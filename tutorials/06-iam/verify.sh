#!/usr/bin/env bash
# Verifies every claim made in tutorials/06-iam/README.md.
#
# Unusual for this repo: several checks below assert that something INSECURE
# happens, because that is the documented behaviour of Floci 0.2.0. If Floci
# ever starts enforcing IAM, those checks fail on purpose and the tutorial has
# to be rewritten. Each one says so where it appears.
source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

S=$$
ROLE="verify-role-$S"
NOTRUST_ROLE="verify-notrust-$S"
USER="verify-user-$S"
BUCKET="verify-iam-$S"
SECRET="verify-secret-$S"
USER_KEY=""

cleanup() {
  aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1
  aws iam delete-role-policy --role-name "$ROLE" --policy-name perms >/dev/null 2>&1
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1
  aws iam delete-role --role-name "$NOTRUST_ROLE" >/dev/null 2>&1
  aws iam delete-user-policy --user-name "$USER" --policy-name denyall >/dev/null 2>&1
  [ -n "$USER_KEY" ] && aws iam delete-access-key --user-name "$USER" --access-key-id "$USER_KEY" >/dev/null 2>&1
  aws iam delete-user --user-name "$USER" >/dev/null 2>&1
  aws secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

require_cmd aws base64
require_floci

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"sts:AssumeRole"}]}'
PERMS='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"*"},{"Effect":"Deny","Action":"s3:DeleteObject","Resource":"*"}]}'

section "Roles and policies are stored correctly"
assert_ok "create role with a trust policy" -- aws iam create-role \
  --role-name "$ROLE" --assume-role-policy-document "$TRUST"
assert_ok "attach a permission policy" -- aws iam put-role-policy \
  --role-name "$ROLE" --policy-name perms --policy-document "$PERMS"

STORED="$(aws iam get-role-policy --role-name "$ROLE" --policy-name perms \
          --query 'PolicyDocument' --output json 2>/dev/null)"
assert_contains "$STORED" "Deny" "the stored policy retains its Deny statement"
assert_contains "$STORED" "s3:DeleteObject" "the stored policy retains the denied action"

section "STS issues temporary credentials"
CREDS="$(aws sts assume-role --role-arn "arn:aws:iam::000000000000:role/$ROLE" \
         --role-session-name my-session \
         --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
         --output text 2>/dev/null)"
AK="$(printf '%s' "$CREDS" | cut -f1)"
SK="$(printf '%s' "$CREDS" | cut -f2)"
ST="$(printf '%s' "$CREDS" | cut -f3)"
if [ -n "$AK" ] && [ "$AK" != "None" ]; then
  pass "assume-role returns credentials with a session token"
else
  fail "assume-role returns credentials with a session token"
  summary
fi

EXPIRY="$(aws sts assume-role --role-arn "arn:aws:iam::000000000000:role/$ROLE" \
          --role-session-name expiry-check --query 'Credentials.Expiration' --output text 2>/dev/null)"
if [ -n "$EXPIRY" ] && [ "$EXPIRY" != "None" ]; then
  pass "credentials carry an expiry timestamp ($EXPIRY)"
else
  fail "credentials carry an expiry timestamp"
fi

ASSUMED_ARN="$(AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" \
               aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
assert_contains "$ASSUMED_ARN" "assumed-role/$ROLE" "identity switches to the assumed role"

# Documented divergence: real AWS puts the requested session name in the ARN.
if printf '%s' "$ASSUMED_ARN" | grep -q "my-session"; then
  fail "role session name is discarded, as documented" \
       "the session name now appears in the ARN; Floci may match real AWS, update section 9"
else
  pass "role session name is discarded, as documented (got '$ASSUMED_ARN')"
fi

section "IAM is not enforced (documented, and asserted so we notice a change)"
aws s3api create-bucket --bucket "$BUCKET" >/dev/null 2>&1
printf 'delete me\n' > "$BUCKET.tmp"
aws s3api put-object --bucket "$BUCKET" --key f.txt \
  --body "$(native_path "$PWD/$BUCKET.tmp")" >/dev/null 2>&1
rm -f "$BUCKET.tmp"

# The role policy explicitly denies s3:DeleteObject. Real AWS returns AccessDenied.
DEL="$(AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" \
       aws s3api delete-object --bucket "$BUCKET" --key f.txt 2>&1)"
if printf '%s' "$DEL" | grep -qi "AccessDenied\|not authorized"; then
  fail "an explicitly denied action still succeeds, as documented" \
       "the action was DENIED; Floci now enforces IAM, rewrite this tutorial"
else
  pass "an explicitly denied action still succeeds, as documented"
fi

# Credentials that were never issued by anything.
FAKE="$(AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKE AWS_SECRET_ACCESS_KEY=nonsense AWS_SESSION_TOKEN= \
        aws s3api list-buckets 2>&1)"
if printf '%s' "$FAKE" | grep -qi "InvalidClientTokenId\|SignatureDoesNotMatch"; then
  fail "fabricated credentials are accepted, as documented" \
       "the credentials were REJECTED; Floci now validates signatures, rewrite this tutorial"
else
  pass "fabricated credentials are accepted, as documented"
fi

# A role that was never created.
GHOST="$(aws sts assume-role --role-arn "arn:aws:iam::000000000000:role/does-not-exist-$S" \
         --role-session-name ghost --query 'Credentials.AccessKeyId' --output text 2>&1)"
if printf '%s' "$GHOST" | grep -qi "NoSuchEntity\|AccessDenied\|error"; then
  fail "assuming a nonexistent role succeeds, as documented" \
       "it was REJECTED; Floci now validates role existence, rewrite this tutorial"
else
  pass "assuming a nonexistent role succeeds, as documented"
fi

# A trust policy that denies everyone.
aws iam create-role --role-name "$NOTRUST_ROLE" --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":{"AWS":"*"},"Action":"sts:AssumeRole"}]}' \
  >/dev/null 2>&1
NOTRUST="$(aws sts assume-role --role-arn "arn:aws:iam::000000000000:role/$NOTRUST_ROLE" \
           --role-session-name nt --query 'Credentials.AccessKeyId' --output text 2>&1)"
if printf '%s' "$NOTRUST" | grep -qi "AccessDenied\|error"; then
  fail "a deny-all trust policy is ignored, as documented" \
       "it was REJECTED; Floci now evaluates trust policies, rewrite this tutorial"
else
  pass "a deny-all trust policy is ignored, as documented"
fi

# An IAM user whose own policy denies everything.
aws iam create-user --user-name "$USER" >/dev/null 2>&1
aws iam put-user-policy --user-name "$USER" --policy-name denyall \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"*","Resource":"*"}]}' \
  >/dev/null 2>&1
UKEY="$(aws iam create-access-key --user-name "$USER" \
        --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text 2>/dev/null)"
USER_KEY="$(printf '%s' "$UKEY" | cut -f1)"
USER_SECRET="$(printf '%s' "$UKEY" | cut -f2)"
UOUT="$(AWS_ACCESS_KEY_ID="$USER_KEY" AWS_SECRET_ACCESS_KEY="$USER_SECRET" AWS_SESSION_TOKEN= \
        aws s3api list-buckets 2>&1)"
if printf '%s' "$UOUT" | grep -qi "AccessDenied\|not authorized"; then
  fail "a deny-all user policy is ignored, as documented" \
       "it was DENIED; Floci now enforces user policies, rewrite this tutorial"
else
  pass "a deny-all user policy is ignored, as documented"
fi

section "The policy simulator evaluates correctly"
sim() {
  aws iam simulate-principal-policy \
    --policy-source-arn "arn:aws:iam::000000000000:role/$ROLE" \
    --action-names "$1" --resource-arns "$2" \
    --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null
}
assert_eq "allowed"      "$(sim s3:GetObject "arn:aws:s3:::$BUCKET/f.txt")" \
  "an allowed action evaluates to allowed"
assert_eq "explicitDeny" "$(sim s3:DeleteObject "arn:aws:s3:::$BUCKET/f.txt")" \
  "an explicitly denied action evaluates to explicitDeny"
assert_eq "implicitDeny" "$(sim ec2:TerminateInstances "*")" \
  "an unmentioned action evaluates to implicitDeny"

section "Secrets Manager works properly"
assert_ok "create secret" -- aws secretsmanager create-secret \
  --name "$SECRET" --secret-string '{"user":"admin","pass":"s3cret"}'
V1="$(aws secretsmanager get-secret-value --secret-id "$SECRET" --query SecretString --output text 2>/dev/null)"
assert_contains "$V1" "s3cret" "secret reads back correctly"

aws secretsmanager put-secret-value --secret-id "$SECRET" \
  --secret-string '{"user":"admin","pass":"rotated"}' >/dev/null 2>&1
V2="$(aws secretsmanager get-secret-value --secret-id "$SECRET" --query SecretString --output text 2>/dev/null)"
assert_contains "$V2" "rotated" "rotated secret returns the new value"

PREV="$(aws secretsmanager get-secret-value --secret-id "$SECRET" --version-stage AWSPREVIOUS \
        --query SecretString --output text 2>/dev/null)"
assert_contains "$PREV" "s3cret" "AWSPREVIOUS still returns the old value"

section "KMS does not actually encrypt (documented)"
KID="$(aws kms create-key --description "verify-$S" --query 'KeyMetadata.KeyId' --output text 2>/dev/null)"
if [ -n "$KID" ] && [ "$KID" != "None" ]; then
  pass "kms create-key returns a key id"
  PLAIN="ATTACK_AT_DAWN"
  CT="$(aws kms encrypt --key-id "$KID" --plaintext "$(printf '%s' "$PLAIN" | base64)" \
        --query CiphertextBlob --output text 2>/dev/null)"
  DECODED="$(printf '%s' "$CT" | base64 -d 2>/dev/null)"
  assert_contains "$DECODED" "kms:v2:" "the ciphertext blob is a plain labelled envelope"

  # Recover the plaintext with no key at all.
  TAIL="$(printf '%s' "$DECODED" | awk -F: '{print $NF}')"
  RECOVERED="$(printf '%s' "$TAIL" | base64 -d 2>/dev/null)"
  if [ "$RECOVERED" = "$PLAIN" ]; then
    pass "plaintext is recoverable from the ciphertext without the key, as documented"
  else
    fail "plaintext is recoverable from the ciphertext without the key, as documented" \
         "could not recover it; Floci may now encrypt properly, update section 6"
  fi
else
  fail "kms create-key returns a key id"
fi

summary
