---
title: Coverage matrix
permalink: /docs/COVERAGE/
---

# Floci coverage matrix

What actually works, verified by hand rather than taken from the vendor docs.
This file drives two things: which services get a tutorial, and the "How this
differs from real AWS" section inside each one.

Regenerate the raw data with:

```bash
floci start && ./scripts/smoke-test.sh
```

---

## Environment under test

| | |
|---|---|
| Floci CLI | 0.2.0 |
| Floci image | `floci/floci:latest`, digest `sha256:b3b3a70a…02f506b` |
| Endpoint | `http://localhost:4566` |
| Host OS | Windows 11 |
| Docker | 29.6.2 (Linux containers) |
| AWS CLI | 2.35.12 |
| Date tested | 2026-07-31 |

## Probe results

**38 of 38 probes passed.** Every service below was exercised with the
operations its tutorial actually needs, not merely pinged.

| Service | Operations probed | Result |
|---|---|---|
| S3 | create bucket, put/get object, list v2, presign, versioning, website config | :white_check_mark: 7/7 |
| DynamoDB | create table, put/get item, query, scan | :white_check_mark: 5/5 |
| SQS | create queue, send, receive, queue attributes | :white_check_mark: 4/4 |
| SNS | create topic, publish, list subscriptions | :white_check_mark: 3/3 |
| IAM | create role, attach policy | :white_check_mark: 2/2 |
| STS | get caller identity | :white_check_mark: 1/1 |
| Secrets Manager | create secret, get secret value | :white_check_mark: 2/2 |
| KMS | create key | :white_check_mark: 1/1 |
| Lambda | create function, invoke, get function | :white_check_mark: 3/3 |
| API Gateway | create REST API, create HTTP API (v2) | :white_check_mark: 2/2 |
| Step Functions | create state machine | :white_check_mark: 1/1 |
| EventBridge | create event bus, put rule | :white_check_mark: 2/2 |
| CloudFormation | create stack, describe stacks | :white_check_mark: 2/2 |
| CloudWatch Logs | create log group | :white_check_mark: 1/1 |
| SSM | put parameter | :white_check_mark: 1/1 |
| Bedrock Runtime | client available | :white_check_mark: 1/1 |

Lambda is not simulated - `create-function` plus `invoke` launches a real
Docker container per invocation and returns the handler's actual return value.

## Verdict per service

Legend: :white_check_mark: covered / :warning: partial, tutorial notes the gap / :x: dropped

| Service | Verdict | Tutorial | Notes |
|---|---|---|---|
| S3 | :warning: | `01-s3` | Fully functional except the versioning divergence below |
| DynamoDB | :warning: | `02-dynamodb` | Fully functional; GSI consistency differs - see below |
| Lambda | :warning: | `03-lambda` | Very high fidelity; IAM role unchecked and no cold starts - see below |
| SQS + SNS | :white_check_mark: | `04-messaging` | Fan-out, DLQ redrive, raw delivery, filter policies and FIFO all confirmed |
| API Gateway | :white_check_mark: | `05-serverless-api` | Both REST and HTTP APIs create cleanly |
| IAM / STS / Secrets Manager | :warning: | `06-iam` | Policies stored but enforcement not verified - see below |
| Step Functions / EventBridge | :white_check_mark: | `07-orchestration` | Execution semantics still to be probed |
| CloudFormation | :white_check_mark: | `08-iac` | Stack create and describe confirmed |

## Known divergences from real AWS

Every row here must be quoted in the relevant tutorial's section 9.

| Service | Divergence | Impact on tutorials |
|---|---|---|
| S3 | Overwriting an object that predates `put-bucket-versioning` **destroys its `null` version**. Real AWS retains it alongside the new version; Floci discards it and the original content is unrecoverable. No error is raised. | Documented at length in `01-s3` step 5, and asserted in its `verify.sh` so we detect any change. **This one loses data.** |
| S3 | Bucket names are not globally unique, so `BucketAlreadyExists` never occurs | Noted in `01-s3` |
| S3 | Presigned URLs point at `localhost:4566` and are not shareable | Noted in `01-s3` |
| S3 | boto3 produced a SigV2-style presigned URL (`AWSAccessKeyId`/`Signature`), while the Node SDK produced SigV4. Both are accepted. | Cosmetic; worth mentioning if a student compares the two URLs |
| DynamoDB | **GSIs are synchronous.** An item written to the base table is queryable via a GSI immediately. Real AWS GSIs are eventually consistent and reject strongly-consistent reads outright. | Documented in `02-dynamodb` section 9 and asserted in its `verify.sh`. Code that write-then-reads a GSI works here and fails intermittently in production. |
| DynamoDB | Tables and GSIs go `ACTIVE` instantly; no `CREATING` or `BACKFILLING` state | Noted in `02-dynamodb` - a missing wait-for-active loop never surfaces here |
| DynamoDB | No capacity model, throttling, or hot-partition penalty | Noted in `02-dynamodb` - partition-key design cannot be learned by experiment here |
| Lambda | **The IAM execution role is not validated.** Any ARN is accepted, including one naming a role that does not exist. On real AWS a role missing `logs:*` produces a function that runs but silently writes no logs. | Documented in `03-lambda` section 9. An entire class of real failure is invisible here. |
| Lambda | Functions are `Active` immediately; real AWS returns while still `Pending` and rejects early invocations | Noted in `03-lambda`. `deploy.py` polls for `Active` anyway, since that is the correct production habit. |
| Lambda | No cold starts, concurrency limits, or per-millisecond billing | Noted in `03-lambda` |
| SQS | **Standard queues never reordered or duplicated a message in testing.** Real AWS standard queues explicitly permit both: they are at-least-once with best-effort ordering. Consumers that are not idempotent will pass here and fail in production. | Documented in `04-messaging` section 9. This is an absence of chaos rather than a missing feature, which makes it harder to notice and more dangerous. |
| SQS | `ApproximateNumberOfMessages` is exact, and `receive-message` returned every available message | Noted in `04-messaging`. On real AWS both are approximate because the queue is distributed, so polling loops must not treat an empty response as an empty queue. |
| All | No authentication. Any credential string is accepted. | Noted in `00-setup` |
| All | No cost, quotas, throttling, or rate limiting | Noted in `00-setup` |

## Still to be probed

Not yet tested, and therefore not yet claimed anywhere in the tutorials:

- IAM policy **enforcement** - roles and policies are accepted and stored, but
  whether a denied action is actually blocked is unverified. This is the single
  most important open question, because `06-iam` is worthless if it teaches
  policy authoring that the emulator does not enforce.
- ~~DynamoDB global secondary indexes and conditional writes~~ - probed
  2026-07-31, all working. GSI creation via `update-table`, GSI queries,
  `begins_with` on sort keys, `ConditionalCheckFailedException`, and
  server-side atomic increments all behave correctly.
- ~~SNS to SQS subscription delivery end to end~~ - probed 2026-08-04 and
  working, along with the SNS envelope, `RawMessageDelivery`, filter policies,
  dead letter queue redrive via `maxReceiveCount`, visibility timeout
  redelivery, long polling, and FIFO ordering within a message group.
- Lambda triggered by an API Gateway route
- Step Functions actual execution, not just state machine creation
- CloudFormation stack updates, deletes, and rollback

## Windows toolchain traps

Not Floci behaviour, but they look like it and cost real time. Both are handled
by helpers in `scripts/lib.sh`.

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to load paramfile file:///tmp/...` | Git Bash passes a POSIX path to the AWS CLI, which is a native Windows binary | `native_path()`, which wraps `cygpath -w` |
| `log group does not exist: C:/Program Files/Git/aws/lambda/...` | Git Bash sees the leading slash of `/aws/lambda/...` and rewrites it as a file path | `msys_safe()`, which sets `MSYS_NO_PATHCONV=1` for one command only. It cannot be set globally, because that breaks `native_path()`. |

## Dropped from scope

| Service | Why dropped |
|---|---|
| _(none yet)_ | Every probed service passed |
