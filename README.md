# Floci-based tutorials on popular AWS services

Hands-on AWS tutorials that run entirely on your laptop. **No AWS account, no
credit card, no credentials, no bill.**

Each tutorial uses [Floci](https://floci.io/) - an MIT-licensed local cloud
emulator that speaks the real AWS wire protocol on `localhost:4566`. You write
ordinary `aws` CLI commands and ordinary boto3 / AWS SDK v3 code. The only
difference from real AWS is one endpoint override, and every tutorial points
at exactly where that line is.

---

## Quick start

```bash
irm https://floci.io/install.ps1 | iex
```

```bash
floci start && eval $(floci env)
```

```bash
aws s3 mb s3://hello-floci && aws s3 ls
```

If that listed your bucket, start at [`00-setup`](tutorials/00-setup/).

## Tutorials

| # | Topic | Services | Time |
|---|---|---|---|
| [00](tutorials/00-setup/) | Setup | - | 20 min |
| [01](tutorials/01-s3/) | Object storage | S3 | 50 min |
| [02](tutorials/02-dynamodb/) | Key-value data | DynamoDB | 60 min |
| [03](tutorials/03-lambda/) | Serverless functions | Lambda | 60 min |
| [04](tutorials/04-messaging/) | Queues and pub/sub | SQS, SNS | 60 min |
| 05 | A full REST API | API Gateway + Lambda + DynamoDB | _planned_ |
| 06 | Identity and secrets | IAM, STS, Secrets Manager | _planned_ |
| 07 | Orchestration | Step Functions, EventBridge | _planned_ |
| 08 | Infrastructure as code | CloudFormation | _planned_ |

## Why local emulation

Learning AWS the normal way means an account, a card on file, and a standing
risk of forgetting to tear something down. That friction is the single biggest
barrier to students actually *practising* cloud work rather than reading about
it.

Floci removes it. It starts in ~24ms, idles at ~13 MiB, accepts any credentials,
and runs 68 AWS services. Lambda, RDS, EC2, ECS and OpenSearch are not emulated
at all - Floci launches real engines in Docker - so those behave very close to
production.

The trade is fidelity. Emulation is not the real thing, and pretending
otherwise would make these tutorials actively harmful. So **every tutorial ends
with a "How this differs from real AWS" section**, populated from
[`docs/COVERAGE.md`](docs/COVERAGE.md), which records what was tested by hand
rather than what the vendor docs claim.

## How this repo is built

- **[`docs/TEMPLATE.md`](docs/TEMPLATE.md)** - the structure every tutorial
  follows. Read this before writing a new one.
- **[`docs/COVERAGE.md`](docs/COVERAGE.md)** - the hand-verified support matrix.
  Written first; it decides what gets a tutorial.
- **`scripts/smoke-test.sh`** - probes candidate services with the operations a
  tutorial would actually need, and emits the raw matrix.
- **`tutorials/NN-*/verify.sh`** - runs that tutorial's commands headless and
  exits non-zero on failure.
- **`scripts/verify-all.sh`** - runs every one of them.
- **`.github/workflows/verify.yml`** - runs the lot on push and weekly, so a
  new Floci release cannot silently break a tutorial.

Run everything locally:

```bash
floci start && ./scripts/verify-all.sh
```

## Repository layout

```
docs/          TEMPLATE.md, COVERAGE.md
scripts/       smoke-test.sh, verify-all.sh, lib.sh
tutorials/
  00-setup/    README.md, verify.sh
  01-s3/       README.md, verify.sh, python/, node/
.github/workflows/verify.yml
```

## Contributing a tutorial

1. Probe the service first: `./scripts/smoke-test.sh <service>`.
2. Record what you found in `docs/COVERAGE.md`.
3. Copy `docs/TEMPLATE.md` to `tutorials/NN-name/README.md` and fill it in.
4. Write `verify.sh` covering every claim the README makes.
5. Confirm `./scripts/verify-all.sh` passes from a clean `floci start`.

## Safety

Floci needs no credentials and should never be exposed beyond `localhost`. It
performs no real authorisation - any request that looks well-formed succeeds.
Never point these tutorials at a real AWS endpoint, and never put real
credentials in this repository.

---

Built by Sreekant Baheti as a research assistant project under
Dr. Saty Raghavachary, Computer Science Department, University of Southern
California.
