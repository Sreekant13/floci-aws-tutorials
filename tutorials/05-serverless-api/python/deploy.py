"""
Build the whole serverless API from nothing, exercise it, then tear it down.

    pip install -r requirements.txt
    python deploy.py

Same sequence as the CLI walkthrough in ../README.md, using boto3.
"""

import io
import json
import os
import time
import urllib.error
import urllib.request
import zipfile

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# The ONLY Floci-specific lines in this file. Note that the Lambda handler
# itself needs none, because the runtime tells it where DynamoDB is.
# ---------------------------------------------------------------------------
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
COMMON = dict(
    endpoint_url=ENDPOINT,
    region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
)

ddb = boto3.client("dynamodb", **COMMON)
lam = boto3.client("lambda", **COMMON)
api = boto3.client("apigatewayv2", **COMMON)

TABLE = "items-demo"
FUNCTION = "items-api-demo"
API_NAME = "items-api-demo"
HANDLER = os.path.join(os.path.dirname(__file__), "..", "function", "handler.py")

ROUTES = [
    "POST /items",
    "GET /items",
    "GET /items/{id}",
    "PUT /items/{id}",
    "DELETE /items/{id}",
]


def step(msg):
    print(f"\n==> {msg}")


def call(method, url, payload=None):
    """Plain HTTP. No SDK, because a REST API is just HTTP."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read().decode()
            return r.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            return e.code, json.loads(body) if body else None
        except json.JSONDecodeError:
            return e.code, body


def teardown():
    try:
        for a in api.get_apis().get("Items", []):
            if a["Name"] == API_NAME:
                api.delete_api(ApiId=a["ApiId"])
    except ClientError:
        pass
    try:
        lam.delete_function(FunctionName=FUNCTION)
    except ClientError:
        pass
    try:
        ddb.delete_table(TableName=TABLE)
    except ClientError:
        pass


def main():
    teardown()
    time.sleep(1)

    step(f"Creating table {TABLE}")
    ddb.create_table(
        TableName=TABLE,
        AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
        KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
        BillingMode="PAY_PER_REQUEST",
    )
    ddb.get_waiter("table_exists").wait(TableName=TABLE)
    print("    active")

    step(f"Deploying function {FUNCTION}")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(HANDLER, "handler.py")
    lam.create_function(
        FunctionName=FUNCTION,
        Runtime="python3.11",
        Handler="handler.handler",
        Role="arn:aws:iam::000000000000:role/lambda-basic-execution",
        Code={"ZipFile": buf.getvalue()},
        # Configuration, not code. The same artifact can point at another table.
        Environment={"Variables": {"TABLE_NAME": TABLE}},
        Timeout=20,
    )
    for _ in range(30):
        if lam.get_function(FunctionName=FUNCTION)["Configuration"]["State"] == "Active":
            break
        time.sleep(1)
    fn_arn = lam.get_function(FunctionName=FUNCTION)["Configuration"]["FunctionArn"]
    print(f"    {fn_arn}")

    step("Creating the HTTP API and wiring it to the function")
    api_id = api.create_api(Name=API_NAME, ProtocolType="HTTP")["ApiId"]
    # AWS_PROXY passes the whole request through and takes whatever the
    # function returns as the whole response.
    integration_id = api.create_integration(
        ApiId=api_id,
        IntegrationType="AWS_PROXY",
        IntegrationUri=fn_arn,
        PayloadFormatVersion="2.0",
    )["IntegrationId"]
    for route in ROUTES:
        api.create_route(
            ApiId=api_id, RouteKey=route, Target=f"integrations/{integration_id}"
        )
    api.create_stage(ApiId=api_id, StageName="prod", AutoDeploy=True)
    print(f"    api {api_id}, {len(ROUTES)} routes, stage prod")

    # Real AWS reports an execute-api hostname here that is unreachable from a
    # laptop. Locally the request path is different. See section 9 of the README.
    print(f"    get-api reports: {api.get_api(ApiId=api_id)['ApiEndpoint']}")
    base = f"{ENDPOINT}/restapis/{api_id}/prod/_user_request_"
    print(f"    actually reachable at: {base}")
    time.sleep(3)

    step("POST /items")
    status, created = call("POST", f"{base}/items", {"name": "widget", "price": 9})
    print(f"    {status} {created}")
    item_id = created["id"]

    step("POST /items with no name, which should be rejected")
    status, err = call("POST", f"{base}/items", {"price": 1})
    print(f"    {status} {err}")

    step("GET /items")
    status, listing = call("GET", f"{base}/items")
    print(f"    {status} {listing}")

    step(f"GET /items/{item_id[:8]}...")
    status, one = call("GET", f"{base}/items/{item_id}")
    print(f"    {status} {one}")

    step("GET an id that does not exist")
    status, missing = call("GET", f"{base}/items/nope")
    print(f"    {status} {missing}")

    step("PUT /items/{id}")
    status, updated = call(
        "PUT", f"{base}/items/{item_id}", {"name": "gadget", "price": 25}
    )
    print(f"    {status} {updated}")

    step("DELETE /items/{id}")
    status, _ = call("DELETE", f"{base}/items/{item_id}")
    print(f"    {status}")
    status, _ = call("GET", f"{base}/items/{item_id}")
    print(f"    re-reading it now gives {status}")

    step("A path with no matching route, answered by API Gateway not Lambda")
    status, _ = call("GET", f"{base}/nothing-here")
    print(f"    {status}")

    step("Cleaning up")
    teardown()
    print("    done")


if __name__ == "__main__":
    main()
