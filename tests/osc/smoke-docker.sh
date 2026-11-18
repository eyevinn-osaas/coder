#!/bin/bash
# Docker smoke test for the first-user bootstrap: builds Dockerfile.osc for
# linux/amd64, runs it against a throwaway Postgres and checks the real Coder
# server. Needs docker and network access to pull images. Usage:
#
#   tests/osc/smoke-docker.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}/../.."
SUFFIX="$$"
NET="osc-coder-smoke-${SUFFIX}"
PG="osc-coder-smoke-pg-${SUFFIX}"
CD="osc-coder-smoke-coder-${SUFFIX}"
IMG="osc-coder-smoke:${SUFFIX}"
PORT="${SMOKE_PORT:-18080}"
PASSWORD='Sm0ke-T3st"pass\word-9x'
FAILS=0

cleanup() {
  docker rm -f "$CD" "$PG" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  docker rmi "$IMG" >/dev/null 2>&1
}
trap cleanup EXIT

ok() { echo "ok   - $1"; }
fail() {
  echo "FAIL - $1"
  FAILS=$((FAILS + 1))
}
check() {
  local d=$1
  shift
  if "$@"; then ok "$d"; else fail "$d"; fi
}

wait_log() { # wait_log PATTERN SECONDS
  local n=$(($2 * 2))
  while [ "$n" -gt 0 ]; do
    docker logs "$CD" 2>&1 | grep -q -- "$1" && return 0
    sleep 0.5
    n=$((n - 1))
  done
  return 1
}

run_coder() { # run_coder [extra docker env args...]
  docker run -d --name "$CD" --network "$NET" --platform linux/amd64 --tmpfs /home/coder:uid=1000,gid=1000 -p "127.0.0.1:${PORT}:8080" \
    -e "DATABASE_URL=postgres://coder:coder@${PG}:5432/coder?sslmode=disable" \
    "$@" "$IMG" /opt/coder server >/dev/null
}

docker build --platform linux/amd64 -f "${ROOT}/Dockerfile.osc" -t "$IMG" "$ROOT" >/dev/null || {
  echo "build failed"
  exit 1
}
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_USER=coder -e POSTGRES_PASSWORD=coder -e POSTGRES_DB=coder postgres:16-alpine >/dev/null
for _ in $(seq 1 60); do
  docker exec "$PG" pg_isready -U coder >/dev/null 2>&1 && break
  sleep 1
done

# 1. Options set: first user is created, can log in, password not in logs/env.
run_coder -e OSC_FIRST_USER_EMAIL=admin@example.com -e OSC_FIRST_USER_PASSWORD="$PASSWORD"
check "created: log line" wait_log "created first user 'admin'" 240
check "created: GET /api/v2/users/first is 200" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/v2/users/first")" = 200
login=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"admin@example.com\",\"password\":\"$(printf '%s' "$PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')\"}" \
  "http://127.0.0.1:${PORT}/api/v2/users/login")
check "created: login with the given password succeeds (201)" test "$login" = 201
check "created: password not in container logs" bash -c '! docker logs "$1" 2>&1 | grep -qF -- "$2"' _ "$CD" "$PASSWORD"
check "created: password not in the server process environment" bash -c '! docker exec "$1" sh -c "cat /proc/1/environ" | tr "\0" "\n" | grep -q "^OSC_FIRST_USER_PASSWORD="' _ "$CD"
check "created: coder server is PID 1" bash -c 'docker exec "$1" sh -c "tr \"\\0\" \" \" </proc/1/cmdline" | grep -q "^/opt/coder server"' _ "$CD"

# 2. Restart (same database): idempotent, no second user, no failure.
docker restart "$CD" >/dev/null
check "restart: already-exists log line" wait_log "a first user already exists" 240
check "restart: no error logged" bash -c '! docker logs "$1" 2>&1 | grep -q "first-user: ERROR"' _ "$CD"
check "restart: server healthy" curl -sf "http://127.0.0.1:${PORT}/healthz" -o /dev/null
docker rm -f "$CD" >/dev/null

# 3. Defaults: options unset on a fresh instance behave as before (no setup, setup page stays open).
docker exec "$PG" psql -U coder -c 'DROP DATABASE coder' postgres >/dev/null 2>&1
docker exec "$PG" psql -U coder -c 'CREATE DATABASE coder' postgres >/dev/null 2>&1
run_coder
for _ in $(seq 1 240); do
  curl -sf "http://127.0.0.1:${PORT}/healthz" -o /dev/null && break
  sleep 0.5
done
check "unset: no first user created (GET is 404)" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/v2/users/first")" = 404
check "unset: no first-user log line" bash -c '! docker logs "$1" 2>&1 | grep -q "first-user"' _ "$CD"
docker rm -f "$CD" >/dev/null

# 4. Weak password: Coder rejects it, soft failure, server keeps running.
run_coder -e OSC_FIRST_USER_EMAIL=admin@example.com -e OSC_FIRST_USER_PASSWORD=weak
check "weak: error logged" wait_log "first-user: ERROR: POST /api/v2/users/first returned 400" 240
check "weak: server still healthy" curl -sf "http://127.0.0.1:${PORT}/healthz" -o /dev/null
check "weak: container still running" test "$(docker inspect -f '{{.State.Running}}' "$CD")" = true

# 5. While the helper waits (the scanning shell and its children are skipped: docker exec
#    gives them the container environment) (server never healthy), the password is in no
#    process environment and no command line inside the container.
docker rm -f "$CD" >/dev/null
docker run -d --name "$CD" --platform linux/amd64 \
  -e DATABASE_URL=postgres://x -e OSC_FIRST_USER_EMAIL=admin@example.com -e OSC_FIRST_USER_PASSWORD="$PASSWORD" \
  -e OSC_FIRST_USER_WAIT_RETRIES=100 -e OSC_FIRST_USER_WAIT_SLEEP=1 "$IMG" sleep 30 >/dev/null
sleep 3
scan='e=0;a=0;h=0;me=$$;for d in /proc/[0-9]*; do pid=${d#/proc/}; pp=$(sed -n "s/^PPid:[[:space:]]*//p" $d/status 2>/dev/null); [ "$pid" = "$me" ] || [ "$pp" = "$me" ] && continue; tr "\0" "\n" <$d/environ 2>/dev/null | grep -q "^OSC_FIRST_USER_PASSWORD=" && e=1; tr "\0" "\n" <$d/environ 2>/dev/null | grep -q "^OSC_FIRST_USER_HELPER=1" && h=1; tr "\0" " " <$d/cmdline 2>/dev/null | grep -qF -- "$PW" && a=1; done; echo "$e $a $h"'
res=$(docker exec -e PW="$PASSWORD" "$CD" sh -c "$scan")
check "helper: a waiting helper process exists" test "${res##* }" = 1
check "helper: no process environ contains OSC_FIRST_USER_PASSWORD" test "${res%% *}" = 0
check "helper: password in no process cmdline" test "$(echo "$res" | cut -d' ' -f2)" = 0

echo
if [ "$FAILS" -eq 0 ]; then
  echo "smoke test passed"
else
  echo "${FAILS} check(s) failed"
  exit 1
fi
