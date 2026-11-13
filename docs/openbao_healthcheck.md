# `openbao_healthcheck.sh`

Runs an end-to-end smoke test against an [OpenBao](https://openbao.org/) (or Vault-compatible) server over its HTTP API. It checks the server, logs in with userpass, then exercises the KV secrets engine and policy listing, printing a colored `[SUCCESS]`/`[FAILED]` line per step.

The checks run in order:

1. **Health** — server is reachable, initialized, and unsealed (`GET /v1/sys/health`). If this fails the run stops.
2. **Authentication** — userpass login (`POST /v1/auth/userpass/login/<user>`) and capture a token.
3. **List** — list keys under the `secret/` KV mount (`LIST /v1/secret/metadata`).
4. **Write** — write a random GUID to `secret/health-check` (`POST /v1/secret/data/health-check`).
5. **Read back** — read `secret/health-check` and confirm the value matches what was written.
6. **Policies** — list ACL policies (`GET /v1/sys/policies/acl`).

Steps 3–6 are skipped if authentication fails.

> **Note:** this script is not read-only — step 4 **writes** a secret to `secret/health-check` on the KV v2 engine, overwriting any existing value at that path. It prints a backup warning before starting unless you pass `--no-warning`. It assumes a KV v2 engine mounted at `secret/` and the userpass auth method enabled.

**Requires:** `bash`, `curl`. `jq` is used when available, with a `grep`/`sed` fallback otherwise.

## Flags

* **`-u` / `--username USER`**: Username for userpass authentication. Prompted interactively if not supplied.
* **`-p` / `--password PASS`**: Password for userpass authentication. Prompted interactively (hidden input) if not supplied. Prefer the prompt or an env-based wrapper over passing the secret on the command line, where it is visible in the host's process list.
* **`--vault-addr ADDR`**: OpenBao server address. Defaults to `$BAO_ADDR`, or `http://127.0.0.1:8200` if that is unset.
* **`--no-warning`**: Skip the backup warning shown before the checks run.
* **`-h` / `--help`**: Show help and exit.

## Usage Examples

**Run against the local server, prompting for credentials:**

```bash
./openbao_healthcheck.sh
```

**Run against a remote server with credentials on the command line:**

```bash
./openbao_healthcheck.sh --vault-addr https://bao.example.org:8200 -u healthcheck -p "$BAO_PASSWORD"
```

**Point at a server via the environment and skip the warning (e.g. in a cron job):**

```bash
BAO_ADDR=https://bao.example.org:8200 ./openbao_healthcheck.sh -u healthcheck -p "$BAO_PASSWORD" --no-warning
```
