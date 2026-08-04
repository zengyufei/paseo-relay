#!/bin/sh
set -eu

PAIRS=3833
WEBSOCKETS=7667
RATE=1
PAYLOAD_BYTES=1024
DURATION_SECONDS=90
RECONNECT_DURATION_SECONDS=10
OWNER_GRACE_SECONDS=35
DEFAULT_REPLACEMENT_TOLERANCE_MS=1000

usage() {
  cat <<'EOF'
Usage: set the required environment, then run:
  sh deployment/fly/staging-gate.sh

Required:
  FLY_API_TOKEN
  PASEO_FLY_ARTIFACT_DIR             persistent, operator-owned output directory
  PASEO_FLY_CONFIRM_STAGING_ONLY=yes
  PASEO_FLY_APP
  PASEO_FLY_MACHINES                 three comma-separated Machine IDs
  PASEO_FLY_TARGET_MACHINE           one ID from PASEO_FLY_MACHINES
  PASEO_FLY_EXPECTED_TIMEOUT_MS
  PASEO_FLY_EXPECTED_CONNECTION_CEILING
  PASEO_FLY_MAX_PEAK_BYTES
  PASEO_FLY_PORT_BASE                three consecutive free local ports

Optional:
  PASEO_FLY_REPLACEMENT_TOLERANCE_MS (default: 1000; range: 1..5000)

Non-destructive contract checks:
  sh deployment/fly/staging-gate.sh --validate-config
  sh deployment/fly/staging-gate.sh --check-replacement-window ELAPSED_MS
  sh deployment/fly/staging-gate.sh --check-snapshot MACHINE PRIVATE_IP < snapshot.json

This destructive command is staging-only. It opens exactly 23,001 WebSockets
(7,667 per Machine) and has not been run or certified for this change.
EOF
}

[ "${1:-}" = "--help" ] && { usage; exit 0; }

ARTIFACT_INPUT=${PASEO_FLY_ARTIFACT_DIR:-}
if [ -z "$ARTIFACT_INPUT" ]; then
  printf '%s\n' '{"schema":1,"status":"failed","staging_only":true,"failed_checks":[{"check":"config.PASEO_FLY_ARTIFACT_DIR","expected":"set","actual":null,"reason":"persistent operator artifact directory is required"}],"artifacts":{}}'
  exit 2
fi
mkdir -p "$ARTIFACT_INPUT" 2>/dev/null || {
  printf '%s\n' '{"schema":1,"status":"failed","staging_only":true,"failed_checks":[{"check":"config.PASEO_FLY_ARTIFACT_DIR","expected":"creatable directory","actual":null,"reason":"artifact directory could not be created"}],"artifacts":{}}'
  exit 2
}
ARTIFACT_DIR=$(cd "$ARTIFACT_INPUT" && pwd -P) || exit 2
SUMMARY="$ARTIFACT_DIR/summary.json"
FAILURES="$ARTIFACT_DIR/failures.ndjson"
KEY_CHECKS="$ARTIFACT_DIR/key-checks.ndjson"
CHILD_STATUSES="$ARTIFACT_DIR/child-statuses.json"
: >"$FAILURES"
: >"$KEY_CHECKS"

exit_status=0
cleaning=0
signal_status=0
reporting_failed=0
setup_complete=0
loads=""
proxies=""
captured_pid=""
target_ip=""
ack_ms=null
changed_ms=null
replacement_elapsed_ms=null
status1=null
status2=null
status3=null
replacement_status=null
load1=""; load2=""; load3=""; replacement_load=""
ephemeral=""

json_failure_fallback() {
  reporting_failed=1
  printf '%s\n' '{"schema":1,"status":"failed","staging_only":true,"failed_checks":[{"check":"reporting.jq","expected":"working jq","actual":"unavailable","reason":"summary construction failed"}],"artifacts":{"directory":"."}}' >"$SUMMARY"
}

record_failure() {
  exit_status=1
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg check "$1" --arg node "$2" --arg shard "$3" \
      --argjson expected "$4" --argjson actual "$5" --arg reason "$6" '
        {check:$check,node:(if $node=="" then null else $node end),
         shard:(if $shard=="" then null else $shard end),expected:$expected,
         actual:$actual,reason:$reason}' >>"$FAILURES" 2>/dev/null || json_failure_fallback
  else
    json_failure_fallback
  fi
}

record_key_check() {
  command -v jq >/dev/null 2>&1 || return 0
  jq -cn --arg check "$1" --arg node "$2" --arg shard "$3" \
    --argjson expected "$4" --argjson actual "$5" \
    '{check:$check,node:(if $node=="" then null else $node end),
      shard:(if $shard=="" then null else $shard end),expected:$expected,actual:$actual}' \
    >>"$KEY_CHECKS" 2>/dev/null || true
}

write_summary() {
  if [ "$reporting_failed" -ne 0 ]; then json_failure_fallback; return; fi
  if ! command -v jq >/dev/null 2>&1; then json_failure_fallback; return; fi
  summary_m1=${M1:-missing}; summary_m2=${M2:-missing}; summary_m3=${M3:-missing}
  : >"$ARTIFACT_DIR/.artifact-refs.ndjson"
  for path in shard1.json shard2.json shard3.json replacement.json child-statuses.json timing.json \
    suspension.json capacity-recovery.json pre-replacement-metrics.prom \
    initial-$summary_m1.json initial-$summary_m2.json initial-$summary_m3.json \
    final-$summary_m1.json final-$summary_m2.json final-$summary_m3.json \
    ownership-$summary_m1.json ownership-$summary_m2.json ownership-$summary_m3.json \
    readiness-$summary_m1.txt readiness-$summary_m2.txt readiness-$summary_m3.txt \
    metrics-$summary_m1.prom metrics-$summary_m2.prom metrics-$summary_m3.prom \
    memory-peak-reset-$summary_m1.json memory-peak-reset-$summary_m2.json memory-peak-reset-$summary_m3.json \
    memory-peak-$summary_m1.json memory-peak-$summary_m2.json memory-peak-$summary_m3.json \
    shard1.stderr shard2.stderr shard3.stderr replacement.stderr; do
    [ -f "$ARTIFACT_DIR/$path" ] && jq -cn --arg path "$path" '$path' >>"$ARTIFACT_DIR/.artifact-refs.ndjson"
  done
  final_status=passed
  [ "$exit_status" -eq 0 ] && [ "$signal_status" -eq 0 ] || final_status=failed
  jq -n --arg status "$final_status" --arg app "${APP:-}" --arg target "${TARGET:-}" \
    --argjson signal "$signal_status" --slurpfile failures "$FAILURES" \
    --slurpfile checks "$KEY_CHECKS" --slurpfile artifacts "$ARTIFACT_DIR/.artifact-refs.ndjson" '
      {schema:1,status:$status,staging_only:true,app:(if $app=="" then null else $app end),
       target_machine:(if $target=="" then null else $target end),signal_status:$signal,
       failed_checks:$failures,key_checks:$checks,
       artifacts:{directory:".",files:$artifacts}}' >"$SUMMARY" 2>/dev/null || json_failure_fallback
}

redact_stderr() {
  name=$1
  source="$ephemeral/$name.stderr.raw"
  target="$ARTIFACT_DIR/$name.stderr"
  if [ -f "$source" ]; then
    sed -E 's/([A-Za-z0-9_]*(TOKEN|PASSWORD|SECRET)[A-Za-z0-9_]*)=[^[:space:]]*/\1=[REDACTED]/g' "$source" \
      | head -c 4096 >"$target"
  elif [ ! -f "$target" ]; then
    : >"$target"
  fi
}

bounded() { seconds=$1; shift; perl -e '$s=shift; alarm $s; exec @ARGV' "$seconds" "$@"; }
json_line() { awk '/^\{/{line=$0} END{print line}'; }

rpc() {
  machine=$1; ip=$2; expression=$3
  command="RELEASE_NODE=paseo_relay@$ip RELEASE_DISTRIBUTION=name ERL_AFLAGS='-proto_dist inet6_tcp' /app/bin/paseo_relay rpc '$expression'"
  bounded 20 fly ssh console --app "$APP" --machine "$machine" --pty=false --command "$command"
}

snapshot() { rpc "$1" "$2" "PaseoRelay.FlyDiagnostics.print_snapshot(\"$ids_encoded\")" | json_line; }

wait_ready() {
  attempts=0
  until curl --max-time 2 --fail --silent "http://127.0.0.1:$1/ready" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || return 1
    sleep 0.1
  done
}

metric() {
  curl --max-time 2 --fail --silent "http://127.0.0.1:$1/metrics" \
    | awk -v n="$2" '$1 == "paseo_relay_" n {print $2}'
}

remote_peak() {
  bounded 20 fly ssh console --app "$APP" --machine "$1" --pty=false --command \
    "sh -lc '$2 /sys/fs/cgroup/memory.peak'"
}

remote_peak_identity() {
  bounded 20 fly ssh console --app "$APP" --machine "$1" --pty=false --command \
    "stat -Lc '%d:%i' /sys/fs/cgroup/memory.peak"
}

collect_final_machine() {
  machine=$1; ip=$2; port=$3
  if wait_ready "$port"; then ready=true; else ready=false; fi
  printf '%s\n' "$ready" >"$ARTIFACT_DIR/readiness-$machine.txt"
  curl --max-time 2 --fail --silent "http://127.0.0.1:$port/metrics" \
    >"$ARTIFACT_DIR/metrics-$machine.prom" 2>"$ephemeral/metrics-$machine.stderr.raw" || true
  final=$(snapshot "$machine" "$ip" 2>"$ephemeral/final-$machine.stderr.raw" || true)
  printf '%s\n' "$final" >"$ARTIFACT_DIR/final-$machine.json"
  printf '%s' "$final" | jq -c '.owners // {}' >"$ARTIFACT_DIR/ownership-$machine.json" 2>/dev/null || \
    printf '%s\n' '{}' >"$ARTIFACT_DIR/ownership-$machine.json"

  peak=$(remote_peak "$machine" cat 2>"$ephemeral/peak-$machine.stderr.raw" | tail -n 1 | tr -d '[:space:]' || true)
  identity=$(remote_peak_identity "$machine" 2>>"$ephemeral/peak-$machine.stderr.raw" | tail -n 1 | tr -d '[:space:]' || true)
  case "$peak" in ''|*[!0-9]*) peak_json=null;; *) peak_json=$peak;; esac
  jq -n --arg machine "$machine" --arg identity "$identity" --argjson actual "$peak_json" \
    --argjson limit "$MAX_PEAK" '{machine_id:$machine,counter:"/sys/fs/cgroup/memory.peak",
      counter_identity:$identity,actual_bytes:$actual,limit_bytes:$limit}' \
    >"$ARTIFACT_DIR/memory-peak-$machine.json" 2>/dev/null || true

  active=$(metric "$port" active_websockets 2>/dev/null || printf null)
  reserved=$(metric "$port" ingress_reserved_bytes 2>/dev/null || printf null)
  inflight=$(metric "$port" inflight_delivery_bytes 2>/dev/null || printf null)
  blocked=$(metric "$port" backpressured_sources 2>/dev/null || printf null)
  actual=$(jq -cn --argjson ready "$ready" --argjson active "${active:-null}" \
    --argjson reserved "${reserved:-null}" --argjson inflight "${inflight:-null}" \
    --argjson blocked "${blocked:-null}" --argjson peak "$peak_json" \
    '{ready:$ready,active_websockets:$active,ingress_reserved_bytes:$reserved,
      inflight_delivery_bytes:$inflight,backpressured_sources:$blocked,memory_peak_bytes:$peak}' \
    2>/dev/null || printf null)
  expected=$(jq -cn --argjson peak "$MAX_PEAK" '{ready:true,active_websockets:0,
    ingress_reserved_bytes:0,inflight_delivery_bytes:0,backpressured_sources:0,
    memory_peak_bytes_at_most:$peak}')
  record_key_check cleanup.machine "$machine" "" "$expected" "$actual"
  printf '%s' "$actual" | jq -e --argjson max "$MAX_PEAK" '
    .ready == true and .active_websockets == 0 and .ingress_reserved_bytes == 0 and
    .inflight_delivery_bytes == 0 and .backpressured_sources == 0 and
    (.memory_peak_bytes | type) == "number" and .memory_peak_bytes <= $max' >/dev/null 2>&1 ||
    record_failure cleanup.machine "$machine" "" "$expected" "$actual" \
      "Machine must finish ready, clean, and below its memory.peak limit"
  owners=$(cat "$ARTIFACT_DIR/ownership-$machine.json")
  printf '%s' "$owners" | jq -e --argjson ids "$ids_json" '
    . as $owners | all($ids[]; $owners[.] == "unowned")' >/dev/null 2>&1 ||
    record_failure cleanup.owners_unowned "$machine" "" '"all staged serverIds unowned"' \
      "$(printf '%s' "$owners" | jq -c '.' 2>/dev/null || printf null)" \
      "observer still reports a staged Owner"
}

cleanup() {
  incoming=$?
  [ "$cleaning" -eq 0 ] || return
  cleaning=1
  set +e
  trap 'signal_status=130; exit_status=1' INT
  trap 'signal_status=143; exit_status=1' TERM
  [ "$incoming" -eq 0 ] || exit_status=1

  if [ -n "$captured_pid" ] && [ -n "$target_ip" ]; then
    if rpc "$TARGET" "$target_ip" "PaseoRelay.FlyDiagnostics.kill_capacity(\"$captured_pid\")" \
      >"$ARTIFACT_DIR/capacity-recovery.json" 2>"$ephemeral/recovery.stderr.raw"; then
      json_line <"$ARTIFACT_DIR/capacity-recovery.json" | jq -e \
        '.status == "killed" or .status == "already_replaced"' >/dev/null 2>&1 ||
        record_failure cleanup.capacity_recovery "$TARGET" "" '"killed or already_replaced"' null \
          "exact captured Capacity PID recovery returned invalid evidence"
    else
      record_failure cleanup.capacity_recovery "$TARGET" "" '"killed or already_replaced"' null \
        "exact captured Capacity PID recovery command failed"
    fi
  fi
  for pid in $loads; do kill "$pid" 2>/dev/null || true; done
  wait_child() {
    child_pid=$1; child_name=$2
    [ -n "$child_pid" ] || return
    if wait "$child_pid" 2>/dev/null; then child_status=0; else child_status=$?; fi
    case "$child_name" in
      shard1) [ "$status1" != null ] || status1=$child_status;;
      shard2) [ "$status2" != null ] || status2=$child_status;;
      shard3) [ "$status3" != null ] || status3=$child_status;;
      replacement) [ "$replacement_status" != null ] || replacement_status=$child_status;;
    esac
  }
  wait_child "$load1" shard1; wait_child "$load2" shard2; wait_child "$load3" shard3
  wait_child "$replacement_load" replacement

  if [ "$setup_complete" -eq 1 ]; then
    sleep "$OWNER_GRACE_SECONDS"
    collect_final_machine "$M1" "$IP1" "$PORT1"
    collect_final_machine "$M2" "$IP2" "$PORT2"
    collect_final_machine "$M3" "$IP3" "$PORT3"
  fi
  for pid in $proxies; do kill "$pid" 2>/dev/null || true; done
  for pid in $proxies; do wait "$pid" 2>/dev/null || true; done
  if [ -n "$ephemeral" ]; then
    for name in shard1 shard2 shard3 replacement recovery; do redact_stderr "$name"; done
  fi
  jq -n --argjson shard1 "$status1" --argjson shard2 "$status2" --argjson shard3 "$status3" \
    --argjson replacement "$replacement_status" \
    '{shard1:$shard1,shard2:$shard2,shard3:$shard3,replacement:$replacement}' \
    >"$CHILD_STATUSES" 2>/dev/null || true
  if [ "$exit_status" -ne 0 ] && [ ! -s "$FAILURES" ] && [ ! -f "$SUMMARY" ]; then
    record_failure run.exit_status "" "" 0 "$incoming" "staging command failed before a detailed check was available"
  fi
  write_summary
  cat "$SUMMARY"
  [ -z "$ephemeral" ] || rm -rf "$ephemeral"
  trap - EXIT INT TERM
  [ "$exit_status" -eq 0 ] && [ "$signal_status" -eq 0 ]
}

trap cleanup EXIT
trap 'signal_status=130; exit 130' INT
trap 'signal_status=143; exit 143' TERM

required() {
  [ -n "$1" ] || { record_failure "config.$2" "" "" '"set"' null "$2 is required"; exit 2; }
}
required "${FLY_API_TOKEN:-}" FLY_API_TOKEN
required "${PASEO_FLY_CONFIRM_STAGING_ONLY:-}" PASEO_FLY_CONFIRM_STAGING_ONLY
required "${PASEO_FLY_APP:-}" PASEO_FLY_APP
required "${PASEO_FLY_MACHINES:-}" PASEO_FLY_MACHINES
required "${PASEO_FLY_TARGET_MACHINE:-}" PASEO_FLY_TARGET_MACHINE
required "${PASEO_FLY_EXPECTED_TIMEOUT_MS:-}" PASEO_FLY_EXPECTED_TIMEOUT_MS
required "${PASEO_FLY_EXPECTED_CONNECTION_CEILING:-}" PASEO_FLY_EXPECTED_CONNECTION_CEILING
required "${PASEO_FLY_MAX_PEAK_BYTES:-}" PASEO_FLY_MAX_PEAK_BYTES
required "${PASEO_FLY_PORT_BASE:-}" PASEO_FLY_PORT_BASE

APP=$PASEO_FLY_APP
TARGET=$PASEO_FLY_TARGET_MACHINE
EXPECTED_TIMEOUT=$PASEO_FLY_EXPECTED_TIMEOUT_MS
EXPECTED_CONNECTION_CEILING=$PASEO_FLY_EXPECTED_CONNECTION_CEILING
REPLACEMENT_TOLERANCE=${PASEO_FLY_REPLACEMENT_TOLERANCE_MS:-$DEFAULT_REPLACEMENT_TOLERANCE_MS}
MAX_PEAK=$PASEO_FLY_MAX_PEAK_BYTES
PORT1=$PASEO_FLY_PORT_BASE

[ "$PASEO_FLY_CONFIRM_STAGING_ONLY" = yes ] || {
  record_failure config.staging_confirmation "" "" '"yes"' '"invalid"' \
    "PASEO_FLY_CONFIRM_STAGING_ONLY must be yes"
  exit 2
}
case "$EXPECTED_TIMEOUT,$EXPECTED_CONNECTION_CEILING,$REPLACEMENT_TOLERANCE,$MAX_PEAK,$PORT1" in
  *[!0-9,]*)
    record_failure config.numeric_inputs "" "" '"positive integers"' '"invalid"' \
      "timeout, ceiling, tolerance, peak, and port must be decimal integers"
    exit 2;;
esac
[ "$PORT1" -ge 1024 ] && [ "$PORT1" -le 65533 ] || {
  record_failure config.port_base "" "" '{"minimum":1024,"maximum":65533}' "$PORT1" \
    "port base must leave three valid unprivileged ports"
  exit 2
}
PORT2=$((PORT1 + 1)); PORT3=$((PORT1 + 2))

IFS=, read -r M1 M2 M3 M4 <<EOF
$PASEO_FLY_MACHINES
EOF
[ -n "$M1" ] && [ -n "$M2" ] && [ -n "$M3" ] && [ -z "$M4" ] || {
  record_failure config.machine_count "" "" 3 '"invalid"' "exactly three Machine IDs are required"
  exit 2
}
[ "$M1" != "$M2" ] && [ "$M1" != "$M3" ] && [ "$M2" != "$M3" ] || {
  record_failure config.distinct_machines "" "" 3 '"duplicate"' "Machine IDs must be distinct"
  exit 2
}
case "$M1$M2$M3$TARGET" in *[!A-Za-z0-9]*)
  record_failure config.machine_id "" "" '"alphanumeric"' '"invalid"' "invalid Machine ID"; exit 2;; esac
[ "$TARGET" = "$M1" ] || [ "$TARGET" = "$M2" ] || [ "$TARGET" = "$M3" ] || {
  record_failure config.target_machine "" "" '"selected Machine"' '"not selected"' \
    "target must be one selected Machine"
  exit 2
}
[ "$EXPECTED_CONNECTION_CEILING" -gt "$WEBSOCKETS" ] || {
  record_failure config.connection_ceiling "" "" '"greater than 7667"' "$EXPECTED_CONNECTION_CEILING" \
    "ceiling must exceed per-Machine occupancy"
  exit 2
}
[ "$EXPECTED_TIMEOUT" -gt 0 ] && [ "$EXPECTED_TIMEOUT" -le 30000 ] || {
  record_failure config.capacity_mutation_timeout_ms "" "" '{"minimum":1,"maximum":30000}' \
    "$EXPECTED_TIMEOUT" "timeout is outside this fixed gate's range"
  exit 2
}
[ "$REPLACEMENT_TOLERANCE" -gt 0 ] && [ "$REPLACEMENT_TOLERANCE" -le 5000 ] || {
  record_failure config.replacement_tolerance_ms "" "" '{"minimum":1,"maximum":5000}' \
    "$REPLACEMENT_TOLERANCE" "replacement tolerance is invalid"
  exit 2
}
[ "$MAX_PEAK" -gt 0 ] || {
  record_failure config.max_peak_bytes "" "" '"positive integer"' "$MAX_PEAK" "memory peak limit is invalid"
  exit 2
}

validate_replacement_window() {
  elapsed=$1
  case "$elapsed" in ''|*[!0-9]*)
    record_failure timing.replacement_elapsed_ms "$TARGET" "" '"integer milliseconds"' '"invalid"' \
      "replacement elapsed time must be an integer"; return 1;; esac
  upper=$((EXPECTED_TIMEOUT + REPLACEMENT_TOLERANCE))
  expected=$(jq -cn --argjson lower "$EXPECTED_TIMEOUT" --argjson upper "$upper" '{lower_ms:$lower,upper_ms:$upper}')
  record_key_check timing.replacement_elapsed_ms "$TARGET" "" "$expected" "$elapsed"
  [ "$elapsed" -ge "$EXPECTED_TIMEOUT" ] && [ "$elapsed" -le "$upper" ] || {
    record_failure timing.replacement_elapsed_ms "$TARGET" "" "$expected" "$elapsed" \
      "replacement was outside the configured timeout observation window"
    return 1
  }
}

validate_snapshot() {
  printf '%s' "$1" | jq -e --arg machine "$2" --arg ip "$3" --argjson timeout "$EXPECTED_TIMEOUT" \
    --argjson ceiling "$EXPECTED_CONNECTION_CEILING" '.schema==1 and .machine_id==$machine and
      .private_ip==$ip and .release_node==("paseo_relay@"+$ip) and
      .capacity_mutation_timeout_ms==$timeout and .connection_ceiling==$ceiling and
      (.capacity_pid|test("^#PID<[0-9]+\\.[0-9]+\\.[0-9]+>$"))' >/dev/null
}

case "${1:-}" in
  --validate-config) [ "$#" -eq 1 ] || exit 2; exit 0;;
  --check-replacement-window) [ "$#" -eq 2 ] || exit 2; validate_replacement_window "$2"; exit $?;;
  --check-snapshot)
    [ "$#" -eq 3 ] || exit 2
    checked_snapshot=$(cat)
    validate_snapshot "$checked_snapshot" "$2" "$3" || {
      record_failure machine.deployed_config "$2" "" '"matching identity, timeout, ceiling, and Capacity PID"' null \
        "deployed diagnostic snapshot did not match operator inputs"
      exit 1
    }
    exit 0;;
  '') ;;
  *) usage >&2; record_failure config.arguments "" "" '"documented arguments"' '"invalid"' "unknown argument"; exit 2;;
esac

for command_name in fly jq node curl perl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    record_failure config.command "" "" '"installed"' "\"$command_name missing\"" \
      "fly, jq, node, curl, and perl are required"
    exit 2
  }
done

ephemeral=$(mktemp -d "${TMPDIR:-/tmp}/paseo-fly-gate.XXXXXX") || {
  record_failure run.temporary_directory "" "" '"created"' '"failed"' "ephemeral directory failed"
  exit 1
}
run_id="fly-gate-$(date +%s)-$$"
SID1="$run_id-$M1"; SID2="$run_id-$M2"; SID3="$run_id-$M3"
ids_json=$(jq -cn --arg a "$SID1" --arg b "$SID2" --arg c "$SID3" '[$a,$b,$c]')
ids_encoded=$(node -e 'process.stdout.write(Buffer.from(process.argv[1]).toString("base64url"))' "$ids_json")

inventory=$(bounded 20 fly machines list --app "$APP" --json) || {
  record_failure machine.inventory "" "" '"three selected running Machines"' null "inventory failed"; exit 1; }
machine_ip() { printf '%s' "$inventory" | jq -er --arg id "$1" '.[]|select(.id==$id and .state=="started")|.private_ip'; }
IP1=$(machine_ip "$M1"); IP2=$(machine_ip "$M2"); IP3=$(machine_ip "$M3")

for entry in "$M1|$IP1" "$M2|$IP2" "$M3|$IP3"; do
  machine=${entry%%|*}; ip=${entry#*|}; initial=$(snapshot "$machine" "$ip")
  printf '%s\n' "$initial" >"$ARTIFACT_DIR/initial-$machine.json"
  validate_snapshot "$initial" "$machine" "$ip" || {
    record_failure machine.deployed_config "$machine" "" '"matching identity, timeout, and ceiling"' null \
      "deployed diagnostic snapshot did not match operator inputs"; exit 1; }
  identity=$(remote_peak_identity "$machine")
  remote_peak "$machine" "printf reset >" >/dev/null
  jq -n --arg machine "$machine" --arg identity "$identity" \
    '{machine_id:$machine,counter:"/sys/fs/cgroup/memory.peak",counter_identity:$identity,reset:true}' \
    >"$ARTIFACT_DIR/memory-peak-reset-$machine.json"
done

start_proxy() {
  fly proxy "$3:4000" "$2" --app "$APP" --bind-addr 127.0.0.1 >"$ephemeral/proxy-$1.log" 2>&1 &
  proxies="$proxies $!"
}
start_proxy "$M1" "$IP1" "$PORT1"; start_proxy "$M2" "$IP2" "$PORT2"; start_proxy "$M3" "$IP3" "$PORT3"
wait_ready "$PORT1"; wait_ready "$PORT2"; wait_ready "$PORT3"
setup_complete=1

start_load() {
  name=$1; sid=$2; port=$3; duration=$4
  paused=${5:-no}
  set -- node scripts/relay-load.mjs --endpoints "ws://127.0.0.1:$port/ws" --server-id "$sid" \
    --connection-prefix "$name" --pairs "$PAIRS" --batch-size 250 --ramp-ms 100 \
    --scenario sustained --duration "$duration" --rate "$RATE" --payload-bytes "$PAYLOAD_BYTES" \
    --cleanup-grace 15 --drain-timeout 15
  [ "$paused" = yes ] && set -- "$@" --start-on-sigusr1
  "$@" >"$ARTIFACT_DIR/$name.json" 2>"$ephemeral/$name.stderr.raw" &
  last_load=$!; loads="$loads $last_load"
}

case "$TARGET" in
  "$M1") target_ip=$IP1; target_port=$PORT1; target_sid=$SID1; pause1=yes; pause2=no; pause3=no;;
  "$M2") target_ip=$IP2; target_port=$PORT2; target_sid=$SID2; pause1=no; pause2=yes; pause3=no;;
  *) target_ip=$IP3; target_port=$PORT3; target_sid=$SID3; pause1=no; pause2=no; pause3=yes;;
esac
start_load shard1 "$SID1" "$PORT1" "$DURATION_SECONDS" "$pause1"; load1=$last_load
start_load shard2 "$SID2" "$PORT2" "$DURATION_SECONDS" "$pause2"; load2=$last_load
start_load shard3 "$SID3" "$PORT3" "$DURATION_SECONDS" "$pause3"; load3=$last_load

case "$TARGET" in
  "$M1") target_load=$load1;;
  "$M2") target_load=$load2;;
  *) target_load=$load3;;
esac

for port in "$PORT1" "$PORT2" "$PORT3"; do
  attempts=0
  while [ "$(metric "$port" active_websockets 2>/dev/null || echo missing)" != "$WEBSOCKETS" ]; do
    attempts=$((attempts + 1)); [ "$attempts" -lt 3000 ] || {
      record_failure shard.opened_sockets "" "" "$WEBSOCKETS" null "shard never reached occupancy"; exit 1; }
    sleep 0.1
  done
done
attempts=0
while [ "$(metric "$target_port" ingress_reserved_bytes 2>/dev/null || echo missing)" != 0 ] || \
  [ "$(metric "$target_port" inflight_delivery_bytes 2>/dev/null || echo missing)" != 0 ] || \
  [ "$(metric "$target_port" backpressured_sources 2>/dev/null || echo missing)" != 0 ]; do
  attempts=$((attempts + 1)); [ "$attempts" -lt 100 ] || {
    record_failure shard.target_quiescence "$TARGET" "" '"zero Capacity traffic gauges"' null \
      "paused target shard did not quiesce before suspension"; exit 1; }
  sleep 0.1
done
target_snapshot=$(snapshot "$TARGET" "$target_ip")
captured_pid=$(printf '%s' "$target_snapshot" | jq -er .capacity_pid)
suspended=$(rpc "$TARGET" "$target_ip" "PaseoRelay.FlyDiagnostics.suspend_capacity(\"$captured_pid\")" | json_line)
printf '%s\n' "$suspended" >"$ARTIFACT_DIR/suspension.json"
ack_ms=$(printf '%s' "$suspended" | jq -er --arg machine "$TARGET" --arg pid "$captured_pid" \
  'select(.event=="capacity_suspended" and .machine_id==$machine and .capacity_pid==$pid)|.acknowledged_monotonic_ms')
kill -USR1 "$target_load" || {
  record_failure shard.target_publisher "$TARGET" "" '"SIGUSR1 accepted after suspension acknowledgement"' null \
    "paused target publisher could not be started"; exit 1; }
curl --max-time 2 --fail --silent "http://127.0.0.1:$target_port/health" >/dev/null
[ "$(curl --max-time 2 --silent -o /dev/null -w '%{http_code}' "http://127.0.0.1:$target_port/ready")" = 503 ]

while :; do
  after=$(snapshot "$TARGET" "$target_ip")
  after_pid=$(printf '%s' "$after" | jq -er .capacity_pid)
  observed_ms=$(printf '%s' "$after" | jq -er .monotonic_ms)
  [ "$after_pid" != "$captured_pid" ] && break
  [ $((observed_ms - ack_ms)) -le $((EXPECTED_TIMEOUT + REPLACEMENT_TOLERANCE)) ] || break
  sleep 0.1
done
changed_ms=$observed_ms
replacement_elapsed_ms=$((changed_ms - ack_ms))
jq -n --argjson acknowledged "$ack_ms" --argjson observed "$changed_ms" \
  --argjson elapsed "$replacement_elapsed_ms" --argjson timeout "$EXPECTED_TIMEOUT" \
  --argjson tolerance "$REPLACEMENT_TOLERANCE" '{suspension_acknowledged_monotonic_ms:$acknowledged,
    replacement_observed_monotonic_ms:$observed,replacement_elapsed_ms:$elapsed,
    configured_timeout_ms:$timeout,observation_tolerance_ms:$tolerance,
    target_publisher_signal:"SIGUSR1",target_publisher_started_after_ack:true}' >"$ARTIFACT_DIR/timing.json"
validate_replacement_window "$replacement_elapsed_ms" || exit 1
wait_ready "$target_port"

wait_status() { if wait "$1"; then waited_status=0; else waited_status=$?; fi; }
wait_status "$load1"; status1=$waited_status
wait_status "$load2"; status2=$waited_status
wait_status "$load3"; status3=$waited_status
loads=""

validate_load() {
  name=$1; node=$2; role=$3; child=$4; duration=$5
  file="$ARTIFACT_DIR/$name.json"
  if [ ! -f "$file" ] || [ "$(wc -c <"$file")" -gt 65536 ] ||
    ! jq -e -s 'length==1 and (.[0]|type)=="object"' "$file" >/dev/null 2>&1; then
    redact_stderr "$name"
    record_failure shard.result_json "$node" "$name" '"valid bounded relay-load JSON"' \
      'null' "relay-load result is malformed; inspect retained artifact and redacted stderr"
    return
  fi
  min_duration=$((duration * 1000))
  if [ "$role" = affected ]; then
    min_ticks=$((EXPECTED_TIMEOUT / 1000 - 2)); [ "$min_ticks" -gt 0 ] || min_ticks=1
  else
    min_ticks=$((duration * RATE - 2)); [ "$min_ticks" -gt 0 ] || min_ticks=1
  fi
  min_frames=$((min_ticks * WEBSOCKETS))
  expected_abnormal=0; expected_normal=$WEBSOCKETS; expected_exit=0
  if [ "$role" = affected ]; then expected_abnormal=$WEBSOCKETS; expected_normal=0; expected_exit=nonzero; fi
  actual=$(jq -c '{child_exit_status:$child,requested_websockets:.requested_websockets,
    opened_sockets:.connection_successes,steady_duration_ms:.steady_duration_ms,
    publisher_started_by_signal:.publisher_started_by_signal,publisher_wait_ms:.publisher_wait_ms,
    frames_sent:.frames_sent,frames_received:.frames_received,frames_lost:.frames_lost,
    normal_closes:.normal_closes,abnormal_closes:.abnormal_closes,
    connection_failures:.connection_failures,send_failures:.send_failures,
    ordering_failures:.ordering_failures,cleanup_timeouts:.cleanup_timeouts}' --argjson child "$child" "$file")
  expected=$(jq -cn --arg role "$role" --arg exit "$expected_exit" --argjson sockets "$WEBSOCKETS" \
    --argjson duration "$min_duration" --argjson frames "$min_frames" --argjson normal "$expected_normal" \
    --argjson abnormal "$expected_abnormal" '{role:$role,child_exit_status:$exit,
      requested_websockets:$sockets,opened_sockets:$sockets,steady_duration_ms_at_least:$duration,
      publisher_started_by_signal:($role=="affected"),
      frames_sent_at_least:$frames,normal_closes:$normal,abnormal_closes:$abnormal}')
  record_key_check shard.traffic "$node" "$name" "$expected" "$actual"
  printf '%s' "$actual" | jq -e --arg role "$role" --argjson sockets "$WEBSOCKETS" \
    --argjson duration "$min_duration" --argjson frames "$min_frames" \
    --argjson normal "$expected_normal" --argjson abnormal "$expected_abnormal" '
      .requested_websockets==$sockets and .opened_sockets==$sockets and
      .steady_duration_ms >= $duration and .frames_sent >= $frames and
      .publisher_started_by_signal==($role=="affected") and
      .normal_closes==$normal and .abnormal_closes==$abnormal and .ordering_failures==0 and
      .cleanup_timeouts==0 and
      (if $role=="affected" then .child_exit_status!=0 and .send_failures>0
       else .child_exit_status==0 and .connection_failures==0 and .send_failures==0 and .frames_lost==0 end)' \
    >/dev/null 2>&1 || record_failure shard.traffic "$node" "$name" "$expected" "$actual" \
      "relay-load duration, traffic, close, or failure counters violated the shard contract"
}

validate_load shard1 "$M1" "$( [ "$TARGET" = "$M1" ] && echo affected || echo unaffected )" "$status1" "$DURATION_SECONDS"
validate_load shard2 "$M2" "$( [ "$TARGET" = "$M2" ] && echo affected || echo unaffected )" "$status2" "$DURATION_SECONDS"
validate_load shard3 "$M3" "$( [ "$TARGET" = "$M3" ] && echo affected || echo unaffected )" "$status3" "$DURATION_SECONDS"
[ "$exit_status" -eq 0 ] || exit 1

curl --max-time 2 --fail --silent "http://127.0.0.1:$target_port/metrics" >"$ARTIFACT_DIR/pre-replacement-metrics.prom"
[ "$(metric "$target_port" active_websockets)" = 0 ] || {
  record_failure replacement.occupancy "$TARGET" replacement 0 "$(metric "$target_port" active_websockets)" \
    "replacement sockets must not overlap old epoch occupancy"; exit 1; }
start_load replacement "$target_sid" "$target_port" "$RECONNECT_DURATION_SECONDS"
replacement_load=$last_load
wait_status "$replacement_load"; replacement_status=$waited_status
loads=""
validate_load replacement "$TARGET" replacement "$replacement_status" "$RECONNECT_DURATION_SECONDS"
[ "$exit_status" -eq 0 ] || exit 1
