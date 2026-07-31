#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Day-1 reconnaissance.
#
# Probes every AWS service we are considering covering, using roughly the
# operations a tutorial would actually need -- not just "does the endpoint
# answer". Emits a markdown coverage matrix to stdout and to scripts/out/.
#
# Run this BEFORE writing any tutorial. Anything that fails here either gets
# dropped from the syllabus or gets an honest "differs from real AWS" callout.
#
#   floci start
#   ./scripts/smoke-test.sh
#   ./scripts/smoke-test.sh s3 lambda      # probe a subset
# ---------------------------------------------------------------------------
set -uo pipefail   # deliberately NOT -e: a failing probe is data, not a crash

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT_DIR="$REPO/scripts/out"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/coverage-$(date +%Y%m%d-%H%M%S).md"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_PAGER=""

SUFFIX="smoke$(date +%s)"
RESULTS=()

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found -- install AWS CLI v2 first" >&2; exit 1; }

# On Windows the AWS CLI is a native .exe and cannot resolve MSYS paths like
# /tmp/foo, so file:// and fileb:// arguments must be converted first.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

if ! curl -fsS --max-time 5 "$AWS_ENDPOINT_URL" >/dev/null 2>&1; then
  echo "Floci not reachable at $AWS_ENDPOINT_URL -- run 'floci start' first" >&2
  exit 1
fi

# probe <service> <label> <command...>
# Records PASS/FAIL plus the first line of any error.
probe() {
  local svc="$1" label="$2"; shift 2
  local out status
  out="$("$@" 2>&1)"; status=$?
  if [ $status -eq 0 ]; then
    printf '  [ok]   %-22s %s\n' "$svc" "$label"
    RESULTS+=("$svc|$label|ok|")
  else
    local first
    first="$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-140)"
    printf '  [FAIL] %-22s %s\n' "$svc" "$label"
    printf '         %s\n' "$first"
    RESULTS+=("$svc|$label|fail|$first")
  fi
}

want() {
  [ $# -eq 0 ] && return 0
  [ ${#WANTED[@]} -eq 0 ] && return 0
  local s
  for s in "${WANTED[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

WANTED=("$@")

# ---------------------------------------------------------------------------
echo "Probing Floci at $AWS_ENDPOINT_URL"
echo

# --- S3 --------------------------------------------------------------------
if want s3; then
  B="smoke-s3-$SUFFIX"
  probe s3 "create bucket"      aws s3api create-bucket --bucket "$B"
  echo "hello floci" > /tmp/$SUFFIX.txt
  probe s3 "put object"         aws s3api put-object --bucket "$B" --key a.txt --body /tmp/$SUFFIX.txt
  probe s3 "get object"         aws s3api get-object --bucket "$B" --key a.txt /tmp/$SUFFIX.out
  probe s3 "list objects v2"    aws s3api list-objects-v2 --bucket "$B"
  probe s3 "presigned url"      aws s3 presign "s3://$B/a.txt"
  probe s3 "bucket versioning"  aws s3api put-bucket-versioning --bucket "$B" --versioning-configuration Status=Enabled
  probe s3 "static website cfg" aws s3api put-bucket-website --bucket "$B" \
      --website-configuration '{"IndexDocument":{"Suffix":"index.html"}}'
fi

# --- DynamoDB --------------------------------------------------------------
if want dynamodb; then
  T="smoke-ddb-$SUFFIX"
  probe dynamodb "create table"  aws dynamodb create-table --table-name "$T" \
      --attribute-definitions AttributeName=pk,AttributeType=S \
      --key-schema AttributeName=pk,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST
  probe dynamodb "put item"      aws dynamodb put-item --table-name "$T" \
      --item '{"pk":{"S":"u1"},"name":{"S":"sreekant"}}'
  probe dynamodb "get item"      aws dynamodb get-item --table-name "$T" --key '{"pk":{"S":"u1"}}'
  probe dynamodb "query"         aws dynamodb query --table-name "$T" \
      --key-condition-expression "pk = :v" \
      --expression-attribute-values '{":v":{"S":"u1"}}'
  probe dynamodb "scan"          aws dynamodb scan --table-name "$T"
fi

# --- SQS -------------------------------------------------------------------
if want sqs; then
  probe sqs "create queue"   aws sqs create-queue --queue-name "smoke-q-$SUFFIX"
  QURL="$(aws sqs get-queue-url --queue-name "smoke-q-$SUFFIX" --query QueueUrl --output text 2>/dev/null)"
  probe sqs "send message"   aws sqs send-message --queue-url "$QURL" --message-body "hi"
  probe sqs "receive message" aws sqs receive-message --queue-url "$QURL"
  probe sqs "queue attrs"    aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names All
fi

# --- SNS -------------------------------------------------------------------
if want sns; then
  probe sns "create topic"  aws sns create-topic --name "smoke-t-$SUFFIX"
  TARN="$(aws sns create-topic --name "smoke-t-$SUFFIX" --query TopicArn --output text 2>/dev/null)"
  probe sns "publish"       aws sns publish --topic-arn "$TARN" --message "hello"
  probe sns "list subs"     aws sns list-subscriptions-by-topic --topic-arn "$TARN"
fi

# --- IAM / STS / Secrets ---------------------------------------------------
if want iam; then
  probe iam "create role" aws iam create-role --role-name "smoke-role-$SUFFIX" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  probe iam "attach policy" aws iam attach-role-policy --role-name "smoke-role-$SUFFIX" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  probe sts "get caller identity" aws sts get-caller-identity
  probe secretsmanager "create secret" aws secretsmanager create-secret \
      --name "smoke-sec-$SUFFIX" --secret-string '{"user":"admin"}'
  probe secretsmanager "get secret" aws secretsmanager get-secret-value --secret-id "smoke-sec-$SUFFIX"
  probe kms "create key" aws kms create-key --description "smoke"
fi

# --- Lambda (needs Docker; slowest probe) ----------------------------------
if want lambda; then
  FN="smoke-fn-$SUFFIX"
  WORK="/tmp/$SUFFIX-lambda"; mkdir -p "$WORK"
  cat > "$WORK/index.mjs" <<'JS'
export const handler = async (event) => ({
  statusCode: 200,
  body: JSON.stringify({ ok: true, got: event })
});
JS
  # Git Bash on Windows ships no `zip`, so fall back to Python's zipfile.
  if command -v zip >/dev/null 2>&1; then
    ( cd "$WORK" && zip -q fn.zip index.mjs ) 2>/dev/null
  elif command -v python >/dev/null 2>&1; then
    python -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1],'w').write(sys.argv[2],'index.mjs')" \
      "$WORK/fn.zip" "$WORK/index.mjs" 2>/dev/null
  fi

  if [ -f "$WORK/fn.zip" ]; then
    probe lambda "create function" aws lambda create-function --function-name "$FN" \
        --runtime nodejs20.x --handler index.handler \
        --role "arn:aws:iam::000000000000:role/lambda-role" \
        --zip-file "fileb://$(native_path "$WORK/fn.zip")"
    sleep 3
    probe lambda "invoke" aws lambda invoke --function-name "$FN" \
        --payload '{"hello":"world"}' --cli-binary-format raw-in-base64-out \
        "$(native_path "$WORK/resp.json")"
    probe lambda "get function" aws lambda get-function --function-name "$FN"
  else
    echo "  [skip] lambda -- could not build the deployment package (no zip, no python)"
    RESULTS+=("lambda|packaging|fail|neither zip nor python available to build the package")
  fi
fi

# --- API Gateway -----------------------------------------------------------
if want apigateway; then
  probe apigatewayv2 "create http api" aws apigatewayv2 create-api \
      --name "smoke-api-$SUFFIX" --protocol-type HTTP
  probe apigateway "create rest api" aws apigateway create-rest-api --name "smoke-rest-$SUFFIX"
fi

# --- Step Functions / EventBridge ------------------------------------------
if want stepfunctions; then
  probe stepfunctions "create state machine" aws stepfunctions create-state-machine \
      --name "smoke-sm-$SUFFIX" \
      --role-arn "arn:aws:iam::000000000000:role/sfn-role" \
      --definition '{"Comment":"smoke","StartAt":"Done","States":{"Done":{"Type":"Pass","End":true}}}'
fi
if want events; then
  probe events "create event bus" aws events create-event-bus --name "smoke-bus-$SUFFIX"
  probe events "put rule" aws events put-rule --name "smoke-rule-$SUFFIX" \
      --event-pattern '{"source":["demo.app"]}'
fi

# --- CloudFormation --------------------------------------------------------
if want cloudformation; then
  cat > /tmp/$SUFFIX-stack.yml <<'YML'
Resources:
  Bucket:
    Type: AWS::S3::Bucket
YML
  probe cloudformation "create stack" aws cloudformation create-stack \
      --stack-name "smoke-stack-$SUFFIX" \
      --template-body "file://$(native_path "/tmp/$SUFFIX-stack.yml")"
  sleep 3
  probe cloudformation "describe stack" aws cloudformation describe-stacks --stack-name "smoke-stack-$SUFFIX"
fi

# --- Misc supporting services ----------------------------------------------
if want logs;   then probe logs "create log group" aws logs create-log-group --log-group-name "/smoke/$SUFFIX"; fi
if want ssm;    then probe ssm "put parameter" aws ssm put-parameter --name "/smoke/$SUFFIX" --value "v" --type String; fi
if want bedrock; then probe bedrock "list models" aws bedrock-runtime help; fi

# ---------------------------------------------------------------------------
# Emit the markdown matrix
# ---------------------------------------------------------------------------
{
  echo "# Floci coverage matrix"
  echo
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "Endpoint: \`$AWS_ENDPOINT_URL\`"
  echo "Floci version: \`$(floci --version 2>/dev/null || echo unknown)\`"
  echo
  echo "| Service | Operation | Result | Notes |"
  echo "|---|---|---|---|"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r svc label status note <<< "$r"
    if [ "$status" = "ok" ]; then
      echo "| \`$svc\` | $label | :white_check_mark: | |"
    else
      note="${note//|/\\|}"
      echo "| \`$svc\` | $label | :x: | \`${note}\` |"
    fi
  done
  echo
  ok=0; bad=0
  for r in "${RESULTS[@]}"; do
    case "$r" in *"|ok|"*) ok=$((ok+1));; *) bad=$((bad+1));; esac
  done
  echo "**$ok passed, $bad failed** out of $((ok+bad)) probes."
} | tee "$OUT_FILE"

echo
echo "Written to $OUT_FILE"
echo "Curate the interesting rows into docs/COVERAGE.md before committing."
