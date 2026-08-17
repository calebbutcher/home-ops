#!/usr/bin/env python3
"""
Every Grafana dashboard in this repo must let you pick its datasource.

A dashboard that hardcodes `"datasource": {"uid": "prometheus"}` is silently
pinned to the local Prometheus and its ~2d retention. The long-term history is
already in Thanos — every one of these dashboards is fed by a Prometheus scrape,
so the sidecar has been uploading it to RustFS the whole time — but a hardcoded
uid gives you no way to ask for it. You notice at the worst possible moment: the
incident is three days old and the graph is empty.

That kept happening one dashboard at a time, which is why this is a check and not
a one-off cleanup. The rules:

  1. Every `datasource` reference resolves to a template variable (`$name` or
     `${name}`), not a literal uid.
  2. Every variable so referenced is declared in `templating.list` with
     `"type": "datasource"`, so Grafana renders a picker for it.

Exempt, because neither is a real datasource choice:
  * `datasource: null` — row panels and anything meaning "inherit the default".
  * The built-in Grafana datasource used by annotations, in all three spellings
    Grafana has shipped: the bare string "-- Grafana --",
    {"type": "datasource", "uid": "grafana"}, and
    {"type": "grafana", "uid": "-- Grafana --"}.

Scope is dashboards committed to this repo. Dashboards that arrive inside a Helm
chart (kube-prometheus-stack ships a pile of them) are not ours to edit and are
not checked.

Run `python3 .github/scripts/check-dashboard-datasources.py` from the repo root.
Exit code 1 if any dashboard fails.
"""
import json
import os
import re
import sys

import yaml

ROOT = sys.argv[1] if len(sys.argv) > 1 else "kubernetes"

# $foo or ${foo} — the whole uid must be the reference. A uid like
# "prom-${cluster}" is not a datasource picker, it is string interpolation into a
# fixed datasource, so it does not satisfy rule 1.
VAR_REF = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")

BUILTIN_GRAFANA = (
    "-- Grafana --",
    ("datasource", "grafana"),
    ("grafana", "-- Grafana --"),
)


def iter_datasource_refs(node, path="$"):
    """Yield (json path, datasource value) for every `datasource` key in the tree."""
    if isinstance(node, dict):
        if "datasource" in node:
            yield path, node["datasource"]
        for key, value in node.items():
            yield from iter_datasource_refs(value, f"{path}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from iter_datasource_refs(value, f"{path}[{index}]")


def is_exempt(ds):
    if ds is None:
        return True
    if isinstance(ds, str):
        return ds in BUILTIN_GRAFANA
    if isinstance(ds, dict):
        return (ds.get("type"), ds.get("uid")) in BUILTIN_GRAFANA
    return False


def check(dashboard):
    """Return a list of human-readable problems with one parsed dashboard."""
    declared = {
        v.get("name")
        for v in dashboard.get("templating", {}).get("list", [])
        if v.get("type") == "datasource"
    }
    problems = []
    # Collapse by (uid, reason): a 167-panel dashboard with one mistake repeated
    # everywhere should print one line, not 167.
    seen = {}
    for path, ds in iter_datasource_refs(dashboard):
        if is_exempt(ds):
            continue
        uid = ds.get("uid") if isinstance(ds, dict) else ds
        if not isinstance(uid, str):
            seen.setdefault((repr(uid), "not a string"), path)
            continue
        match = VAR_REF.match(uid)
        if not match:
            seen.setdefault(
                (uid, "hardcoded uid — use a $datasource template variable"), path
            )
        elif match.group(1) not in declared:
            seen.setdefault(
                (
                    uid,
                    f"references ${match.group(1)}, which is not declared in "
                    f"templating.list as type: datasource "
                    f"(declared: {sorted(declared) or 'none'})",
                ),
                path,
            )
    for (uid, reason), path in seen.items():
        problems.append(f"{uid}: {reason}  (first seen at {path})")
    return problems


failures = []
checked = 0
for dirpath, _dirnames, filenames in os.walk(ROOT):
    for filename in sorted(filenames):
        if not filename.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(dirpath, filename)
        with open(path, encoding="utf-8") as handle:
            try:
                docs = list(yaml.safe_load_all(handle))
            except yaml.YAMLError:
                # yamllint owns unparseable YAML; do not double-report it here.
                continue
        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
                continue
            labels = (doc.get("metadata") or {}).get("labels") or {}
            if labels.get("grafana_dashboard") != "1":
                continue
            for key, raw in (doc.get("data") or {}).items():
                try:
                    dashboard = json.loads(raw)
                except (json.JSONDecodeError, TypeError):
                    failures.append(f"{path} [{key}]\n    not valid JSON")
                    continue
                checked += 1
                problems = check(dashboard)
                if problems:
                    title = dashboard.get("title", key)
                    failures.append(
                        f"{path} [{title}]\n"
                        + "\n".join(f"    {p}" for p in problems)
                    )

if failures:
    print("Dashboards with a datasource that cannot be switched:\n")
    print("\n\n".join(failures))
    print(
        f"\n{len(failures)} of {checked} dashboards failed. Add a template variable "
        '\n  {"name": "datasource", "label": "Datasource", "type": "datasource",'
        '\n   "query": "prometheus", ...}'
        "\nto templating.list and point every panel and target at ${datasource}."
    )
    sys.exit(1)

print(f"OK: {checked} dashboards, every datasource is switchable")
