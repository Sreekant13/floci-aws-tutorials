#!/usr/bin/env bash
# Verifies every claim made in tutorials/04-messaging/README.md.
source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

S=$$
EMAIL_Q="verify-email-$S"
FRAUD_Q="verify-fraud-$S"
DLQ="verify-dlq-$S"
MAIN_Q="verify-main-$S"
FIFO_Q="verify-fifo-$S.fifo"
TOPIC="verify-orders-$S"

TOPIC_ARN=""
declare -a QUEUE_URLS=()

cleanup() {
  # set -e is inherited by the EXIT trap. Without this, a single failing
  # teardown call aborts the trap and the script exits with that error,
  # reporting a failure even when every check passed.
  set +e
  for q in "${QUEUE_URLS[@]}"; do
    [ -n "$q" ] && aws sqs delete-queue --queue-url "$q" >/dev/null 2>&1
  done
  [ -n "$TOPIC_ARN" ] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

require_cmd aws
require_floci

qurl()  { aws sqs create-queue --queue-name "$1" --query QueueUrl --output text 2>/dev/null; }
qarn()  { aws sqs get-queue-attributes --queue-url "$1" --attribute-names QueueArn \
            --query 'Attributes.QueueArn' --output text 2>/dev/null; }

section "Queue lifecycle"
EMAIL_URL="$(qurl "$EMAIL_Q")"; QUEUE_URLS+=("$EMAIL_URL")
if [ -n "$EMAIL_URL" ]; then pass "create queue returns a URL"; else fail "create queue returns a URL"; summary; fi

assert_ok "send a message" -- aws sqs send-message --queue-url "$EMAIL_URL" --message-body "order 1001 placed"

BODY="$(aws sqs receive-message --queue-url "$EMAIL_URL" --query 'Messages[0].Body' --output text 2>/dev/null)"
assert_eq "order 1001 placed" "$BODY" "receive returns the body that was sent"

section "Receiving does not delete"
# Put a message back and confirm the queue still holds it after a receive.
aws sqs purge-queue --queue-url "$EMAIL_URL" >/dev/null 2>&1
sleep 1
aws sqs send-message --queue-url "$EMAIL_URL" --message-body "sticky" >/dev/null 2>&1

# Use a generous visibility timeout and release it explicitly afterwards.
# Relying on a short timeout to expire is racy: each AWS CLI invocation on
# Windows costs about a second just to start, which is enough to overshoot a
# one second window and make this test fail for reasons unrelated to SQS.
RH="$(aws sqs receive-message --queue-url "$EMAIL_URL" --visibility-timeout 60 \
      --query 'Messages[0].ReceiptHandle' --output text 2>/dev/null)"
if [ -n "$RH" ] && [ "$RH" != "None" ]; then
  pass "receive returns a ReceiptHandle"
else
  fail "receive returns a ReceiptHandle"
  summary
fi

# While in flight, the message is hidden rather than gone.
HIDDEN="$(aws sqs receive-message --queue-url "$EMAIL_URL" --query 'Messages' --output text 2>/dev/null)"
if [ -z "$HIDDEN" ] || [ "$HIDDEN" = "None" ]; then
  pass "an in-flight message is invisible to a second receive"
else
  fail "an in-flight message is invisible to a second receive" "got: $HIDDEN"
fi

# Hand it back deliberately rather than waiting for a timeout to lapse. This is
# also what a well behaved worker does when it knows it cannot finish.
aws sqs change-message-visibility --queue-url "$EMAIL_URL" \
  --receipt-handle "$RH" --visibility-timeout 0 >/dev/null 2>&1

# Take the body and the receipt handle from the SAME receive. SQS issues a
# fresh receipt handle on every delivery, so a handle captured from an earlier
# receive is stale and delete-message will reject it.
LINE="$(aws sqs receive-message --queue-url "$EMAIL_URL" --wait-time-seconds 5 \
        --visibility-timeout 60 --query 'Messages[0].[Body,ReceiptHandle]' \
        --output text 2>/dev/null)"
REDELIVERED="$(printf '%s' "$LINE" | cut -f1)"
RH2="$(printf '%s' "$LINE" | cut -f2)"
assert_eq "sticky" "$REDELIVERED" "an undeleted message becomes available again"

assert_ok "delete-message accepts the receipt handle" -- \
  aws sqs delete-message --queue-url "$EMAIL_URL" --receipt-handle "$RH2"

GONE="$(aws sqs receive-message --queue-url "$EMAIL_URL" --query 'Messages' --output text 2>/dev/null)"
if [ -z "$GONE" ] || [ "$GONE" = "None" ]; then
  pass "the deleted message does not come back"
else
  fail "the deleted message does not come back" "got: $GONE"
fi

section "Dead letter queue"
DLQ_URL="$(qurl "$DLQ")"; QUEUE_URLS+=("$DLQ_URL")
DLQ_ARN="$(qarn "$DLQ_URL")"
assert_contains "$DLQ_ARN" "$DLQ" "dead letter queue has an ARN"

MAIN_URL="$(aws sqs create-queue --queue-name "$MAIN_Q" \
  --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"2\\\"}\",\"VisibilityTimeout\":\"1\"}" \
  --query QueueUrl --output text 2>/dev/null)"
QUEUE_URLS+=("$MAIN_URL")
POLICY="$(aws sqs get-queue-attributes --queue-url "$MAIN_URL" --attribute-names RedrivePolicy \
          --query 'Attributes.RedrivePolicy' --output text 2>/dev/null)"
assert_contains "$POLICY" "maxReceiveCount" "redrive policy is stored on the queue"

aws sqs send-message --queue-url "$MAIN_URL" --message-body "poison" >/dev/null 2>&1
for _ in 1 2 3; do
  aws sqs receive-message --queue-url "$MAIN_URL" >/dev/null 2>&1
  sleep 2
done
MOVED="$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
         --attribute-names ApproximateNumberOfMessages \
         --query 'Attributes.ApproximateNumberOfMessages' --output text 2>/dev/null)"
if [ "${MOVED:-0}" -ge 1 ] 2>/dev/null; then
  pass "a message exceeding maxReceiveCount lands in the dead letter queue"
else
  fail "a message exceeding maxReceiveCount lands in the dead letter queue" \
       "expected at least 1 message in the DLQ, found ${MOVED:-none}"
fi

section "SNS fan-out"
TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --query TopicArn --output text 2>/dev/null)"
assert_contains "$TOPIC_ARN" "$TOPIC" "topic created"

aws sqs purge-queue --queue-url "$EMAIL_URL" >/dev/null 2>&1
FRAUD_URL="$(qurl "$FRAUD_Q")"; QUEUE_URLS+=("$FRAUD_URL")
EMAIL_ARN="$(qarn "$EMAIL_URL")"
FRAUD_ARN="$(qarn "$FRAUD_URL")"

EMAIL_SUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
             --notification-endpoint "$EMAIL_ARN" --query SubscriptionArn --output text 2>/dev/null)"
FRAUD_SUB="$(aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
             --notification-endpoint "$FRAUD_ARN" --query SubscriptionArn --output text 2>/dev/null)"
assert_contains "$EMAIL_SUB" "arn:aws:sns" "queue subscribed to topic"

sleep 1
aws sns publish --topic-arn "$TOPIC_ARN" --message "order 1002 placed" >/dev/null 2>&1
sleep 3
ENVELOPE="$(aws sqs receive-message --queue-url "$EMAIL_URL" --wait-time-seconds 5 \
            --query 'Messages[0].Body' --output text 2>/dev/null)"
assert_contains "$ENVELOPE" "order 1002 placed" "published message reached the subscribed queue"
assert_contains "$ENVELOPE" "\"Type\":\"Notification\"" "delivery is wrapped in the SNS envelope by default"

section "Raw message delivery"
aws sns set-subscription-attributes --subscription-arn "$EMAIL_SUB" \
  --attribute-name RawMessageDelivery --attribute-value true >/dev/null 2>&1
aws sqs purge-queue --queue-url "$EMAIL_URL" >/dev/null 2>&1
sleep 1
aws sns publish --topic-arn "$TOPIC_ARN" --message "raw body" >/dev/null 2>&1
sleep 3
RAW="$(aws sqs receive-message --queue-url "$EMAIL_URL" --wait-time-seconds 5 \
       --query 'Messages[0].Body' --output text 2>/dev/null)"
assert_eq "raw body" "$RAW" "raw delivery strips the envelope"

section "Filter policies"
aws sns set-subscription-attributes --subscription-arn "$FRAUD_SUB" \
  --attribute-name FilterPolicy --attribute-value '{"value":["high"]}' >/dev/null 2>&1
aws sns set-subscription-attributes --subscription-arn "$FRAUD_SUB" \
  --attribute-name RawMessageDelivery --attribute-value true >/dev/null 2>&1
aws sqs purge-queue --queue-url "$EMAIL_URL" >/dev/null 2>&1
aws sqs purge-queue --queue-url "$FRAUD_URL" >/dev/null 2>&1
sleep 1

aws sns publish --topic-arn "$TOPIC_ARN" --message "big order" \
  --message-attributes '{"value":{"DataType":"String","StringValue":"high"}}' >/dev/null 2>&1
aws sns publish --topic-arn "$TOPIC_ARN" --message "small order" \
  --message-attributes '{"value":{"DataType":"String","StringValue":"low"}}' >/dev/null 2>&1
sleep 4

FRAUD_MSGS="$(aws sqs receive-message --queue-url "$FRAUD_URL" --max-number-of-messages 10 \
              --wait-time-seconds 5 --query 'Messages[].Body' --output text 2>/dev/null)"
assert_contains "$FRAUD_MSGS" "big order" "filtered subscription receives the matching message"
case "$FRAUD_MSGS" in
  *"small order"*) fail "filtered subscription rejects the non-matching message" \
                        "the low value message reached the fraud queue" ;;
  *)               pass "filtered subscription rejects the non-matching message" ;;
esac

EMAIL_MSGS="$(aws sqs receive-message --queue-url "$EMAIL_URL" --max-number-of-messages 10 \
              --wait-time-seconds 5 --query 'Messages[].Body' --output text 2>/dev/null)"
assert_contains "$EMAIL_MSGS" "small order" "unfiltered subscription still receives everything"

section "FIFO ordering"
FIFO_URL="$(aws sqs create-queue --queue-name "$FIFO_Q" --attributes '{"FifoQueue":"true"}' \
            --query QueueUrl --output text 2>/dev/null)"
QUEUE_URLS+=("$FIFO_URL")
if [ -n "$FIFO_URL" ]; then
  pass "FIFO queue created"
  aws sqs send-message --queue-url "$FIFO_URL" --message-body "one" \
    --message-group-id g1 --message-deduplication-id d1 >/dev/null 2>&1
  aws sqs send-message --queue-url "$FIFO_URL" --message-body "two" \
    --message-group-id g1 --message-deduplication-id d2 >/dev/null 2>&1
  ORDER="$(aws sqs receive-message --queue-url "$FIFO_URL" --max-number-of-messages 2 \
           --query 'Messages[].Body' --output text 2>/dev/null | tr '\t' ' ')"
  assert_eq "one two" "$ORDER" "FIFO preserves send order within a message group"
else
  fail "FIFO queue created"
fi

summary
