# Floci coverage matrix

What actually works, verified by hand rather than taken from the docs. This
file drives two things: which services get a tutorial, and the "How this
differs from real AWS" section inside each one.

**Status: not yet populated.** Run the Day-1 reconnaissance first:

```bash
floci start
./scripts/smoke-test.sh
```

That writes a timestamped raw matrix to `scripts/out/`. Curate the meaningful
rows into the tables below -- the raw output is gitignored, this file is the
committed record.

---

## Environment under test

| | |
|---|---|
| Floci version | _fill in_ |
| Endpoint | `http://localhost:4566` |
| Host OS | Windows 11 |
| Docker | _fill in_ |
| AWS CLI | _fill in_ |
| Date tested | _fill in_ |

## Verdict per service

Legend: :white_check_mark: covered / :warning: partial, tutorial notes the gap / :x: dropped

| Service | Verdict | Tutorial | Notes |
|---|---|---|---|
| S3 | | `01-s3` | |
| DynamoDB | | `02-dynamodb` | |
| Lambda | | `03-lambda` | |
| SQS + SNS | | `04-messaging` | |
| API Gateway | | `05-serverless-api` | |
| IAM / STS / Secrets Manager | | `06-iam` | |
| Step Functions / EventBridge | | `07-orchestration` | |
| CloudFormation | | `08-iac` | |

## Known divergences from real AWS

Every row here should end up quoted in some tutorial's section 9.

| Service | Divergence | Impact on tutorials |
|---|---|---|
| _(fill in from smoke test)_ | | |

## Dropped from scope

Services probed and rejected, with the reason. Recording these is useful --
it tells the next person not to re-investigate.

| Service | Why dropped |
|---|---|
| | |
