---
title: "01 — S3: object storage"
permalink: /tutorials/01-s3/
---

# 01 — S3: object storage

**Time: 50 minutes.** Assumes [`00-setup`](../00-setup/) is done.

## What you'll build

A bucket that stores files, hands out time-limited download links to people
who have no AWS credentials, keeps old versions of overwritten objects, and
serves a static website.

```mermaid
flowchart LR
    U["You<br/>(aws CLI / SDK)"] -->|"PutObject"| B[("S3 bucket")]
    B -->|"presigned URL"| V["Anyone with the link<br/>(no credentials)"]
    B --> W["Static website<br/>index.html"]
    B -.->|"versioning on"| H["Previous versions"]
```

## Why S3

S3 is the default answer to "where do we put this file". Uploads, backups,
logs, build artifacts, static sites, and the storage layer under most data
pipelines. It's the oldest AWS service and the one you're most certain to meet.

Two ideas here matter more than the API surface. **Presigned URLs** let you
grant temporary access to a single object without giving anyone credentials —
that's how "download your invoice" links work. **Versioning** turns a delete
into a tombstone rather than a loss.

## Prerequisites

Floci running:

```bash
floci start && eval $(floci env)
```

## 1. Create a bucket

```bash
aws s3api create-bucket --bucket floci-demo
```

Bucket names are globally unique in real AWS — `floci-demo` is almost certainly
taken there. Locally you have the namespace to yourself, which is itself a
divergence worth remembering.

```bash
aws s3api list-buckets --query 'Buckets[].Name' --output table
```

## 2. Put an object in it

```bash
printf 'the quick brown fox\n' > sample.txt
```

```bash
aws s3api put-object --bucket floci-demo --key notes/sample.txt --body sample.txt
```

Note the key is `notes/sample.txt`. S3 has **no directories** — that slash is
just a character in the key. The console draws folders by splitting on `/`, but
nothing hierarchical exists underneath.

List with a prefix to see the illusion working:

```bash
aws s3api list-objects-v2 --bucket floci-demo --prefix notes/ --query 'Contents[].{Key:Key,Size:Size}' --output table
```

## 3. Read it back

```bash
aws s3api get-object --bucket floci-demo --key notes/sample.txt downloaded.txt
```

```bash
cat downloaded.txt
```

## 4. Presigned URLs

The interesting one. Generate a link that works for five minutes, for someone
with no AWS access at all:

```bash
aws s3 presign s3://floci-demo/notes/sample.txt --expires-in 300
```

Copy that URL and fetch it with no credentials in the environment:

```bash
curl -s "$(aws s3 presign s3://floci-demo/notes/sample.txt --expires-in 300)"
```

Look at the URL itself. The signature, expiry, and your access key ID are all
query parameters. Nothing secret is in there — the signature proves you
authorised this exact object for this exact window, and it cannot be edited to
mean anything else.

## 5. Versioning

```bash
aws s3api put-bucket-versioning --bucket floci-demo --versioning-configuration Status=Enabled
```

Overwrite the object:

```bash
printf 'jumps over the lazy dog\n' > sample.txt
```

```bash
aws s3api put-object --bucket floci-demo --key notes/sample.txt --body sample.txt
```

Both versions now exist:

```bash
aws s3api list-object-versions --bucket floci-demo --prefix notes/ --query 'Versions[].{Key:Key,Id:VersionId,Latest:IsLatest}' --output table
```

Fetch the older one by ID (substitute a `VersionId` from the table above):

```bash
aws s3api get-object --bucket floci-demo --key notes/sample.txt --version-id VERSION_ID old.txt
```

Versioning cannot be turned off once enabled — only suspended. That's true in
real AWS too, and it's a common source of surprise storage bills.

## 6. Static website hosting

```bash
printf '<h1>Served from S3</h1>\n' > index.html
```

```bash
aws s3api put-object --bucket floci-demo --key index.html --body index.html --content-type text/html
```

```bash
aws s3api put-bucket-website --bucket floci-demo --website-configuration '{"IndexDocument":{"Suffix":"index.html"}}'
```

```bash
curl -s http://localhost:4566/floci-demo/index.html
```

Setting `--content-type` matters: S3 stores whatever you tell it and serves
that back verbatim. Omit it and browsers will download your HTML instead of
rendering it.

## 7. The same thing in code

Both implementations do the identical sequence: create, upload, presign, fetch
via the presigned URL, list versions, clean up.

```bash
cd python && pip install -r requirements.txt && python s3_demo.py
```

```bash
cd node && npm install && node s3-demo.mjs
```

Read [`python/s3_demo.py`](python/s3_demo.py) and note the single Floci-specific
line — the `endpoint_url` argument. Delete it and the same file talks to real
AWS. That is the whole trick.

## Verify

```bash
./verify.sh
```

## Clean up

```bash
aws s3 rb s3://floci-demo --force
```

A versioned bucket won't delete while old versions remain; `--force` removes
them first. In real AWS you'd need a lifecycle rule or an explicit
`delete-objects` over every version.

## How this differs from real AWS

> Populate the rest of this from `docs/COVERAGE.md` after running the smoke
> test. The entries below are the ones to verify first.

- **Bucket names are not globally unique.** Locally you'll never hit
  `BucketAlreadyExists`, which is the single most common real-world S3 error.
- **Presigned URLs point at `localhost:4566`**, not `s3.amazonaws.com`. Share
  one with a classmate and it won't resolve for them.
- **No storage classes, no lifecycle transitions.** Glacier, Intelligent-Tiering
  and expiry rules are either accepted-and-ignored or unsupported. Don't learn
  cost optimisation here.
- **Bucket policies and ACLs are stored but not enforced** — see `00-setup`.
  Public-vs-private is not something these tutorials can teach you honestly.
- **Website hosting is served from the same port**, with no CloudFront, no
  custom domains, and no redirect rules.

## Exercises

1. Upload a file larger than 100 MB using `aws s3 cp` and watch it switch to a
   multipart upload. Then interrupt it halfway and find the orphaned parts with
   `list-multipart-uploads`. Why do these cost money in real AWS?
2. Combine with `00-setup`: write a script that copies every object from one
   bucket to another, preserving content types, using only `s3api` calls. Then
   confirm it's byte-identical.
3. Presigned URLs can authorise uploads too, not just downloads
   (`presign` covers GET; the SDK exposes `generate_presigned_post`). Build a
   flow where a client with no credentials uploads directly to your bucket, and
   work out what stops them from uploading a 10 GB file.
   *Hint: look at the conditions you can attach to the policy.*
