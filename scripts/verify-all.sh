#!/usr/bin/env bash
# Runs every tutorial's verify.sh in order. This is what CI executes.
#
#   floci start
#   ./scripts/verify-all.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=()
RAN=0

for dir in "$REPO"/tutorials/*/; do
  script="$dir/verify.sh"
  [ -f "$script" ] || continue
  name="$(basename "$dir")"
  RAN=$((RAN + 1))

  printf '\n=========================================================\n'
  printf '  %s\n' "$name"
  printf '=========================================================\n'

  if bash "$script"; then
    printf '\n  --> %s OK\n' "$name"
  else
    printf '\n  --> %s FAILED\n' "$name"
    FAILED+=("$name")
  fi
done

printf '\n=========================================================\n'
if [ ${#FAILED[@]} -eq 0 ]; then
  printf '  All %d tutorials verified.\n' "$RAN"
  printf '=========================================================\n'
  exit 0
fi

printf '  %d of %d tutorials FAILED:\n' "${#FAILED[@]}" "$RAN"
for f in "${FAILED[@]}"; do printf '    - %s\n' "$f"; done
printf '=========================================================\n'
exit 1
