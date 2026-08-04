/**
 * The tutorial 03 walkthrough, done with AWS SDK v3.
 *
 *   npm install
 *   node deploy.mjs
 *
 * Behaviourally identical to ../python/deploy.py. The deployment package is
 * built in memory with a minimal zip writer so this has no build dependency.
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
  InvokeCommand,
  UpdateFunctionConfigurationCommand,
} from "@aws-sdk/client-lambda";
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
const logs = new CloudWatchLogsClient(config);

const HERE = dirname(fileURLToPath(import.meta.url));
const FUNCTION = "greeter-node";
const step = (msg) => console.log(`\n==> ${msg}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Build a single-entry zip archive in memory.
 *
 * Node has no zip writer in its standard library, only raw deflate. Rather
 * than pull in a dependency for one file, this writes the small amount of zip
 * container format needed for one stored entry. The name inside the archive
 * must match the first half of the handler string.
 */
function buildZip(fileName, contents) {
  const data = Buffer.from(contents);
  const compressed = deflateRawSync(data);
  const crc = crc32(data);
  const name = Buffer.from(fileName);

  const localHeader = Buffer.alloc(30);
  localHeader.writeUInt32LE(0x04034b50, 0); // local file header signature
  localHeader.writeUInt16LE(20, 4);         // version needed
  localHeader.writeUInt16LE(0, 6);          // flags
  localHeader.writeUInt16LE(8, 8);          // method: deflate
  localHeader.writeUInt32LE(0, 10);         // mod time and date
  localHeader.writeUInt32LE(crc, 14);
  localHeader.writeUInt32LE(compressed.length, 18);
  localHeader.writeUInt32LE(data.length, 22);
  localHeader.writeUInt16LE(name.length, 26);
  localHeader.writeUInt16LE(0, 28);         // extra field length

  const centralHeader = Buffer.alloc(46);
  centralHeader.writeUInt32LE(0x02014b50, 0); // central directory signature
  centralHeader.writeUInt16LE(20, 4);         // version made by
  centralHeader.writeUInt16LE(20, 6);         // version needed
  centralHeader.writeUInt16LE(0, 8);
  centralHeader.writeUInt16LE(8, 10);
  centralHeader.writeUInt32LE(0, 12);
  centralHeader.writeUInt32LE(crc, 16);
  centralHeader.writeUInt32LE(compressed.length, 20);
  centralHeader.writeUInt32LE(data.length, 24);
  centralHeader.writeUInt16LE(name.length, 28);
  centralHeader.writeUInt32LE(0, 38);         // external attributes
  centralHeader.writeUInt32LE(0, 42);         // offset of local header

  const centralOffset = localHeader.length + name.length + compressed.length;
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);           // end of central directory
  end.writeUInt16LE(1, 8);                    // entries on this disk
  end.writeUInt16LE(1, 10);                   // total entries
  end.writeUInt32LE(centralHeader.length + name.length, 12);
  end.writeUInt32LE(centralOffset, 16);

  return Buffer.concat([
    localHeader, name, compressed,
    centralHeader, name,
    end,
  ]);
}

async function main() {
  const source = readFileSync(join(HERE, "..", "function", "handler.py"), "utf8");
  const zip = buildZip("handler.py", source);
  step(`Built deployment package: ${zip.length} bytes`);

  // Deleting first makes this script safe to run repeatedly.
  try {
    await lambda.send(new DeleteFunctionCommand({ FunctionName: FUNCTION }));
    console.log("    removed a previous copy");
  } catch {
    // Function did not exist, which is fine.
  }

  step(`Creating function ${FUNCTION}`);
  await lambda.send(
    new CreateFunctionCommand({
      FunctionName: FUNCTION,
      Runtime: "python3.11",
      // "file.function" - the module name, then the function inside it.
      Handler: "handler.handler",
      // Real AWS checks this role exists and grants permissions.
      // Floci accepts it without enforcement. See section 9 of the README.
      Role: "arn:aws:iam::000000000000:role/lambda-basic-execution",
      Code: { ZipFile: zip },
      Environment: { Variables: { STAGE: "dev" } },
      Timeout: 10,
    })
  );

  // Real AWS returns before the function is usable. Poll until Active, which
  // is the habit you want even though Floci is ready immediately.
  let state = "Pending";
  for (let i = 0; i < 30; i++) {
    const { Configuration } = await lambda.send(
      new GetFunctionCommand({ FunctionName: FUNCTION })
    );
    state = Configuration.State;
    if (state === "Active") break;
    await sleep(1000);
  }
  console.log(`    state: ${state}`);

  step("Invoking with a payload");
  let res = await lambda.send(
    new InvokeCommand({
      FunctionName: FUNCTION,
      Payload: Buffer.from(JSON.stringify({ name: "Sreekant" })),
    })
  );
  console.log(`    StatusCode: ${res.StatusCode}`);
  console.log(`    payload:    ${Buffer.from(res.Payload).toString()}`);

  step("Invoking so that it raises");
  res = await lambda.send(
    new InvokeCommand({
      FunctionName: FUNCTION,
      Payload: Buffer.from(JSON.stringify({ boom: true })),
    })
  );
  // Note the HTTP status is still 200. The request succeeded; the *function*
  // failed. Checking only the status code is a classic way to miss errors.
  console.log(`    StatusCode:    ${res.StatusCode}`);
  console.log(`    FunctionError: ${res.FunctionError}`);
  const errBody = JSON.parse(Buffer.from(res.Payload).toString());
  console.log(`    errorType:     ${errBody.errorType}`);
  console.log(`    errorMessage:  ${errBody.errorMessage}`);

  step("Changing configuration without redeploying code");
  await lambda.send(
    new UpdateFunctionConfigurationCommand({
      FunctionName: FUNCTION,
      Environment: { Variables: { STAGE: "prod" } },
    })
  );
  await sleep(2000);
  res = await lambda.send(
    new InvokeCommand({
      FunctionName: FUNCTION,
      Payload: Buffer.from(JSON.stringify({ name: "x" })),
    })
  );
  console.log(`    payload: ${Buffer.from(res.Payload).toString()}`);

  step("Reading the logs");
  await sleep(3000);
  const logGroupName = `/aws/lambda/${FUNCTION}`;
  try {
    const { logStreams } = await logs.send(
      new DescribeLogStreamsCommand({ logGroupName })
    );
    if (logStreams?.length) {
      const { events } = await logs.send(
        new GetLogEventsCommand({
          logGroupName,
          logStreamName: logStreams[0].logStreamName,
        })
      );
      for (const e of (events ?? []).slice(0, 10)) {
        console.log(`    ${e.message.trimEnd()}`);
      }
    } else {
      console.log("    no log streams yet");
    }
  } catch {
    console.log(`    log group ${logGroupName} does not exist yet`);
  }

  step("Cleaning up");
  await lambda.send(new DeleteFunctionCommand({ FunctionName: FUNCTION }));
  console.log("    done");
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
