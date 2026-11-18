#!/bin/bash
# OSC entrypoint for Coder: maps platform variables to Coder's own settings.
#
# Optional first-user bootstrap (see OSC.md): when OSC_FIRST_USER_EMAIL and
# OSC_FIRST_USER_PASSWORD are both set, a background step creates Coder's
# first (owner) user through the local API once the server is healthy. The
# server itself is still exec'd below, so PID 1, signal handling and the exit
# code are unchanged.

# Strip a string down to what may sit inside a JSON string literal.
osc_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  if [[ $s =~ [[:cntrl:]] ]]; then
    return 1
  fi
  printf '%s' "$s"
}

osc_first_user_log() {
  echo "osc-entrypoint: first-user: $*" >&2
}

# osc_create_first_user EMAIL USERNAME PASSWORD PORT
# Waits for the local server, then creates the first user if none exists.
# Returns 0 when the first user exists afterwards (created now or before) and
# non-zero on any failure. It never prints the password or the request body.
osc_create_first_user() {
  local email=$1 username=$2 password=$3 port=$4
  local base="http://127.0.0.1:${port}"
  local retries=${OSC_FIRST_USER_WAIT_RETRIES:-60}
  local wait_s=${OSC_FIRST_USER_WAIT_SLEEP:-2}
  local i status

  # 1. Wait until the local server answers /healthz (bounded).
  local healthy=0
  for ((i = 0; i < retries; i++)); do
    if curl -sf -o /dev/null --max-time 5 "${base}/healthz" 2>/dev/null; then
      healthy=1
      break
    fi
    sleep "$wait_s"
  done
  if [ "$healthy" != 1 ]; then
    osc_first_user_log "ERROR: server did not become healthy on ${base}/healthz after ${retries} attempts; first user not created (use the setup page instead)"
    return 1
  fi

  # 2. Does a first user exist? GET /api/v2/users/first: 200 yes, 404 no.
  status=000
  for ((i = 0; i < 5; i++)); do
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${base}/api/v2/users/first" 2>/dev/null) || status=000
    if [ "$status" = 200 ] || [ "$status" = 404 ]; then
      break
    fi
    sleep "$wait_s"
  done
  if [ "$status" = 200 ]; then
    osc_first_user_log "a first user already exists, nothing to do"
    return 0
  fi
  if [ "$status" != 404 ]; then
    osc_first_user_log "ERROR: unexpected status ${status} from GET /api/v2/users/first; first user not created"
    return 1
  fi

  # 3. Create it. The body goes to curl on stdin (never argv, never a file).
  local e_email e_user e_pass body
  if ! e_email=$(osc_json_escape "$email") || ! e_user=$(osc_json_escape "$username") || ! e_pass=$(osc_json_escape "$password"); then
    osc_first_user_log "ERROR: first user options contain control characters; first user not created"
    return 1
  fi
  body="{\"email\":\"${e_email}\",\"username\":\"${e_user}\",\"password\":\"${e_pass}\",\"trial\":false}"

  local resp http msg
  resp=$(curl -s -w $'\n%{http_code}' --max-time 30 -X POST \
    -H 'Content-Type: application/json' --data-binary @- \
    "${base}/api/v2/users/first" <<<"$body" 2>/dev/null) || resp=$'\n000'
  body=""
  e_pass=""
  http=${resp##*$'\n'}
  msg=${resp%$'\n'*}
  # Defence in depth: the server never echoes the password, but redact anyway.
  if [ -n "$password" ]; then
    msg=${msg//"$password"/'[redacted]'}
  fi
  msg=${msg:0:300}

  case "$http" in
    201)
      osc_first_user_log "created first user '${username}'"
      return 0
      ;;
    409)
      osc_first_user_log "a first user already exists (created concurrently), nothing to do"
      return 0
      ;;
    *)
      osc_first_user_log "ERROR: POST /api/v2/users/first returned ${http}: ${msg}; first user not created (use the setup page instead)"
      return 1
      ;;
  esac
}

# When sourced (tests), only define the functions above.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

# Helper mode: this script re-executed with a clean environment by the main
# flow below. The password arrives on stdin (read to EOF, so any character is
# allowed) and lives only in a non-exported shell variable, so it is never in
# /proc/<pid>/environ or /proc/<pid>/cmdline of this process.
if [ "${OSC_FIRST_USER_HELPER:-}" = 1 ]; then
  IFS= read -r -d '' helper_password || true
  osc_create_first_user "${OSC_FIRST_USER_EMAIL:-}" "${OSC_FIRST_USER_USERNAME:-admin}" "$helper_password" "${OSC_FIRST_USER_PORT:-8080}"
  exit 0
fi

set -e

PORT="${PORT:-8080}"

# Listen on the OSC-provided port on all interfaces.
export CODER_HTTP_ADDRESS="${CODER_HTTP_ADDRESS:-0.0.0.0:${PORT}}"

# Public URL of the instance (no path).
if [ -z "${CODER_ACCESS_URL}" ] && [ -n "${OSC_HOSTNAME}" ]; then
  export CODER_ACCESS_URL="https://${OSC_HOSTNAME}"
fi

# TLS is terminated by the OSC ingress.
export CODER_TLS_ENABLE="${CODER_TLS_ENABLE:-false}"

# Postgres: accept DATABASE_URL as an alias for CODER_PG_CONNECTION_URL.
if [ -z "${CODER_PG_CONNECTION_URL}" ] && [ -n "${DATABASE_URL}" ]; then
  export CODER_PG_CONNECTION_URL="${DATABASE_URL}"
fi
if [ -z "${CODER_PG_CONNECTION_URL}" ]; then
  echo "osc-entrypoint: CODER_PG_CONNECTION_URL (or DATABASE_URL) is required; Coder's built-in Postgres is not persistent on OSC" >&2
  exit 1
fi

# Telemetry off unless the user opts in.
export CODER_TELEMETRY_ENABLE="${CODER_TELEMETRY_ENABLE:-false}"

# Optional first-user bootstrap. The values are removed from the environment
# so that the server and the Terraform it runs for templates never see the
# password; the helper below gets it over stdin only.
first_user_email="${OSC_FIRST_USER_EMAIL:-}"
first_user_username="${OSC_FIRST_USER_USERNAME:-admin}"
first_user_password="${OSC_FIRST_USER_PASSWORD:-}"
unset OSC_FIRST_USER_EMAIL OSC_FIRST_USER_USERNAME OSC_FIRST_USER_PASSWORD

if [ -n "$first_user_email" ] && [ -n "$first_user_password" ]; then
  # Fresh process with a minimal environment: a plain background subshell would
  # keep this process's original environment block (with the password) in
  # /proc/<pid>/environ until it exits. printf is a builtin, so the password
  # is on neither argv nor in the helper's environment.
  printf '%s' "$first_user_password" | env -i PATH="$PATH" \
    OSC_FIRST_USER_HELPER=1 \
    OSC_FIRST_USER_EMAIL="$first_user_email" \
    OSC_FIRST_USER_USERNAME="$first_user_username" \
    OSC_FIRST_USER_PORT="${CODER_HTTP_ADDRESS##*:}" \
    ${OSC_FIRST_USER_WAIT_RETRIES:+OSC_FIRST_USER_WAIT_RETRIES="$OSC_FIRST_USER_WAIT_RETRIES"} \
    ${OSC_FIRST_USER_WAIT_SLEEP:+OSC_FIRST_USER_WAIT_SLEEP="$OSC_FIRST_USER_WAIT_SLEEP"} \
    bash "$0" &
elif [ -n "$first_user_email" ] || [ -n "$first_user_password" ]; then
  osc_first_user_log "FirstUserEmail and FirstUserPassword must both be set; skipping first user creation"
fi
first_user_password=""

exec "$@"
