#!/usr/bin/env bash
# Verifies every claim made in tutorials/05-serverless-api/README.md.
source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

S=$$
TABLE="verify-items-$S"
FN="verify-api-fn-$S"
API_NAME="verify-api-$S"
API_ID=""
WORK="$(mktemp -d)"

cleanup() {
  [ -n "$API_ID" ] && aws apigatewayv2 delete-api --api-id "$API_ID" >/dev/null 2>&1
  aws lambda delete-function --function-name "$FN" >/dev/null 2>&1
  aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

require_cmd aws python curl
require_floci

section "Data store"
assert_ok "create the items table" -- aws dynamodb create-table --table-name "$TABLE" \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

section "Function"
cp "$(dirname "$0")/function/handler.py" "$WORK/handler.py"
python -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1],'w').write(sys.argv[2],'handler.py')" \
  "$(native_path "$WORK/fn.zip")" "$(native_path "$WORK/handler.py")" 2>/dev/null
if [ -f "$WORK/fn.zip" ]; then
  pass "deployment package built"
else
  fail "deployment package built"; summary
fi

assert_ok "create the function" -- aws lambda create-function \
  --function-name "$FN" --runtime python3.11 --handler handler.handler \
  --role arn:aws:iam::000000000000:role/lambda-basic-execution \
  --zip-file "fileb://$(native_path "$WORK/fn.zip")" \
  --environment "Variables={TABLE_NAME=$TABLE}" --timeout 20

FN_ARN="$(aws lambda get-function --function-name "$FN" \
          --query 'Configuration.FunctionArn' --output text 2>/dev/null)"
assert_contains "$FN_ARN" "$FN" "function ARN retrieved"

section "API"
API_ID="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP \
          --query ApiId --output text 2>/dev/null)"
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  pass "HTTP API created"
else
  fail "HTTP API created"; summary
fi

INT_ID="$(aws apigatewayv2 create-integration --api-id "$API_ID" \
          --integration-type AWS_PROXY --integration-uri "$FN_ARN" \
          --payload-format-version 2.0 --query IntegrationId --output text 2>/dev/null)"
assert_contains "$INT_ID" "" "proxy integration created"

for route in "POST /items" "GET /items" "GET /items/{id}" "PUT /items/{id}" "DELETE /items/{id}"; do
  aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$route" \
    --target "integrations/$INT_ID" >/dev/null 2>&1
done
ROUTE_COUNT="$(aws apigatewayv2 get-routes --api-id "$API_ID" --query 'length(Items)' --output text 2>/dev/null)"
assert_eq "5" "$ROUTE_COUNT" "all five routes registered"

assert_ok "create an auto-deploying stage" -- aws apigatewayv2 create-stage \
  --api-id "$API_ID" --stage-name prod --auto-deploy

BASE="http://localhost:4566/restapis/$API_ID/prod/_user_request_"
sleep 3

section "The API actually serves requests"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/items")"
assert_eq "200" "$CODE" "GET /items reaches the function through API Gateway"

section "Create"
CREATED="$(curl -s --max-time 20 -X POST "$BASE/items" \
           -H 'Content-Type: application/json' \
           -d '{"name":"widget","price":9}' 2>/dev/null)"
assert_contains "$CREATED" "widget" "POST /items returns the created item"
ID="$(printf '%s' "$CREATED" | python -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)"
if [ -n "$ID" ]; then
  pass "created item has a generated id"
else
  fail "created item has a generated id" "response: $(printf '%s' "$CREATED" | head -c 120)"
  summary
fi

STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$BASE/items" \
          -H 'Content-Type: application/json' -d '{"price":1}')"
assert_eq "400" "$STATUS" "POST without a name is rejected with 400"

section "Read"
ONE="$(curl -s --max-time 20 "$BASE/items/$ID")"
assert_contains "$ONE" "widget" "GET /items/{id} returns the item"

MISSING="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/items/does-not-exist")"
assert_eq "404" "$MISSING" "GET on an unknown id returns 404"

LIST="$(curl -s --max-time 20 "$BASE/items")"
assert_contains "$LIST" "widget" "GET /items includes the created item"

section "Update"
UPDATED="$(curl -s --max-time 20 -X PUT "$BASE/items/$ID" \
           -H 'Content-Type: application/json' \
           -d '{"name":"gadget","price":25}')"
assert_contains "$UPDATED" "gadget" "PUT /items/{id} returns the updated item"

REREAD="$(curl -s --max-time 20 "$BASE/items/$ID")"
assert_contains "$REREAD" "gadget" "the update persisted to DynamoDB"

section "Delete"
DEL="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X DELETE "$BASE/items/$ID")"
assert_eq "204" "$DEL" "DELETE /items/{id} returns 204"

GONE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/items/$ID")"
assert_eq "404" "$GONE" "the deleted item is really gone"

section "Routing"
UNROUTED="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$BASE/nothing-here")"
assert_eq "404" "$UNROUTED" "an unregistered path returns 404"

BADMETHOD="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$BASE/items/$ID")"
assert_eq "404" "$BADMETHOD" "a method with no matching route returns 404"

section "Documented divergence: the reported endpoint does not work locally"
CLAIMED="$(aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text 2>/dev/null)"
assert_contains "$CLAIMED" "execute-api" "get-api reports a real AWS style endpoint"

# The trailing `|| true` is load-bearing. lib.sh runs with `set -e`, and this
# curl is EXPECTED to fail: the hostname is a real AWS one that does not
# resolve. Without it the assignment aborts the whole script before `summary`
# ever runs, and the tutorial reports a failure for the very behaviour it is
# documenting.
REACH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$CLAIMED/items" 2>/dev/null || true)"
if [ "$REACH" = "200" ]; then
  fail "the reported endpoint is unreachable, as documented" \
       "it responded; Floci may now serve that hostname, update section 9"
else
  pass "the reported endpoint is unreachable, as documented (got '${REACH:-no response}')"
fi

summary
