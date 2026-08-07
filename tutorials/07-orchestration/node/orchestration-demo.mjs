/**
 * The same walkthrough as ../python/orchestration_demo.py, using AWS SDK v3.
 *
 *   npm install
 *   node orchestration-demo.mjs
 */

import { readFileSync } from "node:fs";
import { deflateRawSync, crc32 } from "node:zlib";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  LambdaClient,
  CreateFunctionCommand,
  DeleteFunctionCommand,
  GetFunctionCommand,
} from "@aws-sdk/client-lambda";
import {
  SFNClient,
  CreateStateMachineCommand,
  DeleteStateMachineCommand,
  ListStateMachinesCommand,
  StartExecutionCommand,
  DescribeExecutionCommand,
  GetExecutionHistoryCommand,
} from "@aws-sdk/client-sfn";
import {
  EventBridgeClient,
  PutRuleCommand,
  PutTargetsCommand,
  PutEventsCommand,
  RemoveTargetsCommand,
  DeleteRuleCommand,
} from "@aws-sdk/client-eventbridge";
import {
  SQSClient,
  CreateQueueCommand,
  GetQueueAttributesCommand,
  GetQueueUrlCommand,
  ReceiveMessageCommand,
  DeleteQueueCommand,
} from "@aws-sdk/client-sqs";
import {
  CloudWatchLogsClient,
  DescribeLogStreamsCommand,
  GetLogEventsCommand,
} from "@aws-sdk/client-cloudwatch-logs";

// ---------------------------------------------------------------------------
// The ONLY Floci-specific lines. Drop `endpoint` and this runs on real AWS.
// ---------------------------------------------------------------------------
const config = {
  endpoint: process.env.AWS_ENDPOINT_URL ?? "http://localhost:4566",
  region: process.env.AWS_DEFAULT_REGION ?? "us-east-1",
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID ?? "test",
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY ?? "test",
  },
};

const lambda = new LambdaClient(config);
const sfn = new SFNClient(config);
const events = new EventBridgeClient(config);
const sqs = new SQSClient(config);
const logs = new CloudWatchLogsClient(config);

const HERE = dirname(fileURLToPath(import.meta.url));
const FUNCTION = "charge-demo-node";
const FLOW = "order-flow-demo-node";
const RULE = "order-placed-demo-node";
const QUEUE = "order-events-demo-node";
const ACCOUNT = "000000000000";

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

async function awaitExecution(executionArn, limit = 40) {
  for (let i = 0; i < limit; i++) {
    const d = await sfn.send(new DescribeExecutionCommand({ executionArn }));
    if (d.status !== "RUNNING") return d;
    await sleep(1000);
  }
  return sfn.send(new DescribeExecutionCommand({ executionArn }));
}

async function teardown() {
  await quiet(async () => {
    const { stateMachines = [] } = await sfn.send(new ListStateMachinesCommand({}));
    for (const m of stateMachines) {
      if (m.name === FLOW) {
        await sfn.send(new DeleteStateMachineCommand({ stateMachineArn: m.stateMachineArn }));
      }
    }
  });
  await quiet(() => events.send(new RemoveTargetsCommand({ Rule: RULE, Ids: ["1"] })));
  await quiet(() => events.send(new DeleteRuleCommand({ Name: RULE })));
  await quiet(async () => {
    const { QueueUrl } = await sqs.send(new GetQueueUrlCommand({ QueueName: QUEUE }));
    await sqs.send(new DeleteQueueCommand({ QueueUrl }));
  });
  await quiet(() => lambda.send(new DeleteFunctionCommand({ FunctionName: FUNCTION })));
}

async function main() {
  await teardown();
  await sleep(1000);

  step(`Deploying the workflow step ${FUNCTION}`);
  const source = readFileSync(join(HERE, "..", "function", "charge.py"), "utf8");
  await lambda.send(new CreateFunctionCommand({
    FunctionName: FUNCTION,
    Runtime: "python3.11",
    Handler: "charge.handler",
    Role: `arn:aws:iam::${ACCOUNT}:role/lambda-basic-execution`,
    Code: { ZipFile: buildZip("charge.py", source) },
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

  step("Creating the state machine");
  const definition = {
    Comment: "Order processing",
    StartAt: "CheckValue",
    States: {
      // Choice sends large orders down a different path.
      CheckValue: {
        Type: "Choice",
        Choices: [{ Variable: "$.total", NumericGreaterThan: 100, Next: "FraudHold" }],
        Default: "Charge",
      },
      FraudHold: { Type: "Wait", Seconds: 2, Next: "Charge" },
      Charge: {
        Type: "Task",
        Resource: fnArn,
        // Correct for production. Floci accepts it and never runs it.
        // See section 5 of the README.
        Retry: [
          { ErrorEquals: ["States.ALL"], IntervalSeconds: 1, MaxAttempts: 3, BackoffRate: 2.0 },
        ],
        Catch: [{ ErrorEquals: ["States.ALL"], Next: "Rejected" }],
        Next: "Done",
      },
      Done: { Type: "Succeed" },
      Rejected: { Type: "Fail", Error: "ChargeFailed", Cause: "the charge step raised" },
    },
  };
  const { stateMachineArn } = await sfn.send(new CreateStateMachineCommand({
    name: FLOW,
    roleArn: `arn:aws:iam::${ACCOUNT}:role/sfn`,
    definition: JSON.stringify(definition),
  }));
  console.log(`    ${stateMachineArn}`);

  step("Small order, which takes the default branch");
  let { executionArn } = await sfn.send(new StartExecutionCommand({
    stateMachineArn, input: JSON.stringify({ orderId: "A1", total: 42 }),
  }));
  let d = await awaitExecution(executionArn);
  console.log(`    ${d.status}: ${d.output}`);

  step("Large order, which waits in the fraud hold first");
  const t0 = Date.now();
  ({ executionArn } = await sfn.send(new StartExecutionCommand({
    stateMachineArn, input: JSON.stringify({ orderId: "A2", total: 500 }),
  })));
  d = await awaitExecution(executionArn);
  console.log(`    ${d.status} after ${((Date.now() - t0) / 1000).toFixed(1)}s: ${d.output}`);

  step("Negative total, which fails and is caught");
  ({ executionArn } = await sfn.send(new StartExecutionCommand({
    stateMachineArn, input: JSON.stringify({ orderId: "A3", total: -5 }),
  })));
  d = await awaitExecution(executionArn);
  console.log(`    ${d.status}  error=${d.error}  cause=${d.cause}`);

  step("Execution history, which is the point of using a workflow at all");
  const { events: hist = [] } = await sfn.send(
    new GetExecutionHistoryCommand({ executionArn })
  );
  console.log(`    ${hist.map((e) => e.type).join(" ")}`);

  step("How many times did the failing Task actually run?");
  // MaxAttempts 3 means real AWS invokes it four times. The handler logs
  // before it validates, so every attempt leaves a line even when it fails.
  await sleep(4000);
  let attempts = 0;
  const logGroupName = `/aws/lambda/${FUNCTION}`;
  await quiet(async () => {
    const { logStreams = [] } = await logs.send(
      new DescribeLogStreamsCommand({ logGroupName })
    );
    for (const s of logStreams) {
      const { events: msgs = [] } = await logs.send(new GetLogEventsCommand({
        logGroupName, logStreamName: s.logStreamName,
      }));
      attempts += msgs.filter((m) => m.message.includes("charge attempt for order A3")).length;
    }
  });
  console.log(`    attempts: ${attempts}   (real AWS would show 4, since MaxAttempts is 3)`);
  if (attempts === 1) console.log("    Retry was accepted and never executed");

  step("EventBridge: routing events by their content");
  const { QueueUrl } = await sqs.send(new CreateQueueCommand({ QueueName: QUEUE }));
  const { Attributes } = await sqs.send(new GetQueueAttributesCommand({
    QueueUrl, AttributeNames: ["QueueArn"],
  }));
  await events.send(new PutRuleCommand({
    Name: RULE,
    EventPattern: JSON.stringify({
      source: ["shop.orders"], "detail-type": ["OrderPlaced"],
    }),
  }));
  await events.send(new PutTargetsCommand({
    Rule: RULE, Targets: [{ Id: "1", Arn: Attributes.QueueArn }],
  }));

  for (const [Source, orderId] of [["shop.orders", "E1"], ["shop.shipping", "E2"]]) {
    const r = await events.send(new PutEventsCommand({
      Entries: [{ Source, DetailType: "OrderPlaced", Detail: JSON.stringify({ orderId }) }],
    }));
    // Note: an event matching no rule is NOT an error. It goes nowhere,
    // quietly, which is what makes EventBridge patterns awkward to debug.
    console.log(`    published from ${Source.padEnd(15)} FailedEntryCount=${r.FailedEntryCount}`);
  }

  await sleep(5000);
  const { Messages = [] } = await sqs.send(new ReceiveMessageCommand({
    QueueUrl, MaxNumberOfMessages: 10, WaitTimeSeconds: 6,
  }));
  console.log(`    messages delivered: ${Messages.length}`);
  for (const m of Messages) {
    const body = JSON.parse(m.Body);
    console.log(`      source=${body.source} detail=${JSON.stringify(body.detail)}`);
  }

  step("Cleaning up");
  await teardown();
  console.log("    done");
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
