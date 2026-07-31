/**
 * S3 against Floci, using AWS SDK v3.
 *
 * Behaviourally identical to ../python/s3_demo.py -- read whichever language
 * you know and map it onto the other.
 *
 *   npm install
 *   node s3-demo.mjs
 */

import {
  S3Client,
  CreateBucketCommand,
  PutObjectCommand,
  GetObjectCommand,
  ListObjectsV2Command,
  PutBucketVersioningCommand,
  ListObjectVersionsCommand,
  DeleteObjectCommand,
  DeleteBucketCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

// ---------------------------------------------------------------------------
// The ONLY Floci-specific lines in this file.
//
// Drop `endpoint` and `forcePathStyle` and this runs against real AWS with
// whatever credentials the environment provides.
//
// forcePathStyle matters locally: real S3 uses virtual-host addressing
// (bucket.s3.amazonaws.com), which cannot work against localhost.
// ---------------------------------------------------------------------------
const s3 = new S3Client({
  endpoint: process.env.AWS_ENDPOINT_URL ?? "http://localhost:4566",
  region: process.env.AWS_DEFAULT_REGION ?? "us-east-1",
  forcePathStyle: true,
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID ?? "test",
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY ?? "test",
  },
});

const BUCKET = "floci-demo-node";
const KEY = "notes/sample.txt";

const step = (msg) => console.log(`\n==> ${msg}`);

async function main() {
  step(`Creating bucket ${BUCKET}`);
  try {
    await s3.send(new CreateBucketCommand({ Bucket: BUCKET }));
  } catch (err) {
    if (err.name !== "BucketAlreadyOwnedByYou") throw err;
    console.log("    already exists, reusing it");
  }

  step("Uploading an object");
  await s3.send(
    new PutObjectCommand({ Bucket: BUCKET, Key: KEY, Body: "the quick brown fox\n" })
  );

  step("Listing with a prefix");
  const listing = await s3.send(
    new ListObjectsV2Command({ Bucket: BUCKET, Prefix: "notes/" })
  );
  for (const obj of listing.Contents ?? []) {
    console.log(`    ${obj.Key}  (${obj.Size} bytes)`);
  }

  step("Reading it back");
  const got = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: KEY }));
  console.log(`    ${JSON.stringify((await got.Body.transformToString()).trim())}`);

  step("Generating a presigned URL (valid 5 minutes)");
  const url = await getSignedUrl(
    s3,
    new GetObjectCommand({ Bucket: BUCKET, Key: KEY }),
    { expiresIn: 300 }
  );
  console.log(`    ${url}`);

  step("Fetching that URL with no credentials at all");
  // Plain fetch, no SDK, no credentials. The query-string signature is the
  // entire authorisation.
  const res = await fetch(url);
  console.log(`    HTTP ${res.status}: ${JSON.stringify((await res.text()).trim())}`);

  step("Enabling versioning and overwriting");
  await s3.send(
    new PutBucketVersioningCommand({
      Bucket: BUCKET,
      VersioningConfiguration: { Status: "Enabled" },
    })
  );
  await s3.send(
    new PutObjectCommand({ Bucket: BUCKET, Key: KEY, Body: "jumps over the lazy dog\n" })
  );

  const { Versions = [], DeleteMarkers = [] } = await s3.send(
    new ListObjectVersionsCommand({ Bucket: BUCKET, Prefix: "notes/" })
  );
  for (const v of Versions) {
    console.log(`    ${v.Key}  version=${v.VersionId}${v.IsLatest ? "  <- current" : ""}`);
  }

  step("Cleaning up");
  // A versioned bucket needs every version removed before it will delete.
  for (const v of [...Versions, ...DeleteMarkers]) {
    await s3.send(
      new DeleteObjectCommand({ Bucket: BUCKET, Key: v.Key, VersionId: v.VersionId })
    );
  }
  await s3.send(new DeleteBucketCommand({ Bucket: BUCKET }));
  console.log("    done");
}

main().catch((err) => {
  console.error("\nFailed:", err.message);
  process.exit(1);
});
