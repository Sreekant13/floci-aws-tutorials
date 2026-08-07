#!/usr/bin/env bash
# Verifies every claim made in tutorials/01-s3/README.md.
source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

BUCKET="verify-s3-$$"
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

require_cmd aws curl
require_floci

section "Bucket lifecycle"
assert_ok "create bucket" -- aws s3api create-bucket --bucket "$BUCKET"
BUCKETS="$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null)"
assert_contains "$BUCKETS" "$BUCKET" "bucket appears in list-buckets"

section "Object put / get"
printf 'the quick brown fox\n' > "$TMP/sample.txt"
assert_ok "put object under a prefixed key" -- aws s3api put-object \
  --bucket "$BUCKET" --key notes/sample.txt --body "$TMP/sample.txt"

if aws s3api get-object --bucket "$BUCKET" --key notes/sample.txt "$TMP/got.txt" >/dev/null 2>&1; then
  assert_eq "the quick brown fox" "$(cat "$TMP/got.txt")" "round-tripped content is unchanged"
else
  fail "round-tripped content is unchanged" "get-object failed"
fi

PREFIXED="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix notes/ \
  --query 'Contents[].Key' --output text 2>/dev/null)"
assert_contains "$PREFIXED" "notes/sample.txt" "prefix listing finds the key"

section "Presigned URL"
URL="$(aws s3 presign "s3://$BUCKET/notes/sample.txt" --expires-in 300 2>/dev/null)"
if [ -n "$URL" ]; then
  pass "presign returned a URL"
  # Fetch with every credential stripped -- the signature must carry the auth.
  BODY="$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
          curl -fsS --max-time 10 "$URL" 2>/dev/null)"
  assert_eq "the quick brown fox" "$BODY" "presigned URL serves the object without credentials"
else
  fail "presign returned a URL"
  fail "presigned URL serves the object without credentials" "no URL to test"
fi

section "Versioning"
assert_ok "enable versioning" -- aws s3api put-bucket-versioning \
  --bucket "$BUCKET" --versioning-configuration Status=Enabled

STATUS="$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null)"
assert_eq "Enabled" "$STATUS" "versioning reports as Enabled"

# Objects written AFTER versioning is on are versioned normally.
printf 'draft one\n' > "$TMP/d1.txt"
printf 'draft two\n' > "$TMP/d2.txt"
aws s3api put-object --bucket "$BUCKET" --key drafts/essay.txt --body "$(native_path "$TMP/d1.txt")" >/dev/null 2>&1
aws s3api put-object --bucket "$BUCKET" --key drafts/essay.txt --body "$(native_path "$TMP/d2.txt")" >/dev/null 2>&1

VCOUNT="$(aws s3api list-object-versions --bucket "$BUCKET" --prefix drafts/ \
  --query 'length(Versions)' --output text 2>/dev/null)"
if [ "${VCOUNT:-0}" -ge 2 ] 2>/dev/null; then
  pass "overwriting a post-versioning key kept both versions (found $VCOUNT)"
else
  fail "overwriting a post-versioning key kept both versions" \
       "expected >=2 versions, got ${VCOUNT:-none}"
fi

LATEST="$(aws s3api get-object --bucket "$BUCKET" --key drafts/essay.txt \
  "$(native_path "$TMP/latest.txt")" >/dev/null 2>&1 && cat "$TMP/latest.txt")"
assert_eq "draft two" "$LATEST" "unversioned GET returns the newest version"

# --------------------------------------------------------------------------
# Documented divergence, asserted so we find out if Floci ever changes it.
#
# notes/sample.txt was written BEFORE versioning was enabled, so it carries
# VersionId "null" -- same as real AWS. The divergence is what happens on
# overwrite: real AWS keeps the null version alongside the new one, Floci 0.2.0
# discards it and the original content becomes unrecoverable.
#
# If either assertion below starts failing, Floci has changed behaviour and the
# tutorial's step 5 and section 9 must be rewritten.
# --------------------------------------------------------------------------
NULL_ID="$(aws s3api list-object-versions --bucket "$BUCKET" --prefix notes/ \
  --query 'Versions[0].VersionId' --output text 2>/dev/null)"
assert_eq "null" "$NULL_ID" "pre-versioning object carries VersionId 'null' (matches real AWS)"

printf 'replacement\n' > "$TMP/repl.txt"
aws s3api put-object --bucket "$BUCKET" --key notes/sample.txt \
  --body "$(native_path "$TMP/repl.txt")" >/dev/null 2>&1

REMAINING="$(aws s3api list-object-versions --bucket "$BUCKET" --prefix notes/ \
  --query "length(Versions[?VersionId=='null'])" --output text 2>/dev/null)"
if [ "${REMAINING:-0}" = "0" ]; then
  pass "overwrite drops the null version (Floci divergence still present, tutorial accurate)"
else
  fail "overwrite drops the null version" \
       "null version survived -- Floci may now match real AWS; rewrite step 5 and section 9"
fi

section "Static website hosting"
printf '<h1>Served from S3</h1>\n' > "$TMP/index.html"
assert_ok "upload index.html with an explicit content type" -- aws s3api put-object \
  --bucket "$BUCKET" --key index.html --body "$TMP/index.html" --content-type text/html

assert_ok "configure website hosting" -- aws s3api put-bucket-website --bucket "$BUCKET" \
  --website-configuration '{"IndexDocument":{"Suffix":"index.html"}}'

CT="$(aws s3api head-object --bucket "$BUCKET" --key index.html \
  --query ContentType --output text 2>/dev/null)"
assert_eq "text/html" "$CT" "content type survived the upload"

section "Cleanup path"
assert_ok "force-delete a versioned bucket" -- aws s3 rb "s3://$BUCKET" --force

summary
