#!/usr/bin/env bash
# Verifies the local environment is ready for every other tutorial.
source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

BUCKET="verify-setup-$$"
TMP="$(mktemp -d)"
cleanup() {
  # set -e is inherited by the EXIT trap. Without this, a single failing
  # teardown call aborts the trap and the script exits with that error,
  # reporting a failure even when every check passed.
  set +e
  aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

section "Toolchain"
require_cmd aws curl
assert_ok "aws CLI is installed" -- aws --version

AWS_MAJOR="$(aws --version 2>&1 | sed -n 's#^aws-cli/\([0-9]*\).*#\1#p')"
if [ "${AWS_MAJOR:-0}" -ge 2 ]; then
  pass "aws CLI is v2 or newer (found v$AWS_MAJOR)"
else
  fail "aws CLI is v2 or newer" "found v${AWS_MAJOR:-unknown}; v1 ignores AWS_ENDPOINT_URL"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  pass "Docker daemon is running"
else
  fail "Docker daemon is running" "Lambda, RDS and EC2 tutorials will not work without it"
fi

section "Floci reachability"
require_floci
pass "Floci responds at $FLOCI_ENDPOINT"

section "Credentials resolve"
assert_ok "sts get-caller-identity succeeds" -- aws sts get-caller-identity
assert_eq "http://localhost:4566" "${AWS_ENDPOINT_URL}" "AWS_ENDPOINT_URL points at Floci"

section "S3 round-trip"
assert_ok "create bucket" -- aws s3api create-bucket --bucket "$BUCKET"

printf 'hello floci\n' > "$TMP/in.txt"
assert_ok "upload object" -- aws s3api put-object \
  --bucket "$BUCKET" --key hello.txt --body "$TMP/in.txt"

if aws s3api get-object --bucket "$BUCKET" --key hello.txt "$TMP/out.txt" >/dev/null 2>&1; then
  assert_eq "hello floci" "$(cat "$TMP/out.txt")" "downloaded content matches what was uploaded"
else
  fail "downloaded content matches what was uploaded" "get-object failed"
fi

LISTED="$(aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].Key' --output text 2>/dev/null)"
assert_contains "$LISTED" "hello.txt" "object appears in bucket listing"

assert_ok "delete object" -- aws s3api delete-object --bucket "$BUCKET" --key hello.txt

summary
