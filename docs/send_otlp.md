# `send_otlp.sh`

Sends a single sample metric to an OTLP/HTTP endpoint as a smoke test. It POSTs one minimal OTLP/JSON gauge data point stamped "now" and reports the HTTP result — a quick "is this pipe open?" check that the endpoint is reachable, accepts writes, and (optionally) that a tenant header and Basic Auth credentials are valid.

It is deliberately **not** a general OTLP forwarder: the body is a built-in sample metric, not user-supplied telemetry. A 2xx response exits `0`; anything else prints the response body and exits `1`.

The `X-Scope-OrgID` header is the multi-tenant selector used by the Cortex-derived stack (Grafana Mimir, Loki, Tempo). It is **not** part of OTLP, so it is optional here — set the org id to send it (required by multi-tenant Mimir), leave it unset for a plain OTLP endpoint.

The endpoint must be the full OTLP metrics URL, e.g.

* `https://collector.example.org/v1/metrics`
* `https://mimir.example.org/otlp/v1/metrics` (Mimir prefixes `/otlp`)

Each parameter is read from its flag first, then its environment variable; a required parameter set by neither is a hard error. Basic Auth is optional but all-or-nothing: supply **both** username and password, or **neither**. Prefer `$OTLP_PASSWORD` over `--password` so the secret is not visible in the host's process list.

**Requires:** `bash`, `curl`, and GNU `date` (for nanosecond timestamps).

## Flags

Each flag has a matching environment variable; the flag wins if both are set.

* **`-e` / `--endpoint URL`**: Full OTLP metrics URL. **Required.** Env: `OTLP_ENDPOINT`
* **`-o` / `--org-id ID`**: Tenant for the `X-Scope-OrgID` header (Mimir/Loki/Tempo). Sent only when set. Env: `OTLP_ORG_ID`
* **`-u` / `--username USER`**: Basic Auth username. Env: `OTLP_USERNAME`
* **`-p` / `--password PASS`**: Basic Auth password. Env: `OTLP_PASSWORD` (preferred).
* **`-n` / `--metric-name NAME`**: Metric name to emit. Must match `^[a-zA-Z_][a-zA-Z0-9_.]*$`. Default: `otlp_smoke_test`. Env: `OTLP_METRIC_NAME`
* **`-V` / `--value NUM`**: Gauge value to emit (any number). Default: `1`. Env: `OTLP_METRIC_VALUE`
* **`-h` / `--help`**: Show help and exit.

## Usage Examples

**Send one sample metric to a plain OTLP collector:**

```bash
./send_otlp.sh -e https://collector.example.org/v1/metrics
```

**Send to a multi-tenant Mimir endpoint (note the `/otlp` prefix and tenant):**

```bash
./send_otlp.sh -e https://mimir.example.org/otlp/v1/metrics -o team-a
```

**Configure entirely via the environment:**

```bash
OTLP_ENDPOINT=https://mimir.example.org/otlp/v1/metrics OTLP_ORG_ID=team-a ./send_otlp.sh
```

**Send with Basic Auth, keeping the password out of the process list:**

```bash
OTLP_PASSWORD="$SECRET" ./send_otlp.sh -e "$URL" -o team-a -u writer
```

**Emit a custom metric name and value:**

```bash
./send_otlp.sh -e "$URL" -n ingest_probe -V 1
```
