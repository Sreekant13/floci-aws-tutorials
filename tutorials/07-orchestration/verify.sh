#!/usr/bin/env bash
# Verifies every claim made in tutorials/07-orchestration/README.md.
source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

S=$$
FN="verify-charge-$S"
SM_NAME="verify-flow-$S"
MAP_NAME="verify-map-$S"
RULE="verify-rule-$S"
QUEUE="verify-events-$S"
SM_ARN=""; MAP_ARN=""; QURL=""
WORK="$(mktemp -d)"

cleanup() {
  # set -e is inherited by the EXIT trap. Without this, a single failing
  # teardown call aborts the trap and the script exits with that error,
  # reporting a failure even when every check passed.
  set +e
  [ -n "$SM_ARN" ]  && aws stepfunctions delete-state-machine --state-machine-arn "$SM_ARN" >/dev/null 2>&1
  [ -n "$MAP_ARN" ] && aws stepfunctions delete-state-machine --state-machine-arn "$MAP_ARN" >/dev/null 2>&1
  aws events remove-targets --rule "$RULE" --ids 1 >/dev/null 2>&1
  aws events delete-rule --name "$RULE" >/dev/null 2>&1
  [ -n "$QURL" ] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1
  aws lambda delete-function --function-name "$FN" >/dev/null 2>&1
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

require_cmd aws python
require_floci

# Wait for an execution to leave RUNNING, then echo its final status.
await_execution() {
  local arn="$1" i st
  for i in $(seq 1 30); do
    st="$(aws stepfunctions describe-execution --execution-arn "$arn" --query status --output text 2>/dev/null)"
    [ "$st" != "RUNNING" ] && [ -n "$st" ] && break
    sleep 1
  done
  printf '%s' "$st"
}

section "Workflow step"
cp "$(dirname "$0")/function/charge.py" "$WORK/charge.py"
python -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1],'w').write(sys.argv[2],'charge.py')" \
  "$(native_path "$WORK/fn.zip")" "$(native_path "$WORK/charge.py")" 2>/dev/null
assert_ok "deploy the charge function" -- aws lambda create-function \
  --function-name "$FN" --runtime python3.11 --handler charge.handler \
  --role arn:aws:iam::000000000000:role/lambda-basic-execution \
  --zip-file "fileb://$(native_path "$WORK/fn.zip")" --timeout 20

FN_ARN="$(aws lambda get-function --function-name "$FN" \
          --query 'Configuration.FunctionArn' --output text 2>/dev/null)"
assert_contains "$FN_ARN" "$FN" "function ARN retrieved"

section "State machine"
cat > "$WORK/flow.json" <<JSON
{"Comment":"Order processing","StartAt":"CheckValue","States":{
 "CheckValue":{"Type":"Choice","Choices":[{"Variable":"\$.total","NumericGreaterThan":100,"Next":"FraudHold"}],"Default":"Charge"},
 "FraudHold":{"Type":"Wait","Seconds":2,"Next":"Charge"},
 "Charge":{"Type":"Task","Resource":"$FN_ARN",
   "Retry":[{"ErrorEquals":["States.ALL"],"IntervalSeconds":1,"MaxAttempts":3,"BackoffRate":1.0}],
   "Catch":[{"ErrorEquals":["States.ALL"],"Next":"Rejected"}],"Next":"Done"},
 "Done":{"Type":"Succeed"},
 "Rejected":{"Type":"Fail","Error":"ChargeFailed","Cause":"the charge step raised"}}}
JSON
SM_ARN="$(aws stepfunctions create-state-machine --name "$SM_NAME" \
          --role-arn arn:aws:iam::000000000000:role/sfn \
          --definition "file://$(native_path "$WORK/flow.json")" \
          --query stateMachineArn --output text 2>/dev/null)"
if [ -n "$SM_ARN" ] && [ "$SM_ARN" != "None" ]; then
  pass "state machine created"
else
  fail "state machine created"; summary
fi

section "The Choice default branch"
EX="$(aws stepfunctions start-execution --state-machine-arn "$SM_ARN" \
      --input '{"orderId":"A1","total":42}' --query executionArn --output text 2>/dev/null)"
assert_eq "SUCCEEDED" "$(await_execution "$EX")" "a small order succeeds"
OUT="$(aws stepfunctions describe-execution --execution-arn "$EX" --query output --output text 2>/dev/null)"
assert_contains "$OUT" "PAID" "the Task result reached the output"
assert_contains "$OUT" "A1" "upstream fields survived the Task, because the handler merged"

section "The Choice matching branch"
T0="$(date +%s)"
EX="$(aws stepfunctions start-execution --state-machine-arn "$SM_ARN" \
      --input '{"orderId":"A2","total":500}' --query executionArn --output text 2>/dev/null)"
assert_eq "SUCCEEDED" "$(await_execution "$EX")" "a large order succeeds via the Wait branch"
ELAPSED=$(( $(date +%s) - T0 ))
if [ "$ELAPSED" -ge 2 ]; then
  pass "the Wait state really waited (${ELAPSED}s)"
else
  fail "the Wait state really waited" "completed in ${ELAPSED}s, expected at least 2"
fi

section "Catch"
EX="$(aws stepfunctions start-execution --state-machine-arn "$SM_ARN" \
      --input '{"orderId":"A3","total":-5}' --query executionArn --output text 2>/dev/null)"
assert_eq "FAILED" "$(await_execution "$EX")" "a failing Task ends the execution as FAILED"
ERR="$(aws stepfunctions describe-execution --execution-arn "$EX" --query error --output text 2>/dev/null)"
assert_eq "ChargeFailed" "$ERR" "the Fail state's error name is reported"

section "Execution history"
HIST="$(aws stepfunctions get-execution-history --execution-arn "$EX" \
        --query 'events[].type' --output text 2>/dev/null)"
assert_contains "$HIST" "ExecutionStarted" "history records the start"
assert_contains "$HIST" "ChoiceStateEntered" "history records the Choice state"

# Documented divergence: real AWS records LambdaFunction* events around a Task.
case "$HIST" in
  *LambdaFunctionFailed*|*LambdaFunctionScheduled*)
    fail "history omits LambdaFunction events, as documented" \
         "they are now present; Floci history got richer, update section 9" ;;
  *)
    pass "history omits LambdaFunction events, as documented" ;;
esac

section "Documented divergence: Retry is not executed"
# The state machine sets MaxAttempts 3, so real AWS invokes the function four
# times for order A3. The handler logs "charge attempt" BEFORE validating, so
# every attempt leaves a line even though the call then fails. Counting those
# lines measures retries directly rather than inferring them.
sleep 4
ATTEMPTS=0
for stream in $(msys_safe aws logs describe-log-streams --log-group-name "/aws/lambda/$FN" \
                --query 'logStreams[].logStreamName' --output text 2>/dev/null); do
  n="$(msys_safe aws logs get-log-events --log-group-name "/aws/lambda/$FN" \
       --log-stream-name "$stream" --query 'events[].message' --output text 2>/dev/null \
       | grep -c "charge attempt for order A3" || true)"
  ATTEMPTS=$((ATTEMPTS + n))
done

# Guard against the check passing vacuously: if the marker never appears at all,
# the measurement is broken rather than the behaviour being confirmed.
if [ "$ATTEMPTS" -eq 0 ]; then
  fail "the failing Task attempt was logged at all" \
       "no 'charge attempt for order A3' lines found, so the retry count cannot be measured"
elif [ "$ATTEMPTS" -eq 1 ]; then
  pass "the failing Task ran exactly once despite MaxAttempts 3, as documented"
else
  fail "the failing Task ran exactly once despite MaxAttempts 3, as documented" \
       "found $ATTEMPTS attempts; Floci may now honour Retry, rewrite section 5"
fi

section "Map"
cat > "$WORK/map.json" <<JSON
{"StartAt":"EachOrder","States":{
 "EachOrder":{"Type":"Map","ItemsPath":"\$.orders",
  "Iterator":{"StartAt":"Charge","States":{"Charge":{"Type":"Task","Resource":"$FN_ARN","End":true}}},
  "End":true}}}
JSON
MAP_ARN="$(aws stepfunctions create-state-machine --name "$MAP_NAME" \
           --role-arn arn:aws:iam::000000000000:role/sfn \
           --definition "file://$(native_path "$WORK/map.json")" \
           --query stateMachineArn --output text 2>/dev/null)"
EX="$(aws stepfunctions start-execution --state-machine-arn "$MAP_ARN" \
      --input '{"orders":[{"orderId":"B1","total":10},{"orderId":"B2","total":20}]}' \
      --query executionArn --output text 2>/dev/null)"
assert_eq "SUCCEEDED" "$(await_execution "$EX")" "Map execution succeeds"
MOUT="$(aws stepfunctions describe-execution --execution-arn "$EX" --query output --output text 2>/dev/null)"
assert_contains "$MOUT" "B1" "Map output includes the first item"
assert_contains "$MOUT" "B2" "Map output includes the second item"

section "EventBridge routing"
QURL="$(aws sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text 2>/dev/null)"
QARN="$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn \
        --query 'Attributes.QueueArn' --output text 2>/dev/null)"
assert_ok "create the rule" -- aws events put-rule --name "$RULE" \
  --event-pattern '{"source":["shop.orders"],"detail-type":["OrderPlaced"]}'

FAILED="$(aws events put-targets --rule "$RULE" --targets "Id=1,Arn=$QARN" \
          --query FailedEntryCount --output text 2>/dev/null)"
assert_eq "0" "$FAILED" "the queue is accepted as a target"

aws events put-events --entries \
  '[{"Source":"shop.orders","DetailType":"OrderPlaced","Detail":"{\"orderId\":\"E1\"}"}]' >/dev/null 2>&1
aws events put-events --entries \
  '[{"Source":"shop.shipping","DetailType":"OrderPlaced","Detail":"{\"orderId\":\"E2\"}"}]' >/dev/null 2>&1
sleep 5

BODIES="$(aws sqs receive-message --queue-url "$QURL" --max-number-of-messages 10 \
          --wait-time-seconds 6 --query 'Messages[].Body' --output text 2>/dev/null)"
assert_contains "$BODIES" "E1" "the matching event was delivered"
case "$BODIES" in
  *E2*) fail "the non-matching event was filtered out" "shop.shipping reached the queue" ;;
  *)    pass "the non-matching event was filtered out" ;;
esac
assert_contains "$BODIES" "detail-type" "delivery uses the EventBridge envelope"

section "Documented divergence: EventBridge cannot start a state machine"
SFN_FAILED="$(aws events put-targets --rule "$RULE" \
              --targets "Id=2,Arn=$SM_ARN,RoleArn=arn:aws:iam::000000000000:role/eb" \
              --query FailedEntryCount --output text 2>/dev/null || true)"
assert_eq "0" "$SFN_FAILED" "a state machine target is accepted without error"

BEFORE="$(aws stepfunctions list-executions --state-machine-arn "$SM_ARN" \
          --query 'length(executions)' --output text 2>/dev/null)"
aws events put-events --entries \
  '[{"Source":"shop.orders","DetailType":"OrderPlaced","Detail":"{\"orderId\":\"E3\",\"total\":1}"}]' >/dev/null 2>&1
sleep 6
AFTER="$(aws stepfunctions list-executions --state-machine-arn "$SM_ARN" \
         --query 'length(executions)' --output text 2>/dev/null)"
if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ] 2>/dev/null; then
  fail "the state machine target never fires, as documented" \
       "an execution started; Floci now supports this target, update section 9"
else
  pass "the state machine target never fires, as documented (executions stayed at $AFTER)"
fi

summary
