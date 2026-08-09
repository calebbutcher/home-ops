#!/usr/bin/env python3
"""
Find YAML files that live next to a kustomization.yaml but are not referenced by it.

This exists because of a failure mode this repo hits repeatedly and which nothing
else catches: you add a manifest (a PrometheusRule, an Ingress, a Secret) to a
directory, forget to list it under `resources:` in that directory's
kustomization.yaml, and the file is simply never applied. Flux stays green,
`kustomize build` succeeds, kubeconform passes — the manifest is just silently
absent from the cluster, and you find out when the alert you "added" never fires.

Only git-tracked files are considered, so untracked scratch files and gitignored
plaintext (e.g. kubernetes/infrastructure/configs/cloudflare-token.yaml) do not
produce noise for someone running this locally.

Exit code 1 if any orphan is found.
"""
import os
import re
import subprocess
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "kubernetes"

tracked = set(
    subprocess.run(
        ["git", "ls-files", ROOT], capture_output=True, text=True, check=True
    ).stdout.split()
)

orphans = []
for dirpath, _dirnames, filenames in os.walk(ROOT):
    kfile = next(
        (f for f in ("kustomization.yaml", "kustomization.yml") if f in filenames), None
    )
    if not kfile:
        continue

    text = open(os.path.join(dirpath, kfile), encoding="utf-8").read()
    # Strip comments first: a resource that has been commented out is NOT applied,
    # so a mention inside a comment must not count as a reference.
    body = "\n".join(re.sub(r"#.*$", "", line) for line in text.splitlines())

    for fn in sorted(filenames):
        if not fn.endswith((".yaml", ".yml")) or fn in (
            "kustomization.yaml",
            "kustomization.yml",
        ):
            continue
        path = os.path.join(dirpath, fn)
        if path not in tracked:
            continue
        if fn not in body:
            orphans.append(path)

if orphans:
    print("Manifests not referenced by their sibling kustomization.yaml:")
    for o in orphans:
        print(f"  {o}")
    print()
    print("Add each file to the `resources:` list in that directory's")
    print("kustomization.yaml, or delete it. As-is it will never be applied.")
    sys.exit(1)

print(f"OK — every tracked manifest under {ROOT}/ is referenced by a kustomization.")
