"""
A complete CRUD API in one Lambda function.

API Gateway sends every matching request here. The `routeKey` field tells you
which route matched, so one function can serve the whole resource.

Note what is NOT in this file: there is no endpoint configuration anywhere. The
Lambda runtime supplies the DynamoDB location through the environment, both on
real AWS and under Floci. This file is portable as written.
"""

import decimal
import json
import os
import uuid

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
table = boto3.resource("dynamodb").Table(TABLE_NAME)


class DecimalEncoder(json.JSONEncoder):
    """DynamoDB returns numbers as Decimal, which json cannot serialise.

    Whole numbers become int, everything else becomes float. Doing this in one
    place beats scattering conversions through the handlers.
    """

    def default(self, o):
        if isinstance(o, decimal.Decimal):
            return int(o) if o % 1 == 0 else float(o)
        return super().default(o)


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, cls=DecimalEncoder),
    }


def handler(event, context):
    # With payload format 2.0, routeKey is the literal route you registered,
    # for example "GET /items/{id}". Dispatching on it keeps the routing table
    # in API Gateway rather than duplicated in string comparisons here.
    route = event.get("routeKey", "")
    params = event.get("pathParameters") or {}
    item_id = params.get("id")

    try:
        body = json.loads(event["body"]) if event.get("body") else {}
    except json.JSONDecodeError:
        return respond(400, {"error": "body is not valid JSON"})

    if route == "POST /items":
        if "name" not in body:
            # Validate before writing. An API that stores malformed records is
            # worse than one that rejects them.
            return respond(400, {"error": "name is required"})
        item = {
            "id": str(uuid.uuid4()),
            "name": body["name"],
            "price": body.get("price", 0),
        }
        table.put_item(Item=item)
        return respond(201, item)

    if route == "GET /items":
        # A scan is acceptable here only because this table is tiny and has no
        # natural partition to query. See tutorial 02 on why scans do not scale.
        return respond(200, {"items": table.scan().get("Items", [])})

    if route == "GET /items/{id}":
        found = table.get_item(Key={"id": item_id}).get("Item")
        if not found:
            return respond(404, {"error": "not found", "id": item_id})
        return respond(200, found)

    if route == "PUT /items/{id}":
        if not table.get_item(Key={"id": item_id}).get("Item"):
            return respond(404, {"error": "not found", "id": item_id})
        updated = table.update_item(
            Key={"id": item_id},
            UpdateExpression="SET #n = :n, price = :p",
            # "name" is a DynamoDB reserved word, so it must be aliased.
            ExpressionAttributeNames={"#n": "name"},
            ExpressionAttributeValues={
                ":n": body.get("name", ""),
                ":p": body.get("price", 0),
            },
            ReturnValues="ALL_NEW",
        )["Attributes"]
        return respond(200, updated)

    if route == "DELETE /items/{id}":
        if not table.get_item(Key={"id": item_id}).get("Item"):
            return respond(404, {"error": "not found", "id": item_id})
        table.delete_item(Key={"id": item_id})
        return respond(204, {})

    return respond(404, {"error": "no handler for route", "routeKey": route})
