set shell := ["bash", "-cu"]

SCENARIO := "tests/scenario.sh"
LOG_DIR := "tests/logs"

_default:
  @just --list

default: _default

build:
  cargo build -p h3-server -p h3-client

smoke:
  bash {{SCENARIO}}

run: smoke

repro: smoke

clean-logs:
  rm -f {{LOG_DIR}}/server.log {{LOG_DIR}}/client1.log {{LOG_DIR}}/client2.log {{LOG_DIR}}/client3.log

logs:
  @echo "server:  {{LOG_DIR}}/server.log"
  @echo "client1: {{LOG_DIR}}/client1.log"
  @echo "client2: {{LOG_DIR}}/client2.log"
  @echo "client3: {{LOG_DIR}}/client3.log"

server-log:
  tail -n 40 {{LOG_DIR}}/server.log

client1-log:
  tail -n 40 {{LOG_DIR}}/client1.log

client2-log:
  tail -n 40 {{LOG_DIR}}/client2.log

client3-log:
  tail -n 40 {{LOG_DIR}}/client3.log

timeout-evidence:
  grep -i 'timeout\|send_data failed\|handler failed' {{LOG_DIR}}/server.log || true

watch-logs:
  tail -f {{LOG_DIR}}/server.log {{LOG_DIR}}/client1.log {{LOG_DIR}}/client2.log {{LOG_DIR}}/client3.log