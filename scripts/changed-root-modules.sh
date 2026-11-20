#!/usr/bin/env bash
set -euo pipefail

mapfile -t ALL < <(find src -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

if [[ -n "${SELECTION:-}" ]]; then
  if [[ "$SELECTION" == all ]]; then
    SELECTED=("${ALL[@]}")
  else
    IFS=', ' read -r -a SELECTED <<<"$SELECTION"
  fi
# A new branch has no previous commit to compare with.
elif [[ -z "${BEFORE:-}" || "$BEFORE" =~ ^0+$ ]]; then
  SELECTED=("${ALL[@]}")
else
  mapfile -t SELECTED < <(git diff --name-only "$BEFORE" HEAD -- src | cut -d/ -f2 | sort -u)
fi

MODULES=()
for MODULE in "${SELECTED[@]}"; do
  [[ -z "$MODULE" ]] && continue
  if [[ -d "src/$MODULE" ]]; then
    MODULES+=("$MODULE")
  elif [[ -n "${SELECTION:-}" ]]; then
    echo "::error::'$MODULE' is not a root module. Root modules: ${ALL[*]}"
    exit 1
  fi
done

JSON="$(printf '%s\n' "${MODULES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
echo "Root modules to deploy: $JSON"
echo "modules=$JSON" >> "$GITHUB_OUTPUT"
