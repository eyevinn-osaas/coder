# Coder on Eyevinn Open Source Cloud (OSC)

This fork is built for OSC with `Dockerfile.osc`, which wraps the official
`ghcr.io/coder/coder` release image. `osc-entrypoint.sh` maps the OSC instance
options to Coder's own settings. (This file is OSC-only; the upstream README is
left untouched so fork syncs do not conflict.)

## Instance options

| Option | Env var in the container | Type | Required | Sensitive | Default |
|---|---|---|---|---|---|
| `name` | (instance name) | string | yes | no | |
| `PgConnectionUrl` | `DATABASE_URL` | string | yes | yes | |
| `AccessUrl` | `CODER_ACCESS_URL` | string | no | no | `https://<instance host>` |
| `TelemetryEnable` | `CODER_TELEMETRY_ENABLE` | boolean | no | no | `false` |
| `FirstUserEmail` | `OSC_FIRST_USER_EMAIL` | string | no | no | unset |
| `FirstUserUsername` | `OSC_FIRST_USER_USERNAME` | string | no | no | `admin` |
| `FirstUserPassword` | `OSC_FIRST_USER_PASSWORD` | string | no | yes | unset |

### Option mappings to add at import (supply team)

The mappings live in the maker order's `optionMappings`, not in this repo. Add
these three rows next to the existing ones:

| Option name | Env var |
|---|---|
| `FirstUserEmail` | `OSC_FIRST_USER_EMAIL` |
| `FirstUserUsername` | `OSC_FIRST_USER_USERNAME` |
| `FirstUserPassword` | `OSC_FIRST_USER_PASSWORD` |

`FirstUserPassword` must be marked sensitive in the service schema, like
`PgConnectionUrl`, so the platform stores and shows it as a secret.

## First user (admin) created at start

By default the first person to open a new Coder instance becomes its owner
through the setup page. To create that owner from code instead, set
`FirstUserEmail` and `FirstUserPassword` (and optionally `FirstUserUsername`):

```
{
  "name": "studio",
  "PgConnectionUrl": "{{secrets.coder-pg}}",
  "FirstUserEmail": "ops@example.com",
  "FirstUserUsername": "admin",
  "FirstUserPassword": "{{secrets.coder-admin}}"
}
```

Behaviour:

- Both `FirstUserEmail` and `FirstUserPassword` must be set. If neither is set
  the entrypoint behaves exactly as before. If only one is set, one warning is
  logged and nothing else happens.
- `coder server` is still started with `exec`, so it stays PID 1 and signals
  and the exit code are unchanged. The bootstrap runs in a background step that
  polls `http://127.0.0.1:<port>/healthz` (60 tries, 2 s apart), then calls
  `GET /api/v2/users/first` (404 means no user yet, 200 means one exists) and,
  only on 404, `POST /api/v2/users/first`. The local port is used, so the OSC
  login gate and `AccessUrl` do not matter.
- Idempotent: if a first user exists (also after a restart, or if a concurrent
  creation returns 409) nothing is created and one log line says so.
- Fail soft: if Coder never becomes healthy, or rejects the request (for
  example a password that is too weak: Coder requires about 52 bits of entropy
  and at most 64 characters), one `first-user: ERROR` line is logged and Coder
  keeps running; the setup page can still be used.
- The password is never logged. It is removed from the environment of the
  `coder server` process before the exec (so Terraform runs started by
  templates do not inherit it). The background step is a freshly exec'd process
  with a clean environment (`env -i`): the password reaches it on stdin only, so
  it is in no `/proc/<pid>/environ` and no command line. It is sent to curl on
  stdin too, and redacted from any error text.
- The created user has the `owner` role and password login. The first user is
  not created as a trial (`trial: false`).
- The gateway or any other client obtaining its own Coder API token (log in with
  this admin, then `POST /api/v2/users/me/keys/tokens`) is the client's job and
  is not done here.

## Tests

- `tests/osc/test-first-user.sh`: runs the real entrypoint against a stub HTTP
  server (needs bash, curl, python3).
- `tests/osc/smoke-docker.sh`: builds `Dockerfile.osc` for `linux/amd64` and
  runs it against a throwaway Postgres (needs docker).
- Lint: `shellcheck -x osc-entrypoint.sh tests/osc/*.sh`.
