"""
Build the whole order pipeline with boto3: a topic, two queues, a filter on one
of them, and a dead letter queue.

    pip install -r requirements.txt
    python messaging_demo.py
"""

import json
import os
import time

import boto3

# ---------------------------------------------------------------------------
# The ONLY Floci-specific lines. Delete endpoint_url and this runs on real AWS.
# ---------------------------------------------------------------------------
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
COMMON = dict(
    endpoint_url=ENDPOINT,
    region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
)

sqs = boto3.client("sqs", **COMMON)
sns = boto3.client("sns", **COMMON)

SUFFIX = "demo"
EMAIL_Q = f"email-queue-{SUFFIX}"
FRAUD_Q = f"fraud-queue-{SUFFIX}"
DLQ = f"orders-dlq-{SUFFIX}"
MAIN_Q = f"orders-main-{SUFFIX}"
TOPIC = f"orders-{SUFFIX}"


def step(msg):
    print(f"\n==> {msg}")


def make_queue(name, attributes=None):
    url = sqs.create_queue(QueueName=name, Attributes=attributes or {})["QueueUrl"]
    arn = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["QueueArn"])[
        "Attributes"
    ]["QueueArn"]
    return url, arn


def drain(url, label, wait=5):
    """Read everything currently visible and delete it properly."""
    msgs = sqs.receive_message(
        QueueUrl=url, MaxNumberOfMessages=10, WaitTimeSeconds=wait
    ).get("Messages", [])
    for m in msgs:
        print(f"    {label}: {m['Body'][:80]}")
        # Deleting is a separate call. Receiving only hid the message.
        sqs.delete_message(QueueUrl=url, ReceiptHandle=m["ReceiptHandle"])
    if not msgs:
        print(f"    {label}: nothing")
    return msgs


def main():
    step("Creating queues and topic")
    email_url, email_arn = make_queue(EMAIL_Q)
    fraud_url, fraud_arn = make_queue(FRAUD_Q)
    topic_arn = sns.create_topic(Name=TOPIC)["TopicArn"]
    print(f"    topic: {topic_arn}")

    step("Subscribing both queues to the topic")
    email_sub = sns.subscribe(
        TopicArn=topic_arn, Protocol="sqs", Endpoint=email_arn
    )["SubscriptionArn"]
    fraud_sub = sns.subscribe(
        TopicArn=topic_arn, Protocol="sqs", Endpoint=fraud_arn
    )["SubscriptionArn"]

    # Raw delivery removes the SNS envelope. This is a property of the
    # subscription, so each subscriber chooses independently.
    for sub in (email_sub, fraud_sub):
        sns.set_subscription_attributes(
            SubscriptionArn=sub, AttributeName="RawMessageDelivery", AttributeValue="true"
        )

    # The fraud queue only wants high value orders. SNS applies this before
    # delivery, so the fraud worker never even sees the others.
    sns.set_subscription_attributes(
        SubscriptionArn=fraud_sub,
        AttributeName="FilterPolicy",
        AttributeValue=json.dumps({"value": ["high"]}),
    )
    print("    fraud queue filters on value=high")
    time.sleep(1)

    step("Publishing two orders, one high value and one low")
    for body, value in (("big order", "high"), ("small order", "low")):
        sns.publish(
            TopicArn=topic_arn,
            Message=body,
            MessageAttributes={"value": {"DataType": "String", "StringValue": value}},
        )
    time.sleep(4)

    step("What each queue actually received")
    drain(email_url, "email")
    drain(fraud_url, "fraud")

    step("Dead letter queue: parking a message that never succeeds")
    dlq_url, dlq_arn = make_queue(DLQ)
    main_url, _ = make_queue(
        MAIN_Q,
        {
            "RedrivePolicy": json.dumps(
                {"deadLetterTargetArn": dlq_arn, "maxReceiveCount": "2"}
            ),
            "VisibilityTimeout": "1",
        },
    )
    sqs.send_message(QueueUrl=main_url, MessageBody="poison")

    # Receive it repeatedly without ever deleting it, exactly as a failing
    # worker would. After maxReceiveCount attempts SQS moves it aside.
    for attempt in range(1, 4):
        got = sqs.receive_message(QueueUrl=main_url).get("Messages", [])
        print(f"    attempt {attempt}: {'received' if got else 'nothing visible'}")
        time.sleep(2)

    parked = sqs.get_queue_attributes(
        QueueUrl=dlq_url, AttributeNames=["ApproximateNumberOfMessages"]
    )["Attributes"]["ApproximateNumberOfMessages"]
    print(f"    messages now in the dead letter queue: {parked}")

    step("Cleaning up")
    for url in (email_url, fraud_url, dlq_url, main_url):
        sqs.delete_queue(QueueUrl=url)
    sns.delete_topic(TopicArn=topic_arn)
    print("    done")


if __name__ == "__main__":
    main()
