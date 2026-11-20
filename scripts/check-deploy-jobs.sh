#!/usr/bin/env bash
set -euo pipefail

WORKFLOW=.github/workflows/deploy-explicit.yml
MISSING=0
for DIR in src/*/; do
  MODULE="$(basename "$DIR")"
  if ! grep -qx "  $MODULE:" "$WORKFLOW"; then
    echo "::error file=$WORKFLOW::Root module $MODULE has no job"
    MISSING=1
  fi
done
exit "$MISSING"
