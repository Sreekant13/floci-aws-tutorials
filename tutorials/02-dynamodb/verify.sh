#!/usr/bin/env bash
# Verifies every claim made in tutorials/02-dynamodb/README.md.
source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

TABLE="verify-ddb-$$"
cleanup() { aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

require_cmd aws
require_floci

section "Table creation"
assert_ok "create table with a composite key" -- aws dynamodb create-table \
  --table-name "$TABLE" \
  --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST

STATUS="$(aws dynamodb describe-table --table-name "$TABLE" \
  --query 'Table.TableStatus' --output text 2>/dev/null)"
assert_eq "ACTIVE" "$STATUS" "table reports ACTIVE"

section "Single-table writes"
assert_ok "put user profile" -- aws dynamodb put-item --table-name "$TABLE" \
  --item '{"pk":{"S":"USER#1"},"sk":{"S":"PROFILE"},"email":{"S":"ada@example.com"},"age":{"N":"36"}}'
assert_ok "put order under the same partition" -- aws dynamodb put-item --table-name "$TABLE" \
  --item '{"pk":{"S":"USER#1"},"sk":{"S":"ORDER#1"},"email":{"S":"ada@example.com"},"total":{"N":"99"}}'
assert_ok "put a second user" -- aws dynamodb put-item --table-name "$TABLE" \
  --item '{"pk":{"S":"USER#2"},"sk":{"S":"PROFILE"},"email":{"S":"grace@example.com"},"age":{"N":"45"}}'

section "Reads"
EMAIL="$(aws dynamodb get-item --table-name "$TABLE" \
  --key '{"pk":{"S":"USER#1"},"sk":{"S":"PROFILE"}}' \
  --query 'Item.email.S' --output text 2>/dev/null)"
assert_eq "ada@example.com" "$EMAIL" "get-item returns the right item"

COUNT="$(aws dynamodb query --table-name "$TABLE" \
  --key-condition-expression "pk = :p" \
  --expression-attribute-values '{":p":{"S":"USER#1"}}' \
  --query 'Count' --output text 2>/dev/null)"
assert_eq "2" "$COUNT" "querying a partition returns both of its items"

COUNT="$(aws dynamodb query --table-name "$TABLE" \
  --key-condition-expression "pk = :p AND begins_with(sk, :s)" \
  --expression-attribute-values '{":p":{"S":"USER#1"},":s":{"S":"ORDER"}}' \
  --query 'Count' --output text 2>/dev/null)"
assert_eq "1" "$COUNT" "begins_with on the sort key narrows to orders only"

section "Global secondary index"
assert_ok "add a GSI on email" -- aws dynamodb update-table --table-name "$TABLE" \
  --attribute-definitions AttributeName=email,AttributeType=S \
  --global-secondary-index-updates \
  '[{"Create":{"IndexName":"email-index","KeySchema":[{"AttributeName":"email","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}}]'

GSI="$(aws dynamodb describe-table --table-name "$TABLE" \
  --query 'Table.GlobalSecondaryIndexes[0].IndexName' --output text 2>/dev/null)"
assert_eq "email-index" "$GSI" "GSI appears on the table description"

COUNT="$(aws dynamodb query --table-name "$TABLE" --index-name email-index \
  --key-condition-expression "email = :e" \
  --expression-attribute-values '{":e":{"S":"grace@example.com"}}' \
  --query 'Count' --output text 2>/dev/null)"
assert_eq "1" "$COUNT" "GSI query finds the item by a non-key attribute"

# Documented divergence: real AWS GSIs are eventually consistent, so an item
# written and immediately queried may not be there yet. Floci indexes
# synchronously. If this ever starts failing, the tutorial's section on GSI
# consistency needs revisiting.
aws dynamodb put-item --table-name "$TABLE" \
  --item '{"pk":{"S":"USER#3"},"sk":{"S":"PROFILE"},"email":{"S":"alan@example.com"}}' >/dev/null 2>&1
IMMEDIATE="$(aws dynamodb query --table-name "$TABLE" --index-name email-index \
  --key-condition-expression "email = :e" \
  --expression-attribute-values '{":e":{"S":"alan@example.com"}}' \
  --query 'Count' --output text 2>/dev/null)"
assert_eq "1" "$IMMEDIATE" "GSI is readable immediately after write (Floci is synchronous; real AWS is not)"

section "Conditional writes"
if aws dynamodb put-item --table-name "$TABLE" \
     --item '{"pk":{"S":"USER#1"},"sk":{"S":"PROFILE"},"email":{"S":"oops@example.com"}}' \
     --condition-expression "attribute_not_exists(pk)" >/dev/null 2>&1; then
  fail "conditional write is rejected when the item exists" \
       "the put succeeded, so the condition was not enforced"
else
  pass "conditional write is rejected when the item exists"
fi

SURVIVED="$(aws dynamodb get-item --table-name "$TABLE" \
  --key '{"pk":{"S":"USER#1"},"sk":{"S":"PROFILE"}}' \
  --query 'Item.age.N' --output text 2>/dev/null)"
assert_eq "36" "$SURVIVED" "the rejected write left the original item intact"

section "Atomic counter"
NEWAGE="$(aws dynamodb update-item --table-name "$TABLE" \
  --key '{"pk":{"S":"USER#1"},"sk":{"S":"PROFILE"}}' \
  --update-expression "SET age = age + :inc" \
  --expression-attribute-values '{":inc":{"N":"1"}}' \
  --return-values UPDATED_NEW --query 'Attributes.age.N' --output text 2>/dev/null)"
assert_eq "37" "$NEWAGE" "server-side increment applied"

section "Cleanup"
assert_ok "delete table" -- aws dynamodb delete-table --table-name "$TABLE"

summary
