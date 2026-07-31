#!/usr/bin/env bash
# Verifies every claim made in tutorials/03-lambda/README.md.
source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

FN="verify-lambda-$$"
WORK="$(mktemp -d)"
cleanup() {
  aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

require_cmd aws python
require_floci

section "Build the deployment package"
cp "$(dirname "$0")/function/handler.py" "$WORK/handler.py"
python -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1],'w').write(sys.argv[2],'handler.py')" \
  "$(native_path "$WORK/fn.zip")" "$(native_path "$WORK/handler.py")" 2>/dev/null
if [ -f "$WORK/fn.zip" ]; then
  pass "zip archive built"
else
  fail "zip archive built" "could not create the package; python zipfile failed"
  summary
fi

section "Deploy"
assert_ok "create function" -- aws lambda create-function \
  --function-name "$FN" --runtime python3.11 --handler handler.handler \
  --role arn:aws:iam::000000000000:role/lambda-basic-execution \
  --zip-file "fileb://$(native_path "$WORK/fn.zip")" \
  --environment 'Variables={STAGE=dev}' --timeout 10

STATE="$(aws lambda get-function --function-name "$FN" \
  --query 'Configuration.State' --output text 2>/dev/null)"
assert_eq "Active" "$STATE" "function reaches Active state"

RUNTIME="$(aws lambda get-function --function-name "$FN" \
  --query 'Configuration.Runtime' --output text 2>/dev/null)"
assert_eq "python3.11" "$RUNTIME" "runtime is recorded correctly"

section "Invoke"
aws lambda invoke --function-name "$FN" --payload '{"name":"Sreekant"}' \
  --cli-binary-format raw-in-base64-out "$(native_path "$WORK/out.json")" >/dev/null 2>&1
GREETING="$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['greeting'])" \
  "$(native_path "$WORK/out.json")" 2>/dev/null)"
assert_eq "hello Sreekant" "$GREETING" "handler received the event payload"

STAGE="$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['stage'])" \
  "$(native_path "$WORK/out.json")" 2>/dev/null)"
assert_eq "dev" "$STAGE" "environment variable reached the handler"

REMAINING="$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['remaining_ms'])" \
  "$(native_path "$WORK/out.json")" 2>/dev/null)"
if [ "${REMAINING:-0}" -gt 0 ] 2>/dev/null; then
  pass "context.get_remaining_time_in_millis() returned a real budget (${REMAINING}ms)"
else
  fail "context.get_remaining_time_in_millis() returned a real budget" "got: ${REMAINING:-nothing}"
fi

section "Error handling"
ERR="$(aws lambda invoke --function-name "$FN" --payload '{"boom":true}' \
  --cli-binary-format raw-in-base64-out "$(native_path "$WORK/err.json")" \
  --query 'FunctionError' --output text 2>/dev/null)"
assert_eq "Handled" "$ERR" "a raised exception is reported as FunctionError"

ETYPE="$(python -c "import json,sys; print(json.load(open(sys.argv[1])).get('errorType'))" \
  "$(native_path "$WORK/err.json")" 2>/dev/null)"
assert_eq "ValueError" "$ETYPE" "the original exception type survives"

section "Reconfigure without redeploying"
assert_ok "update environment variables" -- aws lambda update-function-configuration \
  --function-name "$FN" --environment 'Variables={STAGE=prod}'
sleep 2
aws lambda invoke --function-name "$FN" --payload '{"name":"x"}' \
  --cli-binary-format raw-in-base64-out "$(native_path "$WORK/out2.json")" >/dev/null 2>&1
STAGE2="$(python -c "import json,sys; print(json.load(open(sys.argv[1]))['stage'])" \
  "$(native_path "$WORK/out2.json")" 2>/dev/null)"
assert_eq "prod" "$STAGE2" "the new configuration took effect"

section "CloudWatch Logs"
# msys_safe is required here: Git Bash rewrites the leading slash of
# /aws/lambda/... into a Windows path before the CLI sees it.
sleep 3
GROUP="$(msys_safe aws logs describe-log-groups \
  --query "logGroups[?logGroupName=='/aws/lambda/$FN'].logGroupName" --output text 2>/dev/null)"
assert_eq "/aws/lambda/$FN" "$GROUP" "log group was created automatically"

STREAM="$(msys_safe aws logs describe-log-streams --log-group-name "/aws/lambda/$FN" \
  --query 'logStreams[0].logStreamName' --output text 2>/dev/null)"
if [ -n "$STREAM" ] && [ "$STREAM" != "None" ]; then
  pass "a log stream exists ($STREAM)"
  MSGS="$(msys_safe aws logs get-log-events --log-group-name "/aws/lambda/$FN" \
    --log-stream-name "$STREAM" --query 'events[].message' --output text 2>/dev/null)"
  assert_contains "$MSGS" "invoked with event" "print() output reached CloudWatch Logs"
else
  fail "a log stream exists" "no streams found under /aws/lambda/$FN"
fi

section "Cleanup"
assert_ok "delete function" -- aws lambda delete-function --function-name "$FN"

summary
