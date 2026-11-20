#!/usr/bin/env bash
set -euo pipefail

WORKFLOW=.github/workflows/deploy.yml
MISSING=0
for DIR in src/*/; do
  MODULE="$(basename "$DIR")"
  for JOB in test plan prod; do
    if ! grep -qx "  $MODULE-$JOB:" "$WORKFLOW"; then
      echo "::error file=$WORKFLOW::Root module $MODULE has no $MODULE-$JOB job"
      MISSING=1
    fi
  done
done
exit "$MISSING"
