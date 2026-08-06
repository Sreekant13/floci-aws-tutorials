/**
 * The same walkthrough as ../python/iam_demo.py, using AWS SDK v3.
 *
 *   npm install
 *   node iam-demo.mjs
 */

import {
  IAMClient,
  CreateRoleCommand,
  PutRolePolicyCommand,
  DeleteRolePolicyCommand,
  DeleteRoleCommand,
  SimulatePrincipalPolicyCommand,
} from "@aws-sdk/client-iam";
import {
  STSClient,
  AssumeRoleCommand,
  GetCallerIdentityCommand,
} from "@aws-sdk/client-sts";
import {
  SecretsManagerClient,
  CreateSecretCommand,
  GetSecretValueCommand,
  PutSecretValueCommand,
  DeleteSecretCommand,
} from "@aws-sdk/client-secrets-manager";
import { KMSClient, CreateKeyCommand, EncryptCommand } from "@aws-sdk/client-kms";
import {
  S3Client,
  CreateBucketCommand,
  PutObjectCommand,
  DeleteObjectCommand,
  DeleteBucketCommand,
  ListObjectsV2Command,
  ListBucketsCommand,
} from "@aws-sdk/client-s3";

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

const iam = new IAMClient(config);
const sts = new STSClient(config);
const secrets = new SecretsManagerClient(config);
const kms = new KMSClient(config);
const s3 = new S3Client({ ...config, forcePathStyle: true });

const ROLE = "demo-app-role-node";
const BUCKET = "demo-enforcement-test-node";
const SECRET = "demo-db-credentials-node";
const ACCOUNT = "000000000000";

const TRUST = {
  Version: "2012-10-17",
  Statement: [{ Effect: "Allow", Principal: { AWS: "*" }, Action: "sts:AssumeRole" }],
};
const PERMS = {
  Version: "2012-10-17",
  Statement: [
    { Effect: "Allow", Action: "s3:GetObject", Resource: "*" },
    { Effect: "Deny", Action: "s3:DeleteObject", Resource: "*" },
  ],
};

const step = (msg) => console.log(`\n==> ${msg}`);
const quiet = async (fn) => { try { await fn(); } catch { /* ignore */ } };

async function cleanup() {
  await quiet(() => iam.send(new DeleteRolePolicyCommand({ RoleName: ROLE, PolicyName: "perms" })));
  await quiet(() => iam.send(new DeleteRoleCommand({ RoleName: ROLE })));
  await quiet(async () => {
    const { Contents = [] } = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET }));
    for (const o of Contents) {
      await s3.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: o.Key }));
    }
    await s3.send(new DeleteBucketCommand({ Bucket: BUCKET }));
  });
  await quiet(() => secrets.send(new DeleteSecretCommand({
    SecretId: SECRET, ForceDeleteWithoutRecovery: true,
  })));
}

async function main() {
  await cleanup();

  step(`Creating role ${ROLE}`);
  // A trust policy says WHO may assume the role. A permission policy says
  // WHAT the role may then do. Mixing them up is the classic beginner error.
  await iam.send(new CreateRoleCommand({
    RoleName: ROLE,
    AssumeRolePolicyDocument: JSON.stringify(TRUST),
  }));
  await iam.send(new PutRolePolicyCommand({
    RoleName: ROLE,
    PolicyName: "perms",
    PolicyDocument: JSON.stringify(PERMS),
  }));
  console.log("    policy allows s3:GetObject and explicitly denies s3:DeleteObject");

  step("Assuming the role");
  const { Credentials } = await sts.send(new AssumeRoleCommand({
    RoleArn: `arn:aws:iam::${ACCOUNT}:role/${ROLE}`,
    RoleSessionName: "my-session",
  }));
  console.log(`    expires: ${Credentials.Expiration}`);

  const assumedCreds = {
    accessKeyId: Credentials.AccessKeyId,
    secretAccessKey: Credentials.SecretAccessKey,
    sessionToken: Credentials.SessionToken,
  };
  const stsAssumed = new STSClient({ ...config, credentials: assumedCreds });
  const { Arn } = await stsAssumed.send(new GetCallerIdentityCommand({}));
  // Note the session name in this ARN. It says floci-session, not my-session.
  console.log(`    identity: ${Arn}`);

  step("Testing whether the Deny is enforced");
  await s3.send(new CreateBucketCommand({ Bucket: BUCKET }));
  await s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: "f.txt", Body: "delete me\n" }));

  const s3Assumed = new S3Client({ ...config, forcePathStyle: true, credentials: assumedCreds });
  try {
    await s3Assumed.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: "f.txt" }));
    console.log("    delete SUCCEEDED, even though the policy explicitly denies it");
    console.log("    the policy was stored, and never consulted");
  } catch (err) {
    console.log(`    delete was denied: ${err.name}`);
    console.log("    Floci now enforces IAM, and this tutorial needs rewriting");
  }

  step("Trying credentials that were never issued by anything");
  const invented = new S3Client({
    ...config,
    forcePathStyle: true,
    credentials: { accessKeyId: "AKIAFAKEFAKEFAKE", secretAccessKey: "nonsense" },
  });
  try {
    await invented.send(new ListBucketsCommand({}));
    console.log("    accepted, so any credential works here");
  } catch (err) {
    console.log(`    rejected: ${err.name}`);
  }

  step("The simulator, which does evaluate the same policy correctly");
  for (const [action, resource] of [
    ["s3:GetObject", `arn:aws:s3:::${BUCKET}/f.txt`],
    ["s3:DeleteObject", `arn:aws:s3:::${BUCKET}/f.txt`],
    ["ec2:TerminateInstances", "*"],
  ]) {
    const { EvaluationResults } = await iam.send(new SimulatePrincipalPolicyCommand({
      PolicySourceArn: `arn:aws:iam::${ACCOUNT}:role/${ROLE}`,
      ActionNames: [action],
      ResourceArns: [resource],
    }));
    console.log(`    ${action.padEnd(26)} ${EvaluationResults[0].EvalDecision}`);
  }

  console.log("\n    allowed      = something granted it and nothing denied it");
  console.log("    explicitDeny = a Deny matched, and Deny always wins");
  console.log("    implicitDeny = nothing mentioned it, so it is denied by default");

  step("Secrets Manager, which works properly");
  await secrets.send(new CreateSecretCommand({
    Name: SECRET,
    SecretString: JSON.stringify({ user: "admin", pass: "s3cret" }),
  }));
  let cur = await secrets.send(new GetSecretValueCommand({ SecretId: SECRET }));
  console.log(`    current:  ${cur.SecretString}`);

  await secrets.send(new PutSecretValueCommand({
    SecretId: SECRET,
    SecretString: JSON.stringify({ user: "admin", pass: "rotated" }),
  }));
  cur = await secrets.send(new GetSecretValueCommand({ SecretId: SECRET }));
  console.log(`    rotated:  ${cur.SecretString}`);
  // Version staging is what makes safe rotation possible: roll back by moving
  // a label rather than by restoring a backup.
  const prev = await secrets.send(new GetSecretValueCommand({
    SecretId: SECRET, VersionStage: "AWSPREVIOUS",
  }));
  console.log(`    previous: ${prev.SecretString}`);

  step("KMS, which does NOT encrypt");
  const { KeyMetadata } = await kms.send(new CreateKeyCommand({ Description: "demo" }));
  const plaintext = "ATTACK_AT_DAWN";
  const { CiphertextBlob } = await kms.send(new EncryptCommand({
    KeyId: KeyMetadata.KeyId,
    Plaintext: Buffer.from(plaintext),
  }));

  const envelope = Buffer.from(CiphertextBlob).toString();
  console.log(`    ciphertext envelope: ${envelope.slice(0, 90)}`);

  // The final field of the envelope is ordinary base64. No key required.
  const tail = envelope.split(":").pop();
  const recovered = Buffer.from(tail, "base64").toString();
  if (recovered === plaintext) {
    console.log(`    recovered without any key: ${recovered}`);
    console.log("    nothing you put through KMS here is protected");
  } else {
    console.log("    could not decode the tail; Floci may now encrypt properly");
  }

  step("Cleaning up");
  await cleanup();
  console.log("    done");
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
