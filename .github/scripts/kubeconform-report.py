#!/usr/bin/env python3
"""
Turn kubeconform's JSON output into a readable CI log line.

Two things this adds over `kubeconform -summary`:

  * It names every failure inline, so a red job says which resource is wrong
    instead of just "invalid: 1".
  * It lists resources that were SKIPPED for want of a schema. Skipping is
    unavoidable here (SOPS-encrypted Secrets arrive with an encrypted `kind:`,
    and a few vendored CRDs are not in the community catalog) but it is also how
    a typo'd kind slips through unvalidated, so the skips stay visible.

Encrypted Secrets are reported as a count only — they are expected and there are
dozens of them.
"""
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
summary = report["summary"]

encrypted = 0
unschemaed = []
failures = []

for res in report["resources"]:
    kind = str(res.get("kind", ""))
    status = res["status"]
    if status == "statusSkipped":
        if kind.startswith("ENC["):
            encrypted += 1
        else:
            unschemaed.append(f"{kind} ({res.get('version', '?')}) {res.get('name', '')}")
    elif status in ("statusInvalid", "statusError"):
        failures.append(f"{kind} {res.get('name', '')}: {res.get('msg', '')}")

print(
    f"valid={summary['valid']} invalid={summary['invalid']} "
    f"errors={summary['errors']} skipped={summary['skipped']}"
)
if encrypted:
    print(f"  {encrypted} SOPS-encrypted Secret(s) skipped (expected — cannot decrypt in CI)")
for item in sorted(set(unschemaed)):
    print(f"  no schema, NOT validated: {item}")
for item in failures:
    print(f"  FAILED: {item}")

sys.exit(1 if failures else 0)
