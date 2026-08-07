/**
 * Build the whole serverless API from nothing, exercise it, then tear it down.
 *
 *   npm install
 *   node deploy.mjs
 *
 * Behaviourally identical to ../python/deploy.py.
 */

import { readFileSync } from "node:fs";
import { deflateRawSync, crc32 } from "node:zlib";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  DynamoDBClient,
  CreateTableCommand,
  DeleteTableCommand,
  waitUntilTableExists,
} from "@aws-sdk/client-dynamodb";
import {
  LambdaClient,
  CreateFunctionCommand,
  DeleteFunctionCommand,
  GetFunctionCommand,
} from "@aws-sdk/client-lambda";
import {
  ApiGatewayV2Client,
  CreateApiCommand,
  CreateIntegrationCommand,
  CreateRouteCommand,
  CreateStageCommand,
  GetApiCommand,
  GetApisCommand,
  DeleteApiCommand,
} from "@aws-sdk/client-apigatewayv2";

// ---------------------------------------------------------------------------
// The ONLY Floci-specific lines in this file. Note that the Lambda handler
// itself needs none, because the runtime tells it where DynamoDB is.
// ---------------------------------------------------------------------------
const ENDPOINT = process.env.AWS_ENDPOINT_URL ?? "http://localhost:4566";
const config = {
  endpoint: ENDPOINT,
  region: process.env.AWS_DEFAULT_REGION ?? "us-east-1",
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID ?? "test",
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY ?? "test",
  },
};

const ddb = new DynamoDBClient(config);
const lambda = new LambdaClient(config);
const api = new ApiGatewayV2Client(config);

const HERE = dirname(fileURLToPath(import.meta.url));
const TABLE = "items-demo-node";
const FUNCTION = "items-api-demo-node";
const API_NAME = "items-api-demo-node";

const ROUTES = [
  "POST /items",
  "GET /items",
  "GET /items/{id}",
  "PUT /items/{id}",
  "DELETE /items/{id}",
];

const step = (msg) => console.log(`\n==> ${msg}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const quiet = async (fn) => { try { await fn(); } catch { /* ignore */ } };

/** Minimal single-entry zip writer. Node ships raw deflate but no zip. */
function buildZip(fileName, contents) {
  const data = Buffer.from(contents);
  const compressed = deflateRawSync(data);
  const crc = crc32(data);
  const name = Buffer.from(fileName);

  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);
  local.writeUInt16LE(8, 8);
  local.writeUInt32LE(crc, 14);
  local.writeUInt32LE(compressed.length, 18);
  local.writeUInt32LE(data.length, 22);
  local.writeUInt16LE(name.length, 26);

  const central = Buffer.alloc(46);
  central.writeUInt32LE(0x02014b50, 0);
  central.writeUInt16LE(20, 4);
  central.writeUInt16LE(20, 6);
  central.writeUInt16LE(8, 10);
  central.writeUInt32LE(crc, 16);
  central.writeUInt32LE(compressed.length, 20);
  central.writeUInt32LE(data.length, 24);
  central.writeUInt16LE(name.length, 28);

  const centralOffset = local.length + name.length + compressed.length;
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(1, 8);
  end.writeUInt16LE(1, 10);
  end.writeUInt32LE(central.length + name.length, 12);
  end.writeUInt32LE(centralOffset, 16);

  return Buffer.concat([local, name, compressed, central, name, end]);
}

/** Plain HTTP. A REST API is just HTTP, so no SDK is involved here. */
async function call(method, url, payload) {
  const res = await fetch(url, {
    method,
    headers: payload ? { "Content-Type": "application/json" } : undefined,
    body: payload ? JSON.stringify(payload) : undefined,
  });
  const text = await res.text();
  let parsed = text;
  try { parsed = text ? JSON.parse(text) : null; } catch { /* leave as text */ }
  return { status: res.status, body: parsed };
}

async function teardown() {
  await quiet(async () => {
    const { Items = [] } = await api.send(new GetApisCommand({}));
    for (const a of Items) {
      if (a.Name === API_NAME) await api.send(new DeleteApiCommand({ ApiId: a.ApiId }));
    }
  });
  await quiet(() => lambda.send(new DeleteFunctionCommand({ FunctionName: FUNCTION })));
  await quiet(() => ddb.send(new DeleteTableCommand({ TableName: TABLE })));
}

async function main() {
  await teardown();
  await sleep(1000);

  step(`Creating table ${TABLE}`);
  await ddb.send(new CreateTableCommand({
    TableName: TABLE,
    AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
    KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
    BillingMode: "PAY_PER_REQUEST",
  }));
  await waitUntilTableExists({ client: ddb, maxWaitTime: 30 }, { TableName: TABLE });
  console.log("    active");

  step(`Deploying function ${FUNCTION}`);
  const source = readFileSync(join(HERE, "..", "function", "handler.py"), "utf8");
  await lambda.send(new CreateFunctionCommand({
    FunctionName: FUNCTION,
    Runtime: "python3.11",
    Handler: "handler.handler",
    Role: "arn:aws:iam::000000000000:role/lambda-basic-execution",
    Code: { ZipFile: buildZip("handler.py", source) },
    // Configuration, not code. The same artifact can point at another table.
    Environment: { Variables: { TABLE_NAME: TABLE } },
    Timeout: 20,
  }));
  let fnArn;
  for (let i = 0; i < 30; i++) {
    const { Configuration } = await lambda.send(
      new GetFunctionCommand({ FunctionName: FUNCTION })
    );
    fnArn = Configuration.FunctionArn;
    if (Configuration.State === "Active") break;
    await sleep(1000);
  }
  console.log(`    ${fnArn}`);

  step("Creating the HTTP API and wiring it to the function");
  const { ApiId } = await api.send(new CreateApiCommand({
    Name: API_NAME, ProtocolType: "HTTP",
  }));
  // AWS_PROXY passes the whole request through and takes whatever the
  // function returns as the whole response.
  const { IntegrationId } = await api.send(new CreateIntegrationCommand({
    ApiId,
    IntegrationType: "AWS_PROXY",
    IntegrationUri: fnArn,
    PayloadFormatVersion: "2.0",
  }));
  for (const RouteKey of ROUTES) {
    await api.send(new CreateRouteCommand({
      ApiId, RouteKey, Target: `integrations/${IntegrationId}`,
    }));
  }
  await api.send(new CreateStageCommand({ ApiId, StageName: "prod", AutoDeploy: true }));
  console.log(`    api ${ApiId}, ${ROUTES.length} routes, stage prod`);

  // Real AWS reports an execute-api hostname here that is unreachable from a
  // laptop. Locally the request path is different. See section 9 of the README.
  const { ApiEndpoint } = await api.send(new GetApiCommand({ ApiId }));
  console.log(`    get-api reports: ${ApiEndpoint}`);
  const base = `${ENDPOINT}/restapis/${ApiId}/prod/_user_request_`;
  console.log(`    actually reachable at: ${base}`);
  await sleep(3000);

  step("POST /items");
  let r = await call("POST", `${base}/items`, { name: "widget", price: 9 });
  console.log(`    ${r.status} ${JSON.stringify(r.body)}`);
  const itemId = r.body.id;

  step("POST /items with no name, which should be rejected");
  r = await call("POST", `${base}/items`, { price: 1 });
  console.log(`    ${r.status} ${JSON.stringify(r.body)}`);

  step("GET /items");
  r = await call("GET", `${base}/items`);
  console.log(`    ${r.status} ${JSON.stringify(r.body)}`);

  step(`GET /items/${itemId.slice(0, 8)}...`);
  r = await call("GET", `${base}/items/${itemId}`);
  console.log(`    ${r.status} ${JSON.stringify(r.body)}`);

  step("GET an id that does not exist");
  r = await call("GET", `${base}/items/nope`);
  console.log(`    ${r.status} ${JSON.stringify(r.body)}`);

  step("PUT /items/{id}");
  r = await call("PUT", `${base}/items/${itemId}`, { name: "gadget", price: 25 });
  console.log(`    ${r.status} ${JSON.stringify(r.body)}`);

  step("DELETE /items/{id}");
  r = await call("DELETE", `${base}/items/${itemId}`);
  console.log(`    ${r.status}`);
  r = await call("GET", `${base}/items/${itemId}`);
  console.log(`    re-reading it now gives ${r.status}`);

  step("A path with no matching route, answered by API Gateway not Lambda");
  r = await call("GET", `${base}/nothing-here`);
  console.log(`    ${r.status}`);

  step("Cleaning up");
  await teardown();
  console.log("    done");
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
