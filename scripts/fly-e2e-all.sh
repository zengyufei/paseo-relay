#!/usr/bin/env bash

set -uo pipefail

app="${1:-paseo-relay-next}"
endpoint="${2:-wss://relay.paseo.sh}"
passed=0
failed=0

if ! inventory=$(
  fly machines list -a "$app" --json |
    jq -r '.[] | select(.state == "started") | [.id, .name, .region] | @tsv'
); then
  jq -cn --arg app "$app" '{summary: {app: $app, status: "error", error: "Machine discovery failed"}}'
  exit 1
fi

discovered=$(printf '%s\n' "$inventory" | awk 'NF {count++} END {print count + 0}')

while IFS=$'\t' read -r machine_id machine_name region; do
  if output=$(MIX_ENV=test mix run --no-start scripts/fly-replay-e2e.exs \
    --endpoint "$endpoint" \
    --owner "$machine_id" \
    --landing "$machine_id" </dev/null 2>&1); then
    result=$(printf '%s\n' "$output" | grep '^{' | tail -n 1)
    printf '%s\n' "$result" | jq -c \
      --arg machine_name "$machine_name" \
      --arg region "$region" \
      '. + {machine_name: $machine_name, region: $region}'
    passed=$((passed + 1))
  else
    error=$(printf '%s\n' "$output" | grep '^\*\* (' | head -n 1)
    jq -cn \
      --arg machine_id "$machine_id" \
      --arg machine_name "$machine_name" \
      --arg region "$region" \
      --arg error "${error:-E2E probe failed}" \
      '{status: "error", machine_id: $machine_id, machine_name: $machine_name, region: $region, error: $error}'
    failed=$((failed + 1))
  fi
done <<<"$inventory"

jq -cn \
  --arg app "$app" \
  --arg endpoint "$endpoint" \
  --argjson discovered "$discovered" \
  --argjson passed "$passed" \
  --argjson failed "$failed" \
  '{summary: {app: $app, endpoint: $endpoint, discovered: $discovered, passed: $passed, failed: $failed}}'

if ((failed > 0 || passed != discovered)); then
  exit 1
fi
