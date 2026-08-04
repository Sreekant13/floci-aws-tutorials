---
title: Floci AWS Tutorials
---

Hands-on AWS tutorials that run entirely on your laptop.
**No AWS account, no credit card, no credentials, no bill.**

Each tutorial uses [Floci](https://floci.io/) - an MIT-licensed local cloud
emulator that speaks the real AWS wire protocol on `localhost:4566`. You write
ordinary `aws` CLI commands and ordinary boto3 / AWS SDK v3 code. The only
difference from real AWS is a single endpoint override, and every tutorial
points at exactly where that line is.

## Start here

```bash
irm https://floci.io/install.ps1 | iex
```

```bash
floci start && eval $(floci env)
```

```bash
aws s3 mb s3://hello-floci && aws s3 ls
```

If that listed your bucket, you are ready.

## Tutorials

| # | Topic | Services | Time |
|---|---|---|---|
| [00](tutorials/00-setup/) | Setup | - | 20 min |
| [01](tutorials/01-s3/) | Object storage | S3 | 50 min |
| [02](tutorials/02-dynamodb/) | Key-value data | DynamoDB | 60 min |
| [03](tutorials/03-lambda/) | Serverless functions | Lambda | 60 min |
| [04](tutorials/04-messaging/) | Queues and pub/sub | SQS, SNS | 60 min |
| 05 | A full REST API | API Gateway + Lambda + DynamoDB | _in progress_ |
| 06 | Identity and secrets | IAM, STS, Secrets Manager | _in progress_ |
| 07 | Orchestration | Step Functions, EventBridge | _in progress_ |
| 08 | Infrastructure as code | CloudFormation | _in progress_ |

## Why local emulation

Learning AWS the normal way means an account, a card on file, and a standing
risk of forgetting to tear something down. That friction is the single biggest
barrier to actually *practising* cloud work rather than reading about it.

Floci removes it. It starts in roughly 24ms, idles at about 13 MiB, accepts any
credentials, and covers 68 AWS services. Lambda, RDS, EC2, ECS and OpenSearch
are not emulated at all - Floci launches real engines in Docker - so those
behave very close to production.

The trade is fidelity. Emulation is not the real thing, and pretending
otherwise would make these tutorials actively harmful. So **every tutorial ends
with a "How this differs from real AWS" section**, populated from a
[coverage matrix](docs/COVERAGE.md) that records what was tested by hand rather
than what the vendor documentation claims.

## How the tutorials are built

Every tutorial ships a `verify.sh` that runs its own documented commands
headless and exits non-zero if any of them stop working. Continuous integration
runs all of them on every push and once a week, so a new Floci release cannot
quietly break a tutorial without anyone noticing.

Source: [github.com/Sreekant13/floci-aws-tutorials](https://github.com/Sreekant13/floci-aws-tutorials)

---

Built by Sreekant Baheti as a research assistant project under
Dr. Saty Raghavachary, Computer Science Department, University of Southern
California.
