#!/bin/bash
# Tests for the first-user bootstrap in osc-entrypoint.sh. They run the real
# entrypoint against a stub HTTP server that stands in for Coder (the stub is
# also the "server" process the entrypoint execs). Needs bash, curl, python3.
#
#   tests/osc/test-first-user.sh
# shellcheck disable=SC2016 # bash -c bodies are intentionally single-quoted
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY="${HERE}/../../osc-entrypoint.sh"
STUB="${HERE}/stub_coder.py"
TMP="$(mktemp -d)"
PIDS=()
FAILS=0
# shellcheck disable=SC2016
PASSWORD='p@ss"w\ord/with$pecial chars 1234567890!'

cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

ok() { echo "ok   - $1"; }
fail() {
  echo "FAIL - $1"
  FAILS=$((FAILS + 1))
}
check() { # check DESC CMD...
  local d=$1
  shift
  if "$@"; then ok "$d"; else fail "$d"; fi
}

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

posts() { grep -c '"method": "POST"' "$1" 2>/dev/null || true; }
first_gets() { grep -c '"path": "/api/v2/users/first"' "$1" 2>/dev/null || true; }

wait_for() { # wait_for SECONDS CMD...
  local n=$(($1 * 10))
  shift
  while [ "$n" -gt 0 ]; do
    if "$@"; then return 0; fi
    sleep 0.1
    n=$((n - 1))
  done
  return 1
}

# start_case NAME [stub args...]; sets PORT, LOG, BODIES, OUT and PID of entrypoint
# Extra environment for the entrypoint comes from the caller's exported vars.
start_case() {
  local name=$1
  shift
  PORT=$(free_port)
  LOG="${TMP}/${name}.requests"
  BODIES="${TMP}/${name}.bodies"
  OUT="${TMP}/${name}.out"
  : >"$LOG"
  : >"$BODIES"
  env PORT="$PORT" CODER_PG_CONNECTION_URL=postgres://x OSC_FIRST_USER_WAIT_SLEEP=0.2 \
    bash "$ENTRY" python3 "$STUB" --port "$PORT" --log "$LOG" --bodies "$BODIES" "$@" >"$OUT" 2>&1 &
  PID=$!
  PIDS+=("$PID")
  wait_for 5 curl -sf "http://127.0.0.1:${PORT}/healthz" -o /dev/null
}

stop_case() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }

unset OSC_FIRST_USER_EMAIL OSC_FIRST_USER_USERNAME OSC_FIRST_USER_PASSWORD

# --- json escaping roundtrip (sourced functions only) -------------------------
# shellcheck source=../../osc-entrypoint.sh
source "$ENTRY"
esc=$(osc_json_escape "$PASSWORD")
rt=$(ESC="$esc" python3 -c 'import json,os;print(json.loads("\"%s\"" % os.environ["ESC"]),end="")')
check "json escape roundtrips quotes, backslashes and symbols" test "$rt" = "$PASSWORD"
check "json escape rejects other control characters" bash -c 'source "$1"; ! osc_json_escape $'"'"'a\001b'"'"' >/dev/null' _ "$ENTRY"

# --- 1. options unset: no first-user call, no first-user log line -------------
start_case unset
sleep 1
check "unset: server started and exec'd" kill -0 "$PID"
check "unset: no request to /api/v2/users/first" test "$(first_gets "$LOG")" = 0
check "unset: no first-user log line" bash -c '! grep -q "first-user" "$1"' _ "$OUT"
stop_case

# --- 2. first user missing: one POST, correct body, password not in logs ------
export OSC_FIRST_USER_EMAIL=admin@example.com OSC_FIRST_USER_PASSWORD="$PASSWORD"
unset OSC_FIRST_USER_USERNAME
start_case missing
wait_for 8 grep -q 'created first user' "$OUT"
check "missing: created-first-user logged" grep -q "created first user 'admin'" "$OUT"
check "missing: exactly one POST" test "$(posts "$LOG")" = 1
body=$(head -1 "$BODIES")
check "missing: body has email, default username admin and the exact password" \
  env B="$body" P="$PASSWORD" python3 -c 'import json,os,sys;d=json.loads(os.environ["B"]);sys.exit(0 if d["email"]=="admin@example.com" and d["username"]=="admin" and d["password"]==os.environ["P"] and d["trial"] is False else 1)'
check "missing: password not in log output" bash -c '! grep -qF -- "$2" "$1"' _ "$OUT" "$PASSWORD"
check "missing: request body not in log output" bash -c '! grep -q "\"email\"" "$1"' _ "$OUT"
check "missing: server still running" kill -0 "$PID"
stop_case

# --- 3. first user exists: no POST --------------------------------------------
start_case exists --user-exists
wait_for 8 grep -q 'already exists' "$OUT"
check "exists: one-line already-exists message" grep -q "a first user already exists, nothing to do" "$OUT"
check "exists: no POST" test "$(posts "$LOG")" = 0
stop_case

# --- 3b. custom username ------------------------------------------------------
OSC_FIRST_USER_USERNAME=studio-op start_case custom
wait_for 8 grep -q 'created first user' "$OUT"
check "custom: username taken from option" grep -q "created first user 'studio-op'" "$OUT"
check "custom: username in body" bash -c 'grep -q "\"username\":\"studio-op\"" "$1"' _ "$BODIES"
stop_case

# --- 4. Coder rejects the request: soft failure, server unaffected -----------
start_case rejected --post-status 400
wait_for 8 grep -q 'first user not created' "$OUT"
check "rejected: clear error logged with status" grep -q "ERROR: POST /api/v2/users/first returned 400" "$OUT"
check "rejected: password not in log output" bash -c '! grep -qF -- "$2" "$1"' _ "$OUT" "$PASSWORD"
check "rejected: server still running and healthy" curl -sf "http://127.0.0.1:${PORT}/healthz" -o /dev/null
stop_case

# --- 5. server never healthy: soft failure, exit code of the server preserved -
PORT=$(free_port) CODER_PG_CONNECTION_URL=postgres://x OSC_FIRST_USER_WAIT_RETRIES=3 OSC_FIRST_USER_WAIT_SLEEP=0.2 \
  bash "$ENTRY" sh -c 'sleep 2; exit 7' >"${TMP}/never.out" 2>&1
code=$?
check "never healthy: server exit code passes through unchanged" test "$code" = 7
check "never healthy: clear error logged" grep -q "ERROR: server did not become healthy" "${TMP}/never.out"
check "never healthy: password not in log output" bash -c '! grep -qF -- "$2" "$1"' _ "${TMP}/never.out" "$PASSWORD"

# --- 5b. while the helper waits, the password is in no environ and no argv ----
# (/proc only exists on Linux; the docker smoke test covers this too.)
if [ -d /proc/self ]; then
  PORT=$(free_port) CODER_PG_CONNECTION_URL=postgres://x OSC_FIRST_USER_WAIT_RETRIES=40 OSC_FIRST_USER_WAIT_SLEEP=0.25 \
    bash "$ENTRY" sleep 6 >"${TMP}/proc.out" 2>&1 &
  PID=$!
  PIDS+=("$PID")
  sleep 1.5
  leaked_env=0 leaked_arg=0 helpers=0
  for d in /proc/[0-9]*; do
    if tr '\0' '\n' <"$d/environ" 2>/dev/null | grep -q '^OSC_FIRST_USER_PASSWORD='; then leaked_env=1; fi
    if tr '\0' ' ' <"$d/cmdline" 2>/dev/null | grep -qF -- "$PASSWORD"; then leaked_arg=1; fi
    if tr '\0' '\n' <"$d/environ" 2>/dev/null | grep -q '^OSC_FIRST_USER_HELPER=1'; then helpers=$((helpers + 1)); fi
  done
  check "helper: a waiting helper process exists" test "$helpers" -ge 1
  check "helper: no process has OSC_FIRST_USER_PASSWORD in /proc/<pid>/environ" test "$leaked_env" = 0
  check "helper: password in no process cmdline" test "$leaked_arg" = 0
  wait "$PID" 2>/dev/null
else
  echo "skip - /proc not available, helper environ/cmdline check not run"
fi

# --- 6. only one of the two options set: warning, nothing else ----------------
(
  unset OSC_FIRST_USER_EMAIL
  PORT=$(free_port) CODER_PG_CONNECTION_URL=postgres://x bash "$ENTRY" true >"${TMP}/partial.out" 2>&1
)
check "partial: warns and skips" grep -q "must both be set; skipping" "${TMP}/partial.out"

# --- 7. the exec'd server does not inherit the first-user variables -----------
env_out=$(PORT=1 CODER_PG_CONNECTION_URL=postgres://x OSC_FIRST_USER_WAIT_RETRIES=0 bash "$ENTRY" env 2>/dev/null)
check "env: server environment lacks OSC_FIRST_USER_*" bash -c '! grep -Eq "^OSC_FIRST_USER_(EMAIL|USERNAME|PASSWORD)=" <<<"$1"' _ "$env_out"
check "env: existing mappings unchanged (telemetry off, http address)" bash -c 'grep -q "^CODER_TELEMETRY_ENABLE=false" <<<"$1" && grep -q "^CODER_HTTP_ADDRESS=0.0.0.0:1" <<<"$1"' _ "$env_out"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "all tests passed"
else
  echo "${FAILS} test(s) failed"
  exit 1
fi
