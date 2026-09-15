#!/usr/bin/env python3
"""
find_grafana_usage.py

Scans a Grafana instance and reports dashboard panels and alert rules that
match a set of composable filters:

  * --datasource-type : one or more datasource plugin types (graphite,
                        influxdb, prometheus, ...). Omit, or pass "any", to
                        match any datasource.
  * --query-match     : a regular expression matched against each query
                        string (re.search, so it is an unanchored substring
                        match unless you anchor it). Omit to match any query.
  * --panel-type      : one or more panel/visualization types (timeseries,
                        graph, stat, ...). Panels only; alerts have no panel
                        type, so this filter never applies to them.
  * --folder          : one or more folder titles. Applies to both panels
                        and alert rules.

Filters combine with AND; any filter you omit is left unconstrained. With no
filters at all, every panel/alert query is reported (an inventory dump).

Originally written to find Graphite/Telegraf usage for a migration worklist;
that specific search is now just:

    find_grafana_usage.py --datasource-type graphite --query-match 'telegraf\\.'

Usage:
    python find_grafana_usage.py --host https://grafana.example.org --api-key glsa_xxx \\
        --datasource-type influxdb

Configuration can be supplied via CLI flags or environment variables:
    GRAFANA_HOST        (or --host)
    GRAFANA_API_KEY     (or --api-key)
    GRAFANA_QUERY_MATCH (or --query-match)
    GRAFANA_VERIFY_SSL  (or --no-verify-ssl to disable, default: verify)

Output formats: table (default), csv, json  (--format)
"""

import argparse
import csv
import json
import os
import re
import sys
from dataclasses import dataclass, asdict
from typing import Any, Iterable, Optional, Pattern

import requests


# Shown in the "matched query" column when a target matched on datasource type
# alone but exposes no query-text field we recognize. This happens for plugins
# that store a builder query purely structurally (e.g. classic InfluxQL builder,
# Graphite's builder). Note some plugins always emit query text even in builder
# mode -- InfluxDB 3, for instance, generates 'rawSql' from the builder config --
# so this placeholder is not a reliable "was built with the builder" signal.
NO_RAW_QUERY = "(no query text)"


@dataclass
class PanelMatch:
    dashboard_uid: str
    dashboard_title: str
    dashboard_folder: str
    dashboard_url: str
    panel_id: Any
    panel_title: str
    panel_type: str
    datasource_name: str
    datasource_type: str
    matched_targets: str  # semicolon-joined raw query strings


@dataclass
class AlertMatch:
    rule_uid: str
    rule_title: str
    rule_folder: str
    rule_group: str
    rule_url: str
    ref_id: str
    datasource_name: str
    datasource_type: str
    matched_targets: str  # semicolon-joined raw query strings


@dataclass
class Filters:
    """Composable match criteria. A field of None means 'unconstrained'."""
    datasource_types: Optional[set[str]]  # lowercased plugin types; None = any
    query_re: Optional[Pattern[str]]      # compiled regex; None = any query
    panel_types: Optional[set[str]]       # lowercased panel types; None = any
    folders: Optional[set[str]]           # lowercased folder titles; None = any

    def ds_type_ok(self, ds_type: Optional[str]) -> bool:
        if self.datasource_types is None:
            return True
        if not ds_type:
            # A filter was requested but we couldn't resolve the type, so we
            # can't confirm a match -- exclude it.
            return False
        return ds_type.lower() in self.datasource_types

    def query_ok(self, query: Optional[str]) -> bool:
        # No query filter -> accept regardless, even when there is no query
        # text to inspect. This matters for datasources whose visual query
        # builder stores the query structurally (e.g. classic InfluxQL builder)
        # rather than as text, so target_query_string() returns None.
        if self.query_re is None:
            return True
        if not query:
            return False
        return self.query_re.search(query) is not None

    def panel_type_ok(self, panel_type: Optional[str]) -> bool:
        if self.panel_types is None:
            return True
        return (panel_type or "").lower() in self.panel_types

    def folder_ok(self, folder: Optional[str]) -> bool:
        if self.folders is None:
            return True
        return (folder or "").lower() in self.folders

    def is_unconstrained(self) -> bool:
        return (
            self.datasource_types is None
            and self.query_re is None
            and self.panel_types is None
            and self.folders is None
        )


def get_env_or_default(name: str, default: Optional[str] = None) -> Optional[str]:
    return os.environ.get(name, default)


def build_session(api_key: str, verify_ssl: bool) -> requests.Session:
    session = requests.Session()
    session.headers.update(
        {
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
        }
    )
    session.verify = verify_ssl
    return session


def list_dashboards(session: requests.Session, host: str) -> list[dict]:
    """Return all dashboards (search API), paginating if necessary."""
    dashboards = []
    page = 1
    limit = 5000  # Grafana search API supports up to 5000 per request
    while True:
        resp = session.get(
            f"{host.rstrip('/')}/api/search",
            params={"type": "dash-db", "limit": limit, "page": page},
            timeout=30,
        )
        resp.raise_for_status()
        batch = resp.json()
        if not batch:
            break
        dashboards.extend(batch)
        if len(batch) < limit:
            break
        page += 1
    return dashboards


def get_dashboard_detail(session: requests.Session, host: str, uid: str) -> dict:
    resp = session.get(f"{host.rstrip('/')}/api/dashboards/uid/{uid}", timeout=30)
    resp.raise_for_status()
    return resp.json()


def resolve_datasource_map(session: requests.Session, host: str) -> dict[str, str]:
    """
    Map datasource UID -> type, and datasource name -> type, so we can
    resolve panel/target 'datasource' references regardless of whether
    Grafana stores them as {"uid": ...} objects or bare name strings
    (older dashboard schema versions).
    """
    resp = session.get(f"{host.rstrip('/')}/api/datasources", timeout=30)
    resp.raise_for_status()
    ds_list = resp.json()
    ds_map = {}
    for ds in ds_list:
        ds_type = ds.get("type", "")
        if ds.get("uid"):
            ds_map[ds["uid"]] = ds_type
        if ds.get("name"):
            ds_map[ds["name"]] = ds_type
    return ds_map


def datasource_type_of(datasource_field: Any, ds_map: dict[str, str]) -> Optional[str]:
    """
    Normalize a 'datasource' field, which can be:
      - None (inherit from panel/dashboard default)
      - a string (old schema: datasource name)
      - a dict like {"type": "graphite", "uid": "abc123"} (classic schema)
      - a dict like {"name": "000000003"} (schema v2 DataQuery.datasource --
        the key is "name" here but the value is actually a datasource UID)
    Returns the datasource type string if resolvable, else None.
    """
    if datasource_field is None:
        return None
    if isinstance(datasource_field, str):
        # Could be a name, or the special "-- Mixed --" / "default" markers
        return ds_map.get(datasource_field)
    if isinstance(datasource_field, dict):
        if datasource_field.get("type"):
            return datasource_field["type"]
        identifier = datasource_field.get("uid") or datasource_field.get("name")
        if identifier:
            return ds_map.get(identifier)
    return None


def datasource_name_of(datasource_field: Any) -> str:
    if datasource_field is None:
        return "(inherited/default)"
    if isinstance(datasource_field, str):
        return datasource_field
    if isinstance(datasource_field, dict):
        return (
            datasource_field.get("uid")
            or datasource_field.get("name")
            or datasource_field.get("type")
            or "(unknown)"
        )
    return "(unknown)"


def unwrap_spec(dashboard: dict) -> dict:
    """
    Newer Grafana dashboard API responses (v12.2+) can wrap the actual
    dashboard content one level deeper under a "spec" key -- both the
    classic panels array (when returned as a "V1 Resource") and the v2
    "elements" map (when returned as a "V2 Resource", which is how
    Dynamic Dashboards / tabs are stored) live under dashboard.spec
    rather than directly on the dashboard object.

    Returns the effective object to read "panels" / "elements" /
    "title" / "datasource" from, regardless of which of the three
    response shapes (Classic, V1 Resource, V2 Resource) was returned.
    """
    spec = dashboard.get("spec")
    if isinstance(spec, dict):
        return spec
    return dashboard


def get_panel_type(panel: dict) -> str:
    """Classic schema has panel['type'] directly. Schema v2 puts the viz
    plugin id under vizConfig.group instead."""
    if panel.get("type"):
        return panel["type"]
    return panel.get("vizConfig", {}).get("group", "unknown")


def iter_panels(panels: Iterable[dict]) -> Iterable[dict]:
    """Yield panels, flattening row panels which nest their children.

    Handles the classic/legacy dashboard schema, where a row is a panel
    with type == "row" and its own child panels nested under "panels".
    """
    for panel in panels:
        yield panel
        nested = panel.get("panels")
        if nested:
            yield from iter_panels(nested)


def iter_v2_elements(effective_dashboard: dict) -> Iterable[dict]:
    """
    Yield panel-like objects from Grafana's schema v2 ("Dynamic Dashboards")
    format, introduced in Grafana 12. This is how panels embedded in tabs
    are stored (tabs are a layout-only construct -- see below).

    In v2, panel definitions live in a flat "elements" map keyed by
    element ID, found at effective_dashboard["elements"] once "spec" has
    been unwrapped via unwrap_spec(). A separate "layout" section
    (GridLayoutKind, RowsLayoutKind, TabsLayoutKind, AutoGridLayoutKind)
    only describes how those elements are arranged -- into tabs, rows, or
    a grid -- it does not nest the panel definitions themselves. So
    scanning "elements" directly covers panels regardless of whether
    they're grouped into tabs or rows.
    """
    elements = effective_dashboard.get("elements")
    if not isinstance(elements, dict):
        return
    for element in elements.values():
        # Each element typically wraps the actual panel spec under "spec".
        yield element.get("spec", element)


def target_query_string(target: dict) -> Optional[str]:
    """
    Return the raw query string from a target/query object. Different
    datasource plugins use different field names: Graphite uses 'target'
    (or 'targetFull' when the query builder expands functions), Prometheus/
    Loki use 'expr', InfluxDB InfluxQL/Flux use 'query', SQL datasources
    (Postgres/MySQL/MSSQL and InfluxDB 3's SQL mode) use 'rawSql', and others
    use 'rawQuery' / 'queryText'. Check them in turn so the same helper works
    across plugins.

    Note: 'rawQuery' on the InfluxDB InfluxQL model is a boolean (raw-mode
    flag), not the query text -- the isinstance(str) guard below skips it in
    that case, and 'query' (checked first) holds the actual text there.
    """
    for key in ("target", "targetFull", "expr", "query", "rawSql", "rawQuery", "queryText"):
        val = target.get(key)
        if isinstance(val, str):
            return val
    return None


def extract_query_matches(
    panel: dict, ds_map: dict[str, str], filters: Filters
) -> list[tuple[str, str, str]]:
    """
    Return a list of (datasource_display_name, datasource_type, matched_query)
    for a panel-like object, handling both dashboard schema shapes:

    Classic schema: panel["targets"] is a flat list of target dicts, each
    with its own query string field and an optional per-target datasource
    override (falls back to the panel-level datasource).

    Schema v2 ("Dynamic Dashboards"): there is no "targets" array. Instead,
    panel["data"]["spec"]["queries"] is a list of PanelQuery objects; the
    actual query lives at query.spec.query, which carries its own "group"
    field (e.g. "graphite") -- this is the authoritative datasource-plugin
    identifier, more reliable than resolving datasource.name/uid through
    ds_map, since the "datasource" dict here doesn't use the classic
    type/uid key names. The raw query string sits one level deeper, at
    query.spec.query.spec.target (or equivalent field name).

    A target is reported when both the datasource-type filter and the
    query-regex filter accept it (see Filters). Query matching uses
    re.search, so an unanchored pattern behaves like a substring match --
    important because real Graphite queries are often wrapped in a render
    function, e.g. alias(telegraf.host.cpu.usage_idle, 'CPU %'), so the
    query string doesn't start with the metric name even though it contains
    it.
    """
    matches: list[tuple[str, str, str]] = []

    # --- Classic schema: flat "targets" array ---
    targets = panel.get("targets")
    if isinstance(targets, list):
        panel_ds_field = panel.get("datasource")
        for target in targets:
            target_ds_field = target.get("datasource", panel_ds_field)
            target_ds_type = datasource_type_of(target_ds_field, ds_map)
            if not filters.ds_type_ok(target_ds_type):
                continue
            query = target_query_string(target)
            if filters.query_ok(query):
                matches.append(
                    (
                        datasource_name_of(target_ds_field),
                        target_ds_type or "(unknown)",
                        query or NO_RAW_QUERY,
                    )
                )

    # --- Schema v2: nested data.spec.queries[].spec.query ---
    data = panel.get("data")
    if isinstance(data, dict):
        query_group_spec = data.get("spec", {}) or {}
        for panel_query in query_group_spec.get("queries", []) or []:
            pq_spec = panel_query.get("spec", {}) or {}
            query_obj = pq_spec.get("query", {}) or {}

            # "group" is the datasource-plugin id (e.g. "graphite"),
            # set directly on the DataQuery -- authoritative and doesn't
            # need ds_map resolution. Fall back to the datasource dict
            # (keyed by "name" in this schema) if group is absent.
            ds_field = query_obj.get("datasource")
            effective_type = query_obj.get("group") or datasource_type_of(
                ds_field, ds_map
            )
            if not filters.ds_type_ok(effective_type):
                continue

            inner_spec = query_obj.get("spec", {}) or {}
            query = target_query_string(inner_spec)
            if filters.query_ok(query):
                matches.append(
                    (
                        datasource_name_of(ds_field),
                        effective_type or "(unknown)",
                        query or NO_RAW_QUERY,
                    )
                )

    return matches


def list_alert_rules(session: requests.Session, host: str) -> list[dict]:
    """
    Fetch all Grafana-managed alert rules via the provisioning API.
    Returns the raw rule objects, each with a "data" list of query
    definitions (one per refId, e.g. the query step(s) plus any
    reduce/threshold expression steps).
    """
    resp = session.get(
        f"{host.rstrip('/')}/api/v1/provisioning/alert-rules", timeout=30
    )
    resp.raise_for_status()
    return resp.json()


def resolve_folder_titles(
    session: requests.Session, host: str, folder_uids: set[str]
) -> dict[str, str]:
    """Resolve a set of folder UIDs to their display titles, one call each."""
    titles: dict[str, str] = {}
    for uid in folder_uids:
        if not uid:
            titles[uid] = "General"
            continue
        try:
            resp = session.get(f"{host.rstrip('/')}/api/folders/{uid}", timeout=15)
            resp.raise_for_status()
            titles[uid] = resp.json().get("title", uid)
        except requests.HTTPError:
            titles[uid] = uid  # fall back to raw UID if lookup fails
    return titles


def find_alert_matches(
    session: requests.Session,
    host: str,
    ds_map: dict[str, str],
    filters: Filters,
    verbose: bool = False,
) -> list[AlertMatch]:
    matches: list[AlertMatch] = []

    try:
        rules = list_alert_rules(session, host)
    except requests.HTTPError as exc:
        print(f"  ! Failed to fetch alert rules: {exc}", file=sys.stderr)
        return matches

    folder_uids = {rule.get("folderUID", "") for rule in rules}
    folder_titles = resolve_folder_titles(session, host, folder_uids)

    for rule in rules:
        uid = rule.get("uid", "")
        title = rule.get("title", uid)
        folder_uid = rule.get("folderUID", "")
        folder_title = folder_titles.get(folder_uid, "General")

        # Folder filter applies to alerts too; skip whole rule if it doesn't match.
        if not filters.folder_ok(folder_title):
            continue

        rule_group = rule.get("ruleGroup", "")
        rule_url = f"{host.rstrip('/')}/alerting/grafana/{uid}/view"

        if verbose:
            print(f"Scanning alert rule: {title}", file=sys.stderr)

        for query_step in rule.get("data", []) or []:
            ds_uid = query_step.get("datasourceUid", "")
            if ds_uid in ("__expr__", "-100", ""):
                # Server-side expression / classic condition step, not a
                # real datasource query -- nothing to match here.
                continue

            model = query_step.get("model", {}) or {}
            # The model's own "datasource" field (if present) is the most
            # reliable source of truth; fall back to datasourceUid via ds_map.
            effective_type = datasource_type_of(model.get("datasource"), ds_map) or ds_map.get(ds_uid)

            if not filters.ds_type_ok(effective_type):
                continue

            query = target_query_string(model)
            if filters.query_ok(query):
                matches.append(
                    AlertMatch(
                        rule_uid=uid,
                        rule_title=title,
                        rule_folder=folder_title,
                        rule_group=rule_group,
                        rule_url=rule_url,
                        ref_id=query_step.get("refId", "?"),
                        datasource_name=datasource_name_of(model.get("datasource")) or ds_uid,
                        datasource_type=effective_type or "(unknown)",
                        matched_targets=query or NO_RAW_QUERY,
                    )
                )

    return matches


def find_panel_matches(
    session: requests.Session,
    host: str,
    ds_map: dict[str, str],
    filters: Filters,
    verbose: bool = False,
) -> list[PanelMatch]:
    matches: list[PanelMatch] = []
    dashboards = list_dashboards(session, host)

    for dash_summary in dashboards:
        uid = dash_summary.get("uid")
        if not uid:
            continue

        # Pre-filter on the folder from the search result to avoid fetching
        # dashboard detail we'd only discard. The search API reports the
        # folder title (absent for the root "General" folder).
        summary_folder = dash_summary.get("folderTitle", "General")
        if not filters.folder_ok(summary_folder):
            continue

        title_hint = dash_summary.get("title", uid)
        if verbose:
            print(f"Scanning dashboard: {title_hint}", file=sys.stderr)

        try:
            detail = get_dashboard_detail(session, host, uid)
        except requests.HTTPError as exc:
            print(f"  ! Failed to fetch dashboard {uid}: {exc}", file=sys.stderr)
            continue

        dashboard_raw = detail.get("dashboard", {})
        meta = detail.get("meta", {})

        # Unwrap "spec" if present -- covers Classic, V1 Resource
        # (classic content wrapped in spec), and V2 Resource (elements
        # wrapped in spec) response shapes uniformly.
        dashboard = unwrap_spec(dashboard_raw)

        dash_title = dashboard.get("title", title_hint)
        dash_folder = meta.get("folderTitle", "General")
        dash_url = f"{host.rstrip('/')}{meta.get('url', '')}"

        # Classic schema: panels array (with rows nesting their children).
        # Schema v2: flat "elements" map, covers tabs/rows/grid alike.
        all_panels = list(iter_panels(dashboard.get("panels", []))) + list(
            iter_v2_elements(dashboard)
        )

        for panel in all_panels:
            panel_type = get_panel_type(panel)
            # Panel-type filter applies only to panels (alerts have none).
            if not filters.panel_type_ok(panel_type):
                continue

            query_matches = extract_query_matches(panel, ds_map, filters)

            if query_matches:
                matched_targets = "; ".join(q for _, _, q in query_matches)
                # Use the first match's resolved datasource for display; a
                # mixed panel could technically have more than one, but this
                # covers the overwhelming majority of real dashboards.
                ds_display_name = query_matches[0][0]
                ds_display_type = query_matches[0][1]
                matches.append(
                    PanelMatch(
                        dashboard_uid=uid,
                        dashboard_title=dash_title,
                        dashboard_folder=dash_folder,
                        dashboard_url=dash_url,
                        panel_id=panel.get("id"),
                        panel_title=panel.get("title", "(untitled)"),
                        panel_type=panel_type,
                        datasource_name=ds_display_name,
                        datasource_type=ds_display_type,
                        matched_targets=matched_targets,
                    )
                )

    return matches


def output_table(matches: list[PanelMatch], alert_matches: list[AlertMatch]) -> None:
    if not matches and not alert_matches:
        print("No matching panels or alert rules found.")
        return

    headers = [
        "Done", "Kind", "Folder", "Dashboard/Rule", "Panel/RefID",
        "Type/Group", "Datasource", "DS Type", "Query(ies)",
    ]
    rows = [
        [
            "[ ]",
            "Panel",
            m.dashboard_folder,
            m.dashboard_title,
            m.panel_title,
            m.panel_type,
            m.datasource_name,
            m.datasource_type,
            m.matched_targets,
        ]
        for m in matches
    ] + [
        [
            "[ ]",
            "Alert",
            a.rule_folder,
            a.rule_title,
            a.ref_id,
            a.rule_group,
            a.datasource_name,
            a.datasource_type,
            a.matched_targets,
        ]
        for a in alert_matches
    ]

    def escape_cell(value: str) -> str:
        # Escape pipe characters and collapse newlines so cells don't
        # break the Markdown table structure.
        return str(value).replace("|", "\\|").replace("\n", " ")

    print("| " + " | ".join(headers) + " |")
    print("| " + " | ".join("---" for _ in headers) + " |")
    for row in rows:
        print("| " + " | ".join(escape_cell(v) for v in row) + " |")
    print(f"\n{len(matches)} matching panel(s), {len(alert_matches)} matching alert rule(s) found.")


def output_csv(matches: list[PanelMatch], alert_matches: list[AlertMatch]) -> None:
    writer = csv.writer(sys.stdout)
    writer.writerow(
        [
            "kind",
            "folder",
            "dashboard_or_rule_title",
            "panel_title_or_ref_id",
            "panel_type_or_rule_group",
            "url",
            "datasource_name",
            "datasource_type",
            "matched_targets",
        ]
    )
    for m in matches:
        writer.writerow(
            [
                "panel",
                m.dashboard_folder,
                m.dashboard_title,
                m.panel_title,
                m.panel_type,
                m.dashboard_url,
                m.datasource_name,
                m.datasource_type,
                m.matched_targets,
            ]
        )
    for a in alert_matches:
        writer.writerow(
            [
                "alert",
                a.rule_folder,
                a.rule_title,
                a.ref_id,
                a.rule_group,
                a.rule_url,
                a.datasource_name,
                a.datasource_type,
                a.matched_targets,
            ]
        )


def output_json(matches: list[PanelMatch], alert_matches: list[AlertMatch]) -> None:
    print(
        json.dumps(
            {
                "panels": [asdict(m) for m in matches],
                "alert_rules": [asdict(a) for a in alert_matches],
            },
            indent=2,
        )
    )


def build_filters(args: argparse.Namespace) -> Filters:
    """Translate parsed CLI args into a Filters object, compiling the query
    regex and normalizing type/folder lists (None == unconstrained)."""
    # Datasource types: "any"/"*" (or omitting the flag) means no constraint.
    if args.datasource_type:
        lowered = {t.lower() for t in args.datasource_type}
        datasource_types: Optional[set[str]] = (
            None if ("any" in lowered or "*" in lowered) else lowered
        )
    else:
        datasource_types = None

    query_re: Optional[Pattern[str]] = None
    if args.query_match:
        try:
            query_re = re.compile(args.query_match)
        except re.error as exc:
            raise SystemExit(f"Invalid --query-match regex: {exc}")

    panel_types = {t.lower() for t in args.panel_type} if args.panel_type else None
    folders = {f.lower() for f in args.folder} if args.folder else None

    return Filters(
        datasource_types=datasource_types,
        query_re=query_re,
        panel_types=panel_types,
        folders=folders,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Find Grafana panels and alert rules matching datasource/query/panel-type/folder filters."
    )
    parser.add_argument(
        "--host",
        default=get_env_or_default("GRAFANA_HOST"),
        help="Grafana base URL, e.g. https://grafana.example.org (env: GRAFANA_HOST)",
    )
    parser.add_argument(
        "--api-key",
        default=get_env_or_default("GRAFANA_API_KEY"),
        help="Grafana API key / service account token (env: GRAFANA_API_KEY)",
    )
    parser.add_argument(
        "--datasource-type",
        nargs="+",
        metavar="TYPE",
        help="Datasource plugin type(s) to match, e.g. graphite influxdb prometheus. "
             "Pass 'any' (or omit) to match any datasource.",
    )
    parser.add_argument(
        "--query-match",
        default=get_env_or_default("GRAFANA_QUERY_MATCH"),
        metavar="REGEX",
        help="Regular expression matched against each query string (re.search, so "
             "unanchored = substring). Omit to match any query. (env: GRAFANA_QUERY_MATCH)",
    )
    parser.add_argument(
        "--panel-type",
        nargs="+",
        metavar="TYPE",
        help="Panel/visualization type(s) to match, e.g. timeseries graph stat. "
             "Panels only (alerts have no panel type). Omit to match any.",
    )
    parser.add_argument(
        "--folder",
        nargs="+",
        metavar="TITLE",
        help="Folder title(s) to match (applies to panels and alerts). Omit to match any.",
    )
    parser.add_argument(
        "--format",
        choices=["table", "csv", "json"],
        default="table",
        help="Output format (default: table)",
    )
    parser.add_argument(
        "--no-verify-ssl",
        action="store_true",
        default=(get_env_or_default("GRAFANA_VERIFY_SSL", "true").lower() == "false"),
        help="Disable TLS certificate verification (env: GRAFANA_VERIFY_SSL=false)",
    )
    parser.add_argument(
        "--skip-panels",
        action="store_true",
        help="Skip scanning dashboard panels (alert rules only)",
    )
    parser.add_argument(
        "--skip-alerts",
        action="store_true",
        help="Skip scanning alert rules (dashboard panels only)",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Print progress information to stderr while scanning",
    )

    args = parser.parse_args()

    if not args.host:
        parser.error("Grafana host is required (--host or GRAFANA_HOST)")
    if not args.api_key:
        parser.error("Grafana API key is required (--api-key or GRAFANA_API_KEY)")

    filters = build_filters(args)
    if filters.is_unconstrained():
        print(
            "Note: no filters set — reporting every panel/alert query. "
            "Narrow with --datasource-type / --query-match / --panel-type / --folder.",
            file=sys.stderr,
        )

    verify_ssl = not args.no_verify_ssl
    session = build_session(args.api_key, verify_ssl)

    try:
        ds_map = resolve_datasource_map(session, args.host)
    except requests.HTTPError as exc:
        print(f"Failed to fetch data sources: {exc}", file=sys.stderr)
        return 1
    except requests.exceptions.ConnectionError as exc:
        print(f"Could not connect to Grafana at {args.host}: {exc}", file=sys.stderr)
        return 1

    matches = (
        find_panel_matches(session, args.host, ds_map, filters, verbose=args.verbose)
        if not args.skip_panels
        else []
    )
    alert_matches = (
        find_alert_matches(session, args.host, ds_map, filters, verbose=args.verbose)
        if not args.skip_alerts
        else []
    )

    if args.format == "table":
        output_table(matches, alert_matches)
    elif args.format == "csv":
        output_csv(matches, alert_matches)
    elif args.format == "json":
        output_json(matches, alert_matches)

    return 0


if __name__ == "__main__":
    sys.exit(main())
