"""
Build the order workflow, run every path through it, then wire up an event bus.

    pip install -r requirements.txt
    python orchestration_demo.py

Same sequence as the CLI walkthrough in ../README.md, using boto3.
"""

import io
import json
import os
import time
import zipfile

import boto3
from botocore.exceptions import ClientError

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

lam = boto3.client("lambda", **COMMON)
sfn = boto3.client("stepfunctions", **COMMON)
events = boto3.client("events", **COMMON)
sqs = boto3.client("sqs", **COMMON)
logs = boto3.client("logs", **COMMON)

FUNCTION = "charge-demo"
FLOW = "order-flow-demo"
RULE = "order-placed-demo"
QUEUE = "order-events-demo"
HANDLER = os.path.join(os.path.dirname(__file__), "..", "function", "charge.py")
ACCOUNT = "000000000000"


def step(msg):
    print(f"\n==> {msg}")


def await_execution(arn, limit=40):
    """Poll until the execution leaves RUNNING."""
    for _ in range(limit):
        d = sfn.describe_execution(executionArn=arn)
        if d["status"] != "RUNNING":
            return d
        time.sleep(1)
    return sfn.describe_execution(executionArn=arn)


def teardown():
    for name in (FLOW,):
        try:
            for m in sfn.list_state_machines()["stateMachines"]:
                if m["name"] == name:
                    sfn.delete_state_machine(stateMachineArn=m["stateMachineArn"])
        except ClientError:
            pass
    try:
        events.remove_targets(Rule=RULE, Ids=["1"])
    except ClientError:
        pass
    try:
        events.delete_rule(Name=RULE)
    except ClientError:
        pass
    try:
        sqs.delete_queue(QueueUrl=sqs.get_queue_url(QueueName=QUEUE)["QueueUrl"])
    except ClientError:
        pass
    try:
        lam.delete_function(FunctionName=FUNCTION)
    except ClientError:
        pass


def main():
    teardown()
    time.sleep(1)

    step(f"Deploying the workflow step {FUNCTION}")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(HANDLER, "charge.py")
    lam.create_function(
        FunctionName=FUNCTION,
        Runtime="python3.11",
        Handler="charge.handler",
        Role=f"arn:aws:iam::{ACCOUNT}:role/lambda-basic-execution",
        Code={"ZipFile": buf.getvalue()},
        Timeout=20,
    )
    for _ in range(30):
        if lam.get_function(FunctionName=FUNCTION)["Configuration"]["State"] == "Active":
            break
        time.sleep(1)
    fn_arn = lam.get_function(FunctionName=FUNCTION)["Configuration"]["FunctionArn"]
    print(f"    {fn_arn}")

    step("Creating the state machine")
    definition = {
        "Comment": "Order processing",
        "StartAt": "CheckValue",
        "States": {
            # Choice sends large orders down a different path.
            "CheckValue": {
                "Type": "Choice",
                "Choices": [
                    {"Variable": "$.total", "NumericGreaterThan": 100, "Next": "FraudHold"}
                ],
                "Default": "Charge",
            },
            "FraudHold": {"Type": "Wait", "Seconds": 2, "Next": "Charge"},
            "Charge": {
                "Type": "Task",
                "Resource": fn_arn,
                # Correct for production. Floci accepts it and never runs it.
                # See section 5 of the README.
                "Retry": [
                    {
                        "ErrorEquals": ["States.ALL"],
                        "IntervalSeconds": 1,
                        "MaxAttempts": 3,
                        "BackoffRate": 2.0,
                    }
                ],
                "Catch": [{"ErrorEquals": ["States.ALL"], "Next": "Rejected"}],
                "Next": "Done",
            },
            "Done": {"Type": "Succeed"},
            "Rejected": {
                "Type": "Fail",
                "Error": "ChargeFailed",
                "Cause": "the charge step raised",
            },
        },
    }
    sm_arn = sfn.create_state_machine(
        name=FLOW,
        roleArn=f"arn:aws:iam::{ACCOUNT}:role/sfn",
        definition=json.dumps(definition),
    )["stateMachineArn"]
    print(f"    {sm_arn}")

    step("Small order, which takes the default branch")
    ex = sfn.start_execution(
        stateMachineArn=sm_arn, input=json.dumps({"orderId": "A1", "total": 42})
    )["executionArn"]
    d = await_execution(ex)
    print(f"    {d['status']}: {d.get('output')}")

    step("Large order, which waits in the fraud hold first")
    t0 = time.time()
    ex = sfn.start_execution(
        stateMachineArn=sm_arn, input=json.dumps({"orderId": "A2", "total": 500})
    )["executionArn"]
    d = await_execution(ex)
    print(f"    {d['status']} after {time.time() - t0:.1f}s: {d.get('output')}")

    step("Negative total, which fails and is caught")
    ex = sfn.start_execution(
        stateMachineArn=sm_arn, input=json.dumps({"orderId": "A3", "total": -5})
    )["executionArn"]
    d = await_execution(ex)
    print(f"    {d['status']}  error={d.get('error')}  cause={d.get('cause')}")

    step("Execution history, which is the point of using a workflow at all")
    history = sfn.get_execution_history(executionArn=ex)["events"]
    print(f"    {' '.join(e['type'] for e in history)}")

    step("How many times did the failing Task actually run?")
    # MaxAttempts 3 means real AWS invokes it four times. The handler logs
    # before it validates, so every attempt leaves a line even when it fails.
    time.sleep(4)
    attempts = 0
    try:
        group = f"/aws/lambda/{FUNCTION}"
        for s in logs.describe_log_streams(logGroupName=group).get("logStreams", []):
            msgs = logs.get_log_events(
                logGroupName=group, logStreamName=s["logStreamName"]
            ).get("events", [])
            attempts += sum(1 for m in msgs if "charge attempt for order A3" in m["message"])
    except ClientError as e:
        print(f"    could not read logs: {e.response['Error']['Code']}")
    print(f"    attempts: {attempts}   (real AWS would show 4, since MaxAttempts is 3)")
    if attempts == 1:
        print("    Retry was accepted and never executed")

    step("EventBridge: routing events by their content")
    qurl = sqs.create_queue(QueueName=QUEUE)["QueueUrl"]
    qarn = sqs.get_queue_attributes(QueueUrl=qurl, AttributeNames=["QueueArn"])[
        "Attributes"
    ]["QueueArn"]
    events.put_rule(
        Name=RULE,
        EventPattern=json.dumps(
            {"source": ["shop.orders"], "detail-type": ["OrderPlaced"]}
        ),
    )
    events.put_targets(Rule=RULE, Targets=[{"Id": "1", "Arn": qarn}])

    for source, order in (("shop.orders", "E1"), ("shop.shipping", "E2")):
        r = events.put_events(
            Entries=[
                {
                    "Source": source,
                    "DetailType": "OrderPlaced",
                    "Detail": json.dumps({"orderId": order}),
                }
            ]
        )
        # Note: an event matching no rule is NOT an error. It goes nowhere,
        # quietly, which is what makes EventBridge patterns awkward to debug.
        print(f"    published from {source:<15} FailedEntryCount={r['FailedEntryCount']}")

    time.sleep(5)
    msgs = sqs.receive_message(
        QueueUrl=qurl, MaxNumberOfMessages=10, WaitTimeSeconds=6
    ).get("Messages", [])
    print(f"    messages delivered: {len(msgs)}")
    for m in msgs:
        body = json.loads(m["Body"])
        print(f"      source={body['source']} detail={body['detail']}")

    step("Cleaning up")
    teardown()
    print("    done")


if __name__ == "__main__":
    main()
