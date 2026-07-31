"""
Package, deploy, invoke and inspect a Lambda function, using boto3.

    pip install -r requirements.txt
    python deploy.py

This does with the SDK exactly what the CLI walkthrough in ../README.md does
by hand. Read them side by side.
"""

import io
import json
import os
import time
import zipfile

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

lam = boto3.client("lambda", **COMMON)
logs = boto3.client("logs", **COMMON)

FUNCTION = "greeter-python"
HANDLER_FILE = os.path.join(os.path.dirname(__file__), "..", "function", "handler.py")


def step(msg):
    print(f"\n==> {msg}")


def build_zip():
    """Lambda accepts a zip archive, not a loose file.

    Built in memory rather than on disk. The name inside the archive must match
    the first half of the handler string: handler.py -> "handler.handler".
    """
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(HANDLER_FILE, "handler.py")
    return buf.getvalue()


def main():
    package = build_zip()
    step(f"Built deployment package: {len(package)} bytes")

    # Deleting first makes this script safe to run repeatedly.
    try:
        lam.delete_function(FunctionName=FUNCTION)
        print("    removed a previous copy")
    except lam.exceptions.ResourceNotFoundException:
        pass

    step(f"Creating function {FUNCTION}")
    lam.create_function(
        FunctionName=FUNCTION,
        Runtime="python3.11",
        # "file.function" - the module name, then the function inside it.
        Handler="handler.handler",
        # Real AWS checks this role exists and grants permissions.
        # Floci accepts it without enforcement. See section 9 of the README.
        Role="arn:aws:iam::000000000000:role/lambda-basic-execution",
        Code={"ZipFile": package},
        Environment={"Variables": {"STAGE": "dev"}},
        Timeout=10,
    )

    # Real AWS returns before the function is usable. Poll until Active, which
    # is the habit you want even though Floci is ready immediately.
    for _ in range(30):
        state = lam.get_function(FunctionName=FUNCTION)["Configuration"]["State"]
        if state == "Active":
            break
        time.sleep(1)
    print(f"    state: {state}")

    step("Invoking with a payload")
    resp = lam.invoke(
        FunctionName=FUNCTION,
        Payload=json.dumps({"name": "Sreekant"}).encode(),
    )
    print(f"    StatusCode: {resp['StatusCode']}")
    print(f"    payload:    {resp['Payload'].read().decode()}")

    step("Invoking so that it raises")
    resp = lam.invoke(
        FunctionName=FUNCTION,
        Payload=json.dumps({"boom": True}).encode(),
    )
    # Note the HTTP status is still 200. The request succeeded; the *function*
    # failed. Checking only the status code is a classic way to miss errors.
    print(f"    StatusCode:    {resp['StatusCode']}")
    print(f"    FunctionError: {resp.get('FunctionError')}")
    body = json.loads(resp["Payload"].read().decode())
    print(f"    errorType:     {body.get('errorType')}")
    print(f"    errorMessage:  {body.get('errorMessage')}")

    step("Changing configuration without redeploying code")
    lam.update_function_configuration(
        FunctionName=FUNCTION,
        Environment={"Variables": {"STAGE": "prod"}},
    )
    time.sleep(2)
    resp = lam.invoke(FunctionName=FUNCTION, Payload=json.dumps({"name": "x"}).encode())
    print(f"    payload: {resp['Payload'].read().decode()}")

    step("Reading the logs")
    group = f"/aws/lambda/{FUNCTION}"
    time.sleep(3)
    try:
        streams = logs.describe_log_streams(logGroupName=group)["logStreams"]
        if streams:
            events = logs.get_log_events(
                logGroupName=group,
                logStreamName=streams[0]["logStreamName"],
            )["events"]
            for e in events[:10]:
                print(f"    {e['message'].rstrip()}")
        else:
            print("    no log streams yet")
    except logs.exceptions.ResourceNotFoundException:
        print(f"    log group {group} does not exist yet")

    step("Cleaning up")
    lam.delete_function(FunctionName=FUNCTION)
    print("    done")


if __name__ == "__main__":
    main()
