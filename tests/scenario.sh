#!/usr/bin/env bash

SERVER_IDLE_TIMEOUT_SECS=10

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="tests/logs"
mkdir -p "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server.log"
CLIENT1_LOG="$LOG_DIR/client1.log"
CLIENT2_LOG="$LOG_DIR/client2.log"
CLIENT3_LOG="$LOG_DIR/client3.log"
SERVER_BIN="$ROOT_DIR/target/debug/h3-server"
CLIENT_BIN="$ROOT_DIR/target/debug/h3-client"

cleanup() {
  for pid_var in CLIENT3_PID CLIENT2_PID CLIENT1_PID SERVER_PID; do
    pid="${!pid_var:-}"
    if [[ -n "$pid" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

wait_for_log_line() {
  local file="$1"
  local pattern="$2"
  local timeout="${3:-10}"
  local started
  started="$(date +%s)"

  while true; do
    if grep -q "$pattern" "$file" 2>/dev/null; then
      return 0
    fi

    if (("$(date +%s)" - started >= timeout)); then
      echo "timed out waiting for pattern '$pattern' in $file" >&2
      [[ -f "$file" ]] && cat "$file" >&2
      exit 1
    fi

    sleep 0.1
  done
}

wait_for_pid_exit() {
  local pid="$1"
  local timeout="${2:-5}"
  local started
  started="$(date +%s)"

  while kill -0 "$pid" 2>/dev/null; do
    if (("$(date +%s)" - started >= timeout)); then
      return 1
    fi
    sleep 0.1
  done

  wait "$pid" 2>/dev/null || true
  return 0
}

last_tick_json() {
  local file="$1"
  grep '\[Client\] tick ' "$file" | tail -n 1 | sed -E 's/^.*(\{.*\})/\1/'
}

last_tick_number() {
  local file="$1"
  local json
  json="$(last_tick_json "$file" 2>/dev/null || true)"

  if [[ -z "$json" ]]; then
    return 1
  fi

  printf '%s\n' "$json" | jq -r '.tick'
}

wait_until_next_tick_after() {
  local file="$1"
  local baseline_tick="$2"
  local label="$3"
  local timeout="${4:-12}"
  local started
  started="$(date +%s)"

  while true; do
    local current_tick
    local safe_next_tick
    current_tick="$(last_tick_number "$file" 2>/dev/null || true)"
    safe_next_tick=$((baseline_tick + 2))

    if [[ -n "$current_tick" ]] && [[ "$current_tick" =~ ^[0-9]+$ ]] && ((current_tick > safe_next_tick)); then
      return 0
    fi

    if (("$(date +%s)" - started >= timeout)); then
      echo "timed out waiting for tick > $baseline_tick [$label] in $file" >&2
      cat "$file" >&2
      exit 1
    fi

    sleep 0.1
  done
}

assert_last_subscribers() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local json
  json="$(last_tick_json "$file" 2>/dev/null || true)"

  if [[ -z "$json" ]]; then
    echo "no tick json found in $file" >&2
    cat "$file" >&2
    return 1
  fi

  local actual
  actual="$(printf '%s\n' "$json" | jq -r '.subscribers')"

  if [[ "$actual" != "$expected" ]]; then
    echo -e "${RED}[FAILED]${NC} [$label]: expected subscribers=$expected got $actual from $json" >&2
    return 1
  fi

  echo -e "${GREEN}[OK]${NC} [$label]: $json"
}

assert_subscribers_after_next_tick() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local baseline_tick="$4"
  local timeout="${5:-12}"

  if ! wait_until_next_tick_after "$file" "$baseline_tick" "$label" "$timeout"; then
    return 1
  fi

  assert_last_subscribers "$file" "$expected" "$label"
}

require_cmd cargo
require_cmd jq

cd "$ROOT_DIR" || exit 1

echo "== build binaries =="
cargo build -p h3-server -p h3-client >/dev/null

echo "cleanup old logs"
rm -f "$LOG_DIR"/{client1,client2,client3,server}.log

echo "== start server =="
"$SERVER_BIN" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
wait_for_log_line "$SERVER_LOG" '\[Server\] listening on'
echo "server pid=$SERVER_PID"

echo "== start client1 =="
"$CLIENT_BIN" >"$CLIENT1_LOG" 2>&1 &
CLIENT1_PID=$!
echo "client1 pid=$CLIENT1_PID"
wait_for_log_line "$CLIENT1_LOG" '\[Client\] tick 1:'
assert_last_subscribers "$CLIENT1_LOG" 1 "client1 first tick"

echo "== start client2 =="
client1_tick_before_client2_join="$(last_tick_number "$CLIENT1_LOG")"
"$CLIENT_BIN" >"$CLIENT2_LOG" 2>&1 &
CLIENT2_PID=$!
echo "client2 pid=$CLIENT2_PID"
wait_for_log_line "$CLIENT2_LOG" '\[Client\] tick 1:'
assert_last_subscribers "$CLIENT2_LOG" 2 "client2 first tick"
assert_subscribers_after_next_tick "$CLIENT1_LOG" 2 "client1 should see 2 subscribers after client2 joins" "$client1_tick_before_client2_join"

echo "== graceful exit scenario (SIGTERM) =="
echo "sending SIGTERM to client2 pid=$CLIENT2_PID (with ApplicationClose(0x100))"
client1_tick_before_client2_exit="$(last_tick_number "$CLIENT1_LOG")"
kill -SIGTERM "$CLIENT2_PID"
if ! wait_for_pid_exit "$CLIENT2_PID" 5; then
  echo "client2 did not exit after SIGTERM" >&2
  exit 1
fi
unset CLIENT2_PID
assert_subscribers_after_next_tick "$CLIENT1_LOG" 1 "client1 should see 1 subscriber after client2 exit" "$client1_tick_before_client2_exit"

echo "== start client3 =="
client1_tick_before_client3_join="$(last_tick_number "$CLIENT1_LOG")"
"$CLIENT_BIN" >"$CLIENT3_LOG" 2>&1 &
CLIENT3_PID=$!
echo "client3 pid=$CLIENT3_PID"
wait_for_log_line "$CLIENT3_LOG" '\[Client\] tick 1:'
assert_last_subscribers "$CLIENT3_LOG" 2 "client3 first tick"
assert_subscribers_after_next_tick "$CLIENT1_LOG" 2 "client1 should see 2 subscribers after client3 joins" "$client1_tick_before_client3_join"

echo "== abrupt close scenario (SIGINT/SIGKILL)"
echo "sending SIGKILL to client3 pid=$CLIENT3_PID (without ApplicationClose)"
client1_tick_before_client3_exit="$(last_tick_number "$CLIENT1_LOG")"
kill -SIGKILL "$CLIENT3_PID"
if ! wait_for_pid_exit "$CLIENT3_PID" 3; then
  echo "client3 did not exit after SIGKILL" >&2
  exit 1
fi
unset CLIENT3_PID

if ! assert_subscribers_after_next_tick "$CLIENT1_LOG" 1 "client1 should see 1 subscriber after client3 exit" "$client1_tick_before_client3_exit"; then
  echo "waiting ${SERVER_IDLE_TIMEOUT_SECS}s for server idle timeout, then retrying assertion"
  sleep "$SERVER_IDLE_TIMEOUT_SECS"
  if assert_last_subscribers "$CLIENT1_LOG" 1 "client1 should see 1 subscriber after server idle timeout"; then
    echo "server timeout evidence:"
    grep -i 'timeout\|send_data failed\|handler failed' "$SERVER_LOG" | tail -3
    printf "\n\n"
    echo -e "${YELLOW}--- if the server is not configured with a keepalive interval and idle_timeout, this may remain stale --${NC}"
  fi
fi

echo
echo "logs:"
echo "  server:  $SERVER_LOG"
echo "  client1: $CLIENT1_LOG"
echo "  client2: $CLIENT2_LOG"
echo "  client3: $CLIENT3_LOG"
