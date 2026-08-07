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

| # | Topic | Services | Checks | Time |
|---|---|---|---|---|
| [00](tutorials/00-setup/) | Setup | - | 11 | 20 min |
| [01](tutorials/01-s3/) | Object storage | S3 | 17 | 50 min |
| [02](tutorials/02-dynamodb/) | Key-value data | DynamoDB | 16 | 60 min |
| [03](tutorials/03-lambda/) | Serverless functions | Lambda | 15 | 60 min |
| [04](tutorials/04-messaging/) | Queues and pub/sub | SQS, SNS | 21 | 60 min |
| [05](tutorials/05-serverless-api/) | A full REST API | API Gateway + Lambda + DynamoDB | 23 | 75 min |
| [06](tutorials/06-iam/) | Identity and secrets | IAM, STS, Secrets Manager | 23 | 70 min |
| [07](tutorials/07-orchestration/) | Orchestration | Step Functions, EventBridge | 24 | 70 min |
| 08 | Infrastructure as code | CloudFormation | | _in progress_ |

Every tutorial has command line steps, the same thing in both boto3 and the
Node SDK, three exercises, and an honest account of where the emulator and real
AWS part company. **150 checks passing** across the eight that are done.

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

## What the testing actually found

Writing those verification scripts turned up real differences that are not
documented anywhere. Each one is now written into the relevant tutorial and
asserted in its test, so a future Floci release that changes the behaviour will
break the build rather than quietly make the tutorial wrong.

| Service | What differs | Why it matters |
|---|---|---|
| S3 | Overwriting an object that predates versioning destroys its `null` version. Real AWS keeps it. | Silent data loss, with no error raised. |
| DynamoDB | Secondary indexes update instantly. Real AWS indexes are eventually consistent. | Write-then-immediately-query works here and fails intermittently in production. |
| SQS | Standard queues never reordered or duplicated a message. Real AWS permits both. | A consumer that is not idempotent passes here and fails in production. |
| Lambda | The IAM execution role is not validated at all. | On real AWS a role missing log permissions gives you a function that runs but writes nothing. |
| IAM | Policies are stored and correctly simulated, but **never enforced**. An explicit `Deny` is ignored, and invented credentials work. | The largest gap in the series. A security control that looks present and does nothing. |
| KMS | `encrypt` does not encrypt. The plaintext is recoverable from the ciphertext with no key. | Anything you put through KMS locally is readable by anyone holding the output. |

## How the tutorials are built

Every tutorial ships a `verify.sh` that runs its own documented commands
headless and exits non-zero if any of them stop working. Continuous integration
runs all of them on every push and once a week, so a new Floci release cannot
quietly break a tutorial without anyone noticing.

Source: [github.com/Sreekant13/floci-aws-tutorials](https://github.com/Sreekant13/floci-aws-tutorials)

Licensed [MIT](https://github.com/Sreekant13/floci-aws-tutorials/blob/main/LICENSE).
Use them, fork them, teach from them.

## Before you go

You are about to spend a few hours breaking a cloud that cannot bill you. That
is a genuinely rare position to be in, so please misuse it. Delete the thing you
were told not to delete. Feed the function garbage. Run a `verify.sh` and try to
make it fail. The worst outcome is that you type `floci stop` and everything you
did evaporates for free.

Nothing here has a credit card attached, so there is no such thing as an
expensive mistake. Go and make some cheap ones.

If any of this was useful, a
[star](https://github.com/Sreekant13/floci-aws-tutorials) takes one click and
helps the next student find it. If you know somebody who has been putting off
learning AWS because of the credit card form, send them this way.

Good luck, and enjoy the low floor.

## Say hello

Built by **Sreekant Baheti**.

- Portfolio: **[sreekantbaheti.com](https://sreekantbaheti.com/)**
- GitHub: [@Sreekant13](https://github.com/Sreekant13)

Found a typo, a broken command, or a place where Floci does something none of
these pages warn you about?
[Open an issue](https://github.com/Sreekant13/floci-aws-tutorials/issues).
Turning up a new divergence is the single most valuable thing you can contribute
here, and I will credit you for it on the page you break.

---

Built as a research assistant project under Dr. Saty Raghavachary, Computer
Science Department, University of Southern California.
