#!/usr/bin/env bash
# Shared helpers for every tutorial's verify.sh.
#
# Source this at the top of a verify script:
#   source "$(dirname "$0")/../../scripts/lib.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Floci connection settings. All credentials are dummy values -- Floci accepts
# anything. Never put real AWS credentials in this repo.
# ---------------------------------------------------------------------------
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
export AWS_PAGER=""

FLOCI_ENDPOINT="$AWS_ENDPOINT_URL"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  _RED=$'\033[31m'; _GRN=$'\033[32m'; _YEL=$'\033[33m'; _BLD=$'\033[1m'; _RST=$'\033[0m'
else
  _RED=""; _GRN=""; _YEL=""; _BLD=""; _RST=""
fi

_PASS_COUNT=0
_FAIL_COUNT=0
_FAILED_CHECKS=()

section() { printf '\n%s==> %s%s\n' "$_BLD" "$*" "$_RST"; }
info()    { printf '    %s\n' "$*"; }
warn()    { printf '    %sWARN%s %s\n' "$_YEL" "$_RST" "$*"; }

# pass "check name"
pass() {
  _PASS_COUNT=$((_PASS_COUNT + 1))
  printf '    %sPASS%s %s\n' "$_GRN" "$_RST" "$1"
}

# fail "check name" [detail]
fail() {
  _FAIL_COUNT=$((_FAIL_COUNT + 1))
  _FAILED_CHECKS+=("$1")
  printf '    %sFAIL%s %s\n' "$_RED" "$_RST" "$1"
  [ $# -gt 1 ] && printf '         %s\n' "$2"
  return 0
}

# assert_eq "expected" "actual" "check name"
assert_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3" "expected [$1], got [$2]"
  fi
}

# assert_contains "haystack" "needle" "check name"
assert_contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *)      fail "$3" "expected output to contain [$2]" ;;
  esac
}

# assert_ok "check name" -- <command...>
# Runs the command, passes if it exits 0.
assert_ok() {
  local name="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local out
  if out="$("$@" 2>&1)"; then
    pass "$name"
  else
    fail "$name" "$(printf '%s' "$out" | head -3)"
  fi
}

# ---------------------------------------------------------------------------
# Path translation
#
# On Windows the AWS CLI is a native .exe, but these scripts run under Git Bash
# / MSYS. A path like /tmp/foo is meaningless to the CLI, so any argument using
# file:// or fileb:// must be converted first, or you get a misleading
# "Unable to load paramfile" that looks like a service failure.
#
#   aws lambda create-function --zip-file "fileb://$(native_path "$WORK/fn.zip")"
#
# No-op on Linux and macOS.
# ---------------------------------------------------------------------------
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

# ---------------------------------------------------------------------------
# The opposite problem.
#
# Some AWS arguments are not paths but start with a slash, most notably
# CloudWatch log group names like /aws/lambda/my-function. Git Bash sees the
# leading slash and helpfully rewrites it into C:/Program Files/Git/aws/...
# before the CLI ever sees it, producing a baffling "log group does not exist".
#
# Wrap those calls so the argument is passed through untouched:
#
#   msys_safe aws logs describe-log-streams --log-group-name "/aws/lambda/$FN"
#
# Note this cannot be turned on globally: it would also stop the conversion
# that native_path relies on. Apply it per command.
# ---------------------------------------------------------------------------
msys_safe() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$@"
}

# ---------------------------------------------------------------------------
# Floci lifecycle
# ---------------------------------------------------------------------------

# Fail fast with a useful message if the emulator is not up.
require_floci() {
  if ! curl -fsS --max-time 5 "$FLOCI_ENDPOINT/_floci/health" >/dev/null 2>&1 \
     && ! curl -fsS --max-time 5 "$FLOCI_ENDPOINT" >/dev/null 2>&1; then
    printf '%sFloci is not reachable at %s%s\n' "$_RED" "$FLOCI_ENDPOINT" "$_RST" >&2
    printf 'Start it with:  floci start\n' >&2
    exit 1
  fi
}

# Fail fast if a required CLI is missing.
require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      printf '%sRequired command not found: %s%s\n' "$_RED" "$c" "$_RST" >&2
      exit 1
    }
  done
}

# ---------------------------------------------------------------------------
# Summary -- call at the end of a verify script.
# Exits non-zero if anything failed, so CI catches it.
# ---------------------------------------------------------------------------
summary() {
  printf '\n%s---------------------------------------------%s\n' "$_BLD" "$_RST"
  printf '%s  %d passed, %d failed%s\n' "$_BLD" "$_PASS_COUNT" "$_FAIL_COUNT" "$_RST"
  if [ "$_FAIL_COUNT" -gt 0 ]; then
    printf '\n  Failed checks:\n'
    for c in "${_FAILED_CHECKS[@]}"; do printf '    - %s\n' "$c"; done
    printf '\n'
    exit 1
  fi
  printf '\n'
  exit 0
}
