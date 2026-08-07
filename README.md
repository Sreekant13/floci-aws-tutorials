# Floci-based tutorials on popular AWS services

Hands-on AWS tutorials that run entirely on your laptop. **No AWS account, no
credit card, no credentials, no bill.**

**Read them here: <https://sreekant13.github.io/floci-aws-tutorials/>**

Each tutorial uses [Floci](https://floci.io/), an MIT-licensed local cloud
emulator that speaks the real AWS wire protocol on `localhost:4566`. You write
ordinary `aws` CLI commands and ordinary boto3 or AWS SDK v3 code. The only
difference from real AWS is one endpoint override, and every tutorial points at
exactly where that line is.

---

## Quick start

Install Floci. Windows:

```powershell
irm https://floci.io/install.ps1 | iex
```

macOS and Linux:

```bash
curl -fsSL https://floci.io/install.sh | sh
```

Start it and point your shell at it:

```bash
floci start && eval $(floci env)
```

```bash
aws s3 mb s3://hello-floci && aws s3 ls
```

If that listed your bucket, start at [`00-setup`](tutorials/00-setup/).

You need **Docker** (Floci is a container, and Lambda launches more containers),
**AWS CLI v2** (v1 ignores `AWS_ENDPOINT_URL`), and **Python 3.9+** and
**Node 18+** for the SDK examples.

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
| 08 | Infrastructure as code | CloudFormation | | _planned_ |

**150 checks passing**, on Windows locally and on Ubuntu in CI.

## Why local emulation

Learning AWS the normal way means an account, a card on file, and a standing
risk of forgetting to tear something down. That friction is the single biggest
barrier to students actually *practising* cloud work rather than reading about
it.

Floci removes it. It starts in about 24ms, idles at roughly 13 MiB, accepts any
credentials, and covers 68 AWS services. Lambda, RDS, EC2, ECS and OpenSearch
are not emulated at all, since Floci launches real engines in Docker, so those
behave very close to production.

The trade is fidelity. Emulation is not the real thing, and pretending otherwise
would make these tutorials actively harmful. So **every tutorial ends with a
"How this differs from real AWS" section**, populated from
[`docs/COVERAGE.md`](docs/COVERAGE.md), which records what was tested by hand
rather than what the vendor documentation claims.

## What the testing actually found

Every tutorial ships a `verify.sh` that runs its own documented commands and
fails loudly. Writing those scripts turned up real divergences that are not
documented anywhere, and each one is now written into the relevant tutorial and
asserted in its test, so a future Floci release that changes the behaviour will
break the build rather than quietly make the tutorial wrong.

| Service | What differs | Why it matters |
|---|---|---|
| S3 | Overwriting an object that predates `put-bucket-versioning` destroys its `null` version. Real AWS keeps it. | Silent data loss, with no error raised. The first draft of tutorial 01 walked students straight into it. |
| DynamoDB | Global secondary indexes are updated synchronously. Real AWS indexes are eventually consistent. | Write-then-immediately-query works locally and fails intermittently in production. |
| SQS | Standard queues never reordered or duplicated a message in testing. Real AWS explicitly permits both. | A consumer that is not idempotent passes here and fails in production. An absence of chaos is harder to notice than a missing feature. |
| Lambda | The IAM execution role is not validated. Any ARN is accepted. | On real AWS a role missing log permissions produces a function that runs but writes nothing. That whole failure mode is invisible here. |
| IAM | Policies are stored faithfully and evaluated correctly by the simulator, but **never enforced on a real call**. An explicit `Deny` is ignored, as are credentials invented on the spot. | The largest gap in the series, verified across seven cases. A security control that appears present and does nothing is harder to spot than one that is missing. |
| KMS | `encrypt` does not encrypt. The ciphertext is a label wrapped around base64 of the plaintext, recoverable with no key. | Anything put through KMS locally is readable by anyone holding the output. |
| Step Functions | `Retry` is accepted and never executed. A Task set to retry three times runs exactly once. | Retry logic that looks correct locally behaves completely differently in production, including timing and the idempotency each step then needs. |

The full list, including what remains unprobed, is in
[`docs/COVERAGE.md`](docs/COVERAGE.md).

## How this repo is built

- **[`docs/TEMPLATE.md`](docs/TEMPLATE.md)** is the structure every tutorial
  follows. Read it before writing a new one.
- **[`docs/COVERAGE.md`](docs/COVERAGE.md)** is the hand-verified support matrix.
  It is written first, and it decides what gets a tutorial at all.
- **`scripts/smoke-test.sh`** probes candidate services with the operations a
  tutorial would actually need, and emits the raw matrix.
- **`scripts/lib.sh`** holds the assertion helpers every `verify.sh` uses, plus
  two Windows workarounds described below.
- **`tutorials/NN-*/verify.sh`** runs that tutorial's own commands headless and
  exits non-zero on failure.
- **`scripts/verify-all.sh`** runs every one of them.
- **`.github/workflows/verify.yml`** runs the lot on every push and once a week,
  so a new Floci release cannot silently break a tutorial.

Run everything locally:

```bash
floci start && ./scripts/verify-all.sh
```

## Repository layout

```
index.md                     landing page for the published site
_config.yml                  Jekyll config, stock theme, no customisation
_includes/head-custom.html   renders mermaid diagrams on GitHub Pages

docs/
  TEMPLATE.md                the structure every tutorial follows
  COVERAGE.md                hand-verified support matrix and divergences

scripts/
  lib.sh                     assertion helpers, native_path, msys_safe
  smoke-test.sh              service probes, emits the raw coverage matrix
  verify-all.sh              runs every tutorial's verify.sh

tutorials/
  00-setup/                  README.md, verify.sh
  01-s3/                     README.md, verify.sh, python/, node/
  02-dynamodb/               README.md, verify.sh, python/, node/
  03-lambda/                 README.md, verify.sh, function/, python/, node/
  04-messaging/              README.md, verify.sh, python/, node/
  05-serverless-api/         README.md, verify.sh, function/, python/, node/
  06-iam/                    README.md, verify.sh, python/, node/
  07-orchestration/          README.md, verify.sh, function/, python/, node/

.github/workflows/verify.yml
```

`03-lambda/function/` holds the handler that actually gets uploaded to Lambda.
It is separate from `python/` because it is the deployed artifact rather than a
client script.

## Notes for Windows

Both of these look like Floci bugs and are not. Both are handled by helpers in
`scripts/lib.sh`, and both cost real time to diagnose the first time.

**Paths passed to the AWS CLI.** Git Bash hands over a POSIX path such as
`/tmp/fn.zip`, but the AWS CLI is a native Windows binary and cannot resolve it.
The symptom is `Unable to load paramfile`. Use `native_path()`, which wraps
`cygpath -w`.

**Arguments that start with a slash but are not paths.** CloudWatch log group
names look like `/aws/lambda/my-function`. Git Bash rewrites that into
`C:/Program Files/Git/aws/lambda/my-function` before the CLI sees it, and you
are told the log group does not exist. Use `msys_safe()`, which sets
`MSYS_NO_PATHCONV=1` for a single command. It cannot be set globally, because
that breaks the conversion `native_path()` depends on.

## Contributing a tutorial

1. Probe the service first: `./scripts/smoke-test.sh <service>`. Never document
   behaviour from vendor documentation.
2. Record what you found in `docs/COVERAGE.md`.
3. Copy `docs/TEMPLATE.md` to `tutorials/NN-name/README.md` and fill it in.
4. Write `verify.sh` covering every claim the README makes.
5. Run it more than once. Several bugs in this repo only appeared on a second
   or third consecutive run.
6. Confirm `./scripts/verify-all.sh` passes from a clean `floci start`.

When a verify script disagrees with the tutorial, work out which one is wrong
before fixing either. Twice the answer was the tutorial, and both times that
produced the most useful page in the repository.

House style: no em dashes, and no contractions.

## Safety

Floci needs no credentials and should never be exposed beyond `localhost`. It
performs no real authorisation, so any request that looks well formed succeeds.
Never point these tutorials at a real AWS endpoint, and never put real
credentials in this repository.

---

Built by Sreekant Baheti as a research assistant project under
Dr. Saty Raghavachary, Computer Science Department, University of Southern
California.
