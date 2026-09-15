# `find_grafana_usage.py`

Scans a Grafana instance and reports dashboard panels and alert rules that match a set of **composable filters**. Handy for migration worklists, audits, and "where is X still used?" questions — e.g. everything still on Graphite, everything on InfluxDB, all legacy Angular `graph` panels, or every query matching a metric-name pattern.

It understands the classic dashboard schema, the v1 "Resource" wrapper, and the v2 "Dynamic Dashboards" (tabs/rows/grid) schema, plus Grafana-managed alert rules.

**Requires:** Python 3 and the `requests` package (a `.venv` is present in the repo for this).

## Filters

All filters are optional and combine with **AND**; omit one and it's unconstrained. With no filters at all, every panel/alert query is reported (an inventory dump — the script prints a note to stderr when this happens).

* **`--datasource-type <type...>`**: One or more datasource plugin types, e.g. `graphite`, `influxdb`, `prometheus`. Pass `any` (or omit) to match any datasource.
* **`--query-match <regex>`**: A regular expression matched against each query string with `re.search` (so an unanchored pattern behaves like a substring match). Omit to match any query — including panels that expose no query text at all; those show `(no query text)` in the query column. Setting `--query-match` necessarily excludes those, since there is nothing to match against. A panel has no query text only when its plugin stores builder queries purely structurally (e.g. the classic InfluxQL builder or Graphite's builder); some plugins always emit text even in builder mode — InfluxDB 3, for instance, generates `rawSql` from the builder — so the placeholder is *not* a reliable "built with the builder" indicator. Env: `GRAFANA_QUERY_MATCH`.
* **`--panel-type <type...>`**: One or more panel/visualization types, e.g. `timeseries`, `graph`, `stat`. Panels only — alert rules have no panel type, so this filter never applies to them. Omit to match any.
* **`--folder <title...>`**: One or more folder titles (applies to both panels and alerts). Omit to match any.

## Connection & output flags

* **`--host <url>`**: Grafana base URL, e.g. `https://grafana.example.org` (env: `GRAFANA_HOST`).
* **`--api-key <token>`**: Grafana API key / service account token (env: `GRAFANA_API_KEY`).
* **`--format <table|csv|json>`**: Output format. Default: `table` (a Markdown checklist table with a `Done` column for worklists).
* **`--no-verify-ssl`**: Disable TLS certificate verification (env: `GRAFANA_VERIFY_SSL=false`).
* **`--skip-panels`**: Skip scanning dashboard panels (alert rules only).
* **`--skip-alerts`**: Skip scanning alert rules (dashboard panels only).
* **`-v` / `--verbose`**: Print progress to stderr while scanning.
* **`-h` / `--help`**: Show help and exit.

Configuration can come from CLI flags or the `GRAFANA_HOST`, `GRAFANA_API_KEY`, `GRAFANA_QUERY_MATCH`, and `GRAFANA_VERIFY_SSL` environment variables (the flag wins if both are given).

## Usage Examples

**Graphite/Telegraf migration worklist (the original use case):**

```bash
python find_grafana_usage.py --host https://grafana.example.org --api-key glsa_xxx \
  --datasource-type graphite --query-match 'telegraf\.'
```

**Everything on InfluxDB:**

```bash
python find_grafana_usage.py --datasource-type influxdb
```

**Graphite or InfluxDB, in one pass:**

```bash
python find_grafana_usage.py --datasource-type graphite influxdb
```

**All legacy Angular `graph` panels (a common upgrade target):**

```bash
python find_grafana_usage.py --panel-type graph
```

**Any query referencing a specific metric, as a CSV export:**

```bash
python find_grafana_usage.py --query-match 'node_cpu_seconds_total' --format csv > worklist.csv
```

**Scope a scan to one folder, alerts only:**

```bash
python find_grafana_usage.py --folder "Production" --skip-panels
```
