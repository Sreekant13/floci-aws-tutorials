"""
The tutorial 02 walkthrough, done with boto3.

    pip install -r requirements.txt
    python ddb_demo.py

This uses boto3.resource("dynamodb") rather than boto3.client. The resource API
marshals Python types to and from DynamoDB type descriptors for you, so you
write {"pk": "USER#1"} instead of {"pk": {"S": "USER#1"}}. Compare this with the
raw CLI calls in ../README.md to see exactly what it is doing on your behalf.
"""

import os
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# The ONLY Floci-specific line. Delete endpoint_url and this runs on real AWS.
# ---------------------------------------------------------------------------
ddb = boto3.resource(
    "dynamodb",
    endpoint_url=os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566"),
    region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
)

TABLE = "app-data-python"


def step(msg):
    print(f"\n==> {msg}")


def main():
    # Start clean so the script can be run repeatedly.
    existing = ddb.Table(TABLE)
    try:
        existing.delete()
        existing.wait_until_not_exists()
    except ClientError:
        pass

    step(f"Creating {TABLE} with a composite key")
    table = ddb.create_table(
        TableName=TABLE,
        # Only key attributes are declared. email is added later, when the
        # index needs it.
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
        ],
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},   # partition key
            {"AttributeName": "sk", "KeyType": "RANGE"},  # sort key
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    table.wait_until_exists()
    print(f"    status: {table.table_status}")

    step("Writing users and orders into the same table")
    # No type descriptors here. The resource API adds them.
    table.put_item(Item={"pk": "USER#1", "sk": "PROFILE",
                         "email": "ada@example.com", "age": 36})
    table.put_item(Item={"pk": "USER#1", "sk": "ORDER#1",
                         "email": "ada@example.com", "total": Decimal("99")})
    table.put_item(Item={"pk": "USER#2", "sk": "PROFILE",
                         "email": "grace@example.com", "age": 45})
    print("    3 items written")

    step("get_item needs the complete primary key")
    item = table.get_item(Key={"pk": "USER#1", "sk": "PROFILE"})["Item"]
    print(f"    {item}")

    step("Querying a partition returns everything under that pk")
    resp = table.query(KeyConditionExpression=Key("pk").eq("USER#1"))
    for i in resp["Items"]:
        print(f"    {i['sk']}")

    step("Narrowing with begins_with on the sort key")
    resp = table.query(
        KeyConditionExpression=Key("pk").eq("USER#1") & Key("sk").begins_with("ORDER")
    )
    print(f"    matched {resp['Count']} item(s): {[i['sk'] for i in resp['Items']]}")

    step("The query you cannot serve without an index")
    # A scan reads EVERY item and then discards non-matches. Correct answer,
    # wrong solution. It gets slower forever as the table grows.
    scanned = table.scan(
        FilterExpression=Key("email").eq("grace@example.com")
    )
    print(f"    scan found {scanned['Count']}, after reading {scanned['ScannedCount']} item(s)")

    step("Adding a global secondary index on email")
    table.meta.client.update_table(
        TableName=TABLE,
        # email becomes a key attribute the moment an index uses it.
        AttributeDefinitions=[{"AttributeName": "email", "AttributeType": "S"}],
        GlobalSecondaryIndexUpdates=[
            {
                "Create": {
                    "IndexName": "email-index",
                    "KeySchema": [{"AttributeName": "email", "KeyType": "HASH"}],
                    "Projection": {"ProjectionType": "ALL"},
                }
            }
        ],
    )
    resp = table.query(
        IndexName="email-index",
        KeyConditionExpression=Key("email").eq("grace@example.com"),
    )
    print(f"    index query found {resp['Count']} item(s), reading only what matched")

    step("Conditional write prevents an accidental overwrite")
    try:
        table.put_item(
            Item={"pk": "USER#1", "sk": "PROFILE", "email": "oops@example.com"},
            ConditionExpression="attribute_not_exists(pk)",
        )
        print("    the write succeeded, which it should NOT have")
    except ClientError as e:
        print(f"    rejected as expected: {e.response['Error']['Code']}")

    survived = table.get_item(Key={"pk": "USER#1", "sk": "PROFILE"})["Item"]
    print(f"    original item intact, age is still {survived['age']}")

    step("Atomic counter, incremented server side")
    resp = table.update_item(
        Key={"pk": "USER#1", "sk": "PROFILE"},
        UpdateExpression="SET age = age + :inc",
        ExpressionAttributeValues={":inc": 1},
        ReturnValues="UPDATED_NEW",
    )
    print(f"    age is now {resp['Attributes']['age']}")

    step("Cleaning up")
    table.delete()
    print("    done")


if __name__ == "__main__":
    main()
