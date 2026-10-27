#!/usr/bin/env python3
"""
Check that the Flux notification Alerts list every namespace that holds a HelmRelease.

notification-controller has no namespace wildcard: an Alert `eventSources` entry with
no `namespace:` means "the Alert's own namespace" (flux-system), and the match is an
exact string compare. So `{kind: HelmRelease, name: "*"}` alone matches nothing here —
every HelmRelease lives in an app namespace — and that is exactly how Helm upgrade
failures went unreported to Discord for months. The fix is one entry per namespace,
and this script is what keeps that list from rotting when an app is added.

Checked Alerts (the list must match EXACTLY — a missing namespace is a silent gap,
a stale one is a sign the list is not being maintained):
  * flux-discord-alert.yaml  — every namespace with a HelmRelease anywhere.
  * github-dispatch-alert.yaml (if present) — only namespaces whose HelmReleases live
    under kubernetes/apps/. That Alert drives automatic reverts, which only ever
    apply to app updates; infrastructure is never automerged.

Only git-tracked files are read. Exit code 1 on any mismatch.
"""
import os
import subprocess
import sys

import yaml

ROOT = sys.argv[1] if len(sys.argv) > 1 else "kubernetes"
CONFIGS = os.path.join(ROOT, "infrastructure", "configs")
APPS = os.path.join(ROOT, "apps") + os.sep

ALERTS = [
    # (file, include-this-HelmRelease-path?)
    (os.path.join(CONFIGS, "flux-discord-alert.yaml"), lambda path: True),
    (os.path.join(CONFIGS, "github-dispatch-alert.yaml"), lambda path: path.startswith(APPS)),
]

tracked = subprocess.run(
    ["git", "ls-files", ROOT], capture_output=True, text=True, check=True
).stdout.split()

# namespace -> first file it was seen in (for the error message)
releases = []  # (namespace, path)
for path in tracked:
    # SOPS files have `kind:` encrypted, and the vendored Flux install is not ours.
    if not path.endswith((".yaml", ".yml")) or ".sops." in path:
        continue
    if os.path.basename(path) == "gotk-components.yaml":
        continue
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if "kind: HelmRelease" not in text:
        continue
    for doc in yaml.safe_load_all(text):
        if isinstance(doc, dict) and doc.get("kind") == "HelmRelease":
            ns = (doc.get("metadata") or {}).get("namespace")
            if not ns:
                print(f"{path}: HelmRelease without metadata.namespace — cannot check coverage")
                sys.exit(1)
            releases.append((ns, path))

rc = 0
for alert_path, wanted in ALERTS:
    if not os.path.exists(alert_path):
        continue
    with open(alert_path, encoding="utf-8") as fh:
        alert = yaml.safe_load(fh)

    expected = {}
    for ns, path in releases:
        if wanted(path):
            expected.setdefault(ns, path)

    listed = set()
    for src in alert["spec"].get("eventSources", []):
        if src.get("kind") != "HelmRelease":
            continue
        ns = src.get("namespace")
        if not ns:
            print(f"{alert_path}: HelmRelease eventSource without `namespace:` only matches "
                  "flux-system (there is no namespace wildcard) — list namespaces explicitly")
            rc = 1
            continue
        listed.add(ns)

    missing = sorted(set(expected) - listed)
    stale = sorted(listed - set(expected))
    for ns in missing:
        print(f"{alert_path}: missing HelmRelease namespace `{ns}` (e.g. {expected[ns]})")
    for ns in stale:
        print(f"{alert_path}: lists namespace `{ns}`, which has no HelmRelease in scope")
    if missing or stale:
        rc = 1
    else:
        print(f"{alert_path}: OK ({len(listed)} namespaces)")

sys.exit(rc)
