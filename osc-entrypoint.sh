#!/bin/bash
# OSC entrypoint for Coder: maps platform variables to Coder's own settings.
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

exec "$@"
