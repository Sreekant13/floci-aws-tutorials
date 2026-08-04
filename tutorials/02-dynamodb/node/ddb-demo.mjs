/**
 * The tutorial 02 walkthrough, done with AWS SDK v3.
 *
 *   npm install
 *   node ddb-demo.mjs
 *
 * This wraps the low level client in DynamoDBDocumentClient, which marshals
 * plain JavaScript values to and from DynamoDB type descriptors. You write
 * { pk: "USER#1" } instead of { pk: { S: "USER#1" } }. Compare with the raw CLI
 * calls in ../README.md to see what that layer is doing for you.
 */

import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  PutCommand,
  GetCommand,
  QueryCommand,
  ScanCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";
import {
  CreateTableCommand,
  UpdateTableCommand,
  DeleteTableCommand,
  DescribeTableCommand,
  waitUntilTableExists,
  waitUntilTableNotExists,
} from "@aws-sdk/client-dynamodb";

// ---------------------------------------------------------------------------
// The ONLY Floci-specific line. Drop `endpoint` and this runs on real AWS.
// ---------------------------------------------------------------------------
const base = new DynamoDBClient({
  endpoint: process.env.AWS_ENDPOINT_URL ?? "http://localhost:4566",
  region: process.env.AWS_DEFAULT_REGION ?? "us-east-1",
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID ?? "test",
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY ?? "test",
  },
});
const doc = DynamoDBDocumentClient.from(base);

const TABLE = "app-data-node";
const step = (msg) => console.log(`\n==> ${msg}`);

async function main() {
  // Start clean so the script can be run repeatedly.
  try {
    await base.send(new DeleteTableCommand({ TableName: TABLE }));
    await waitUntilTableNotExists({ client: base, maxWaitTime: 30 }, { TableName: TABLE });
  } catch {
    // Table did not exist, which is fine.
  }

  step(`Creating ${TABLE} with a composite key`);
  await base.send(
    new CreateTableCommand({
      TableName: TABLE,
      // Only key attributes are declared. email is added later, when the
      // index needs it.
      AttributeDefinitions: [
        { AttributeName: "pk", AttributeType: "S" },
        { AttributeName: "sk", AttributeType: "S" },
      ],
      KeySchema: [
        { AttributeName: "pk", KeyType: "HASH" },   // partition key
        { AttributeName: "sk", KeyType: "RANGE" },  // sort key
      ],
      BillingMode: "PAY_PER_REQUEST",
    })
  );
  await waitUntilTableExists({ client: base, maxWaitTime: 30 }, { TableName: TABLE });
  const desc = await base.send(new DescribeTableCommand({ TableName: TABLE }));
  console.log(`    status: ${desc.Table.TableStatus}`);

  step("Writing users and orders into the same table");
  // No type descriptors here. The document client adds them.
  await doc.send(new PutCommand({
    TableName: TABLE,
    Item: { pk: "USER#1", sk: "PROFILE", email: "ada@example.com", age: 36 },
  }));
  await doc.send(new PutCommand({
    TableName: TABLE,
    Item: { pk: "USER#1", sk: "ORDER#1", email: "ada@example.com", total: 99 },
  }));
  await doc.send(new PutCommand({
    TableName: TABLE,
    Item: { pk: "USER#2", sk: "PROFILE", email: "grace@example.com", age: 45 },
  }));
  console.log("    3 items written");

  step("GetCommand needs the complete primary key");
  const got = await doc.send(new GetCommand({
    TableName: TABLE,
    Key: { pk: "USER#1", sk: "PROFILE" },
  }));
  console.log(`    ${JSON.stringify(got.Item)}`);

  step("Querying a partition returns everything under that pk");
  const partition = await doc.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: "pk = :p",
    ExpressionAttributeValues: { ":p": "USER#1" },
  }));
  for (const i of partition.Items) console.log(`    ${i.sk}`);

  step("Narrowing with begins_with on the sort key");
  const orders = await doc.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: "pk = :p AND begins_with(sk, :s)",
    ExpressionAttributeValues: { ":p": "USER#1", ":s": "ORDER" },
  }));
  console.log(`    matched ${orders.Count} item(s): ${orders.Items.map((i) => i.sk)}`);

  step("The query you cannot serve without an index");
  // A scan reads EVERY item and then discards non-matches. Correct answer,
  // wrong solution. It gets slower forever as the table grows.
  const scanned = await doc.send(new ScanCommand({
    TableName: TABLE,
    FilterExpression: "email = :e",
    ExpressionAttributeValues: { ":e": "grace@example.com" },
  }));
  console.log(`    scan found ${scanned.Count}, after reading ${scanned.ScannedCount} item(s)`);

  step("Adding a global secondary index on email");
  await base.send(new UpdateTableCommand({
    TableName: TABLE,
    // email becomes a key attribute the moment an index uses it.
    AttributeDefinitions: [{ AttributeName: "email", AttributeType: "S" }],
    GlobalSecondaryIndexUpdates: [
      {
        Create: {
          IndexName: "email-index",
          KeySchema: [{ AttributeName: "email", KeyType: "HASH" }],
          Projection: { ProjectionType: "ALL" },
        },
      },
    ],
  }));
  const byEmail = await doc.send(new QueryCommand({
    TableName: TABLE,
    IndexName: "email-index",
    KeyConditionExpression: "email = :e",
    ExpressionAttributeValues: { ":e": "grace@example.com" },
  }));
  console.log(`    index query found ${byEmail.Count} item(s), reading only what matched`);

  step("Conditional write prevents an accidental overwrite");
  try {
    await doc.send(new PutCommand({
      TableName: TABLE,
      Item: { pk: "USER#1", sk: "PROFILE", email: "oops@example.com" },
      ConditionExpression: "attribute_not_exists(pk)",
    }));
    console.log("    the write succeeded, which it should NOT have");
  } catch (err) {
    console.log(`    rejected as expected: ${err.name}`);
  }

  const survived = await doc.send(new GetCommand({
    TableName: TABLE,
    Key: { pk: "USER#1", sk: "PROFILE" },
  }));
  console.log(`    original item intact, age is still ${survived.Item.age}`);

  step("Atomic counter, incremented server side");
  const bumped = await doc.send(new UpdateCommand({
    TableName: TABLE,
    Key: { pk: "USER#1", sk: "PROFILE" },
    UpdateExpression: "SET age = age + :inc",
    ExpressionAttributeValues: { ":inc": 1 },
    ReturnValues: "UPDATED_NEW",
  }));
  console.log(`    age is now ${bumped.Attributes.age}`);

  step("Cleaning up");
  await base.send(new DeleteTableCommand({ TableName: TABLE }));
  console.log("    done");
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
