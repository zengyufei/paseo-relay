#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <binary> [relay-load]" >&2; exit 2; }
readonly binary="$1"
readonly mode="${2:-health}"
readonly port="${PASEO_RELAY_SMOKE_PORT:-4400}"

[[ -f "${binary}" ]] || { echo "standalone binary not found: ${binary}" >&2; exit 1; }
chmod 0755 "${binary}"
"${binary}" maintenance meta

relay_pid=""
cleanup() {
  if [[ -n "${relay_pid}" ]] && kill -0 "${relay_pid}" 2>/dev/null; then
    while IFS= read -r child_pid; do
      [[ -z "${child_pid}" ]] || kill "${child_pid}" 2>/dev/null || true
    done < <(pgrep -P "${relay_pid}" 2>/dev/null || true)
    kill "${relay_pid}"
    wait "${relay_pid}" || true
  fi
}
trap cleanup EXIT

PASEO_RELAY_HOST=127.0.0.1 \
PASEO_RELAY_PORT="${port}" \
PASEO_RELAY_MIN_CLUSTER_SIZE=1 \
  "${binary}" >standalone-smoke.log 2>&1 &
relay_pid=$!

for _attempt in $(seq 1 300); do
  if curl --fail --silent --show-error "http://127.0.0.1:${port}/health" >/dev/null; then
    break
  fi
  if ! kill -0 "${relay_pid}" 2>/dev/null; then
    cat standalone-smoke.log >&2
    exit 1
  fi
  sleep 0.2
done

health="$(curl --fail --silent --show-error "http://127.0.0.1:${port}/health")" || {
  cat standalone-smoke.log >&2
  exit 1
}
[[ "${health}" == '{"status":"ok"}' ]]
[[ "$(curl --fail --silent --show-error "http://127.0.0.1:${port}/ready")" == '{"status":"ready"}' ]]

if [[ "${mode}" == "relay-load" ]]; then
  node scripts/relay-load.mjs \
    --endpoints "ws://127.0.0.1:${port}/ws" \
    --scenario sustained --pairs 10 --batch-size 10 --rate 10 --duration 1 \
    --cleanup-grace 5 --drain-timeout 5
fi
