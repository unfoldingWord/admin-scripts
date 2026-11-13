#!/usr/bin/env bash
#
# send_otlp.sh
# Send a single sample metric to an OTLP/HTTP endpoint as a smoke test.
#
# Purpose: verify end to end that an OTLP/HTTP metrics endpoint accepts writes —
# the URL is reachable, an optional tenant header is accepted, and (optionally)
# Basic Auth credentials are valid. It POSTs one minimal OTLP/JSON gauge data
# point stamped "now" and reports the HTTP result.
#
# It is deliberately not a general OTLP forwarder: the body is a built-in sample
# metric, not user-supplied telemetry.
#
# Tenancy: the X-Scope-OrgID header is the multi-tenant selector used by the
# Cortex-derived stack (Grafana Mimir, Loki, Tempo). It is NOT part of OTLP, so
# it is optional here — set the org id to send it (required by multi-tenant
# Mimir), leave it unset for a plain OTLP endpoint.
#
# Parameters come from flags first, then environment variables; a required
# parameter that is set by neither is a hard error.
#
#   Parameter      Flag                     Env var           Required
#   -------------  -----------------------  ----------------  --------
#   endpoint       -e, --endpoint URL       OTLP_ENDPOINT     yes
#   tenant/org id  -o, --org-id ID          OTLP_ORG_ID       no (X-Scope-OrgID)
#   username       -u, --username USER      OTLP_USERNAME     no (Basic Auth)
#   password       -p, --password PASS      OTLP_PASSWORD     no (Basic Auth)
#   metric name    -n, --metric-name NAME   OTLP_METRIC_NAME  no (default below)
#   metric value   -V, --value NUM          OTLP_METRIC_VALUE no (default below)
#
# Basic Auth is optional and all-or-nothing: supply BOTH username and password
# to enable it, or NEITHER to send unauthenticated. Supplying only one is an
# error. Prefer $OTLP_PASSWORD over --password so the secret is not visible in
# the host's process list.
#
# The endpoint must be the full OTLP metrics URL, e.g.
#   https://collector.example.org/v1/metrics
#   https://mimir.example.org/otlp/v1/metrics      (Mimir prefixes /otlp)
#
# Requires: bash, curl, date (GNU coreutils, for nanosecond timestamps).
#
# Usage:
#   ./send_otlp.sh -e https://collector.example.org/v1/metrics
#   ./send_otlp.sh -e https://mimir.example.org/otlp/v1/metrics -o team-a
#   OTLP_ENDPOINT=... OTLP_ORG_ID=team-a ./send_otlp.sh
#   ./send_otlp.sh -e "$URL" -o team-a -u writer -p "$SECRET"

set -euo pipefail

# --- config (flags override these env-derived defaults) -------------------

ENDPOINT="${OTLP_ENDPOINT:-}"
ORG_ID="${OTLP_ORG_ID:-}"
USERNAME="${OTLP_USERNAME:-}"
PASSWORD="${OTLP_PASSWORD:-}"
METRIC_NAME="${OTLP_METRIC_NAME:-otlp_smoke_test}"
METRIC_VALUE="${OTLP_METRIC_VALUE:-1}"

usage() {
  cat <<EOF
Usage: send_otlp.sh [options]

Send one sample OTLP/JSON gauge metric to an OTLP/HTTP endpoint as a smoke test.

  -e, --endpoint URL     Full OTLP metrics URL, e.g. https://host/v1/metrics
                         (Mimir: https://host/otlp/v1/metrics).
                         Required. Env: OTLP_ENDPOINT
  -o, --org-id ID        Tenant for the X-Scope-OrgID header (Mimir/Loki/Tempo).
                         Sent only when set. Env: OTLP_ORG_ID
  -u, --username USER    Basic Auth username. Env: OTLP_USERNAME
  -p, --password PASS    Basic Auth password. Env: OTLP_PASSWORD (preferred).
  -n, --metric-name NAME Metric name to emit. Default: $METRIC_NAME
                         Env: OTLP_METRIC_NAME
  -V, --value NUM        Gauge value to emit. Default: $METRIC_VALUE
                         Env: OTLP_METRIC_VALUE
  -h, --help             Show this help and exit.

Each parameter is read from its flag first, then its environment variable; a
required parameter set by neither is an error. Basic Auth is optional but
all-or-nothing: give both username and password, or neither.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -e|--endpoint)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      ENDPOINT="$2"; shift 2 ;;
    --endpoint=*)
      ENDPOINT="${1#*=}"; shift ;;
    -o|--org-id)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      ORG_ID="$2"; shift 2 ;;
    --org-id=*)
      ORG_ID="${1#*=}"; shift ;;
    -u|--username)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      USERNAME="$2"; shift 2 ;;
    --username=*)
      USERNAME="${1#*=}"; shift ;;
    -p|--password)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      PASSWORD="$2"; shift 2 ;;
    --password=*)
      PASSWORD="${1#*=}"; shift ;;
    -n|--metric-name)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      METRIC_NAME="$2"; shift 2 ;;
    --metric-name=*)
      METRIC_NAME="${1#*=}"; shift ;;
    -V|--value)
      [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      METRIC_VALUE="$2"; shift 2 ;;
    --value=*)
      METRIC_VALUE="${1#*=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- logging --------------------------------------------------------------

# Emit one timestamped line to stdout. Format: "2026-09-29T12:34:56Z [INFO ] msg".
log() {
  local level="$1"; shift
  printf '%s [%-5s] %s\n' "$(date -u +%FT%TZ)" "$level" "$*"
}

# --- preflight ------------------------------------------------------------

[ -n "$ENDPOINT" ] || { echo "Error: endpoint is required (-e/--endpoint or \$OTLP_ENDPOINT)." >&2; usage >&2; exit 2; }

# Basic Auth is all-or-nothing: reject exactly one of username/password.
USE_AUTH=false
if [ -n "$USERNAME" ] || [ -n "$PASSWORD" ]; then
  if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "Error: Basic Auth needs BOTH username and password (or neither)." >&2
    exit 2
  fi
  USE_AUTH=true
fi

# Guard the two values that get interpolated into the JSON body so they cannot
# break its structure: a Prometheus-style metric name and a plain number.
if ! [[ "$METRIC_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]]; then
  echo "Error: metric name must match ^[a-zA-Z_][a-zA-Z0-9_.]*$ : $METRIC_NAME" >&2
  exit 2
fi
if ! [[ "$METRIC_VALUE" =~ ^-?([0-9]+\.?[0-9]*|\.[0-9]+)$ ]]; then
  echo "Error: value must be a number: $METRIC_VALUE" >&2
  exit 2
fi

command -v curl >/dev/null 2>&1 || { log ERROR "curl not found on PATH"; exit 1; }

# --- build the OTLP/JSON payload ------------------------------------------

# OTLP timestamps are int64 nanoseconds since the Unix epoch, carried as a JSON
# string. GNU date's %N gives nanoseconds; stamp the point "now" so the backend
# accepts it within its ingestion window.
ts_nanos="$(date +%s%N)"
host="$(hostname 2>/dev/null || echo unknown)"

read -r -d '' payload <<JSON || true
{
  "resourceMetrics": [
    {
      "resource": {
        "attributes": [
          { "key": "service.name", "value": { "stringValue": "otlp-smoke-test" } },
          { "key": "host.name",    "value": { "stringValue": "$host" } }
        ]
      },
      "scopeMetrics": [
        {
          "scope": { "name": "admin-scripts/send_otlp.sh" },
          "metrics": [
            {
              "name": "$METRIC_NAME",
              "description": "Smoke-test gauge emitted by send_otlp.sh",
              "unit": "1",
              "gauge": {
                "dataPoints": [
                  {
                    "asDouble": $METRIC_VALUE,
                    "timeUnixNano": "$ts_nanos"
                  }
                ]
              }
            }
          ]
        }
      ]
    }
  ]
}
JSON

# --- send -----------------------------------------------------------------

log INFO "Sending metric '$METRIC_NAME'=$METRIC_VALUE to $ENDPOINT (org-id=${ORG_ID:-none}, auth=$USE_AUTH)"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

curl_args=(
  --silent --show-error
  -X POST "$ENDPOINT"
  -H "Content-Type: application/json"
  --data-binary "$payload"
  -o "$body_file"
  -w '%{http_code}'
)
# X-Scope-OrgID only when a tenant is set (Cortex-family multi-tenancy).
[ -n "$ORG_ID" ] && curl_args+=(-H "X-Scope-OrgID: $ORG_ID")
# -u only when auth is enabled; curl reads user:pass, never echoed back.
[ "$USE_AUTH" = true ] && curl_args+=(-u "$USERNAME:$PASSWORD")

http_code="$(curl "${curl_args[@]}")" || {
  log ERROR "curl failed to reach $ENDPOINT"
  exit 1
}

response_body="$(cat "$body_file")"

# OTLP/HTTP returns 2xx on success (200 with an empty or partialSuccess body).
# Anything else is a failure worth surfacing verbatim.
case "$http_code" in
  2*)
    log INFO "Success: HTTP $http_code"
    [ -n "$response_body" ] && log INFO "Response: $response_body"
    exit 0 ;;
  *)
    log ERROR "Failed: HTTP $http_code"
    [ -n "$response_body" ] && log ERROR "Response: $response_body"
    exit 1 ;;
esac
