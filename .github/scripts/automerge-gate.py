#!/usr/bin/env python3
"""
The `automerge gate` — a required status check that decides whether a Renovate PR
which Renovate has marked for automerge may actually merge without a human.

Renovate's packageRules (renovate.json) decide what is *eligible*. This gate is the
second opinion, and it is the only thing that sees the release notes:

  pass   not a Renovate PR (human PRs, rollout-revert PRs) — the check must be green
         on every PR because it is required by the `main` ruleset
  pass   a Renovate PR that is not marked for automerge — you merge it by hand anyway
  pass   `gate-approved` label — a human said yes
  FAIL   AUTOMERGE_ENABLED=false (repo variable) — the instant kill switch
  FAIL   a changed file is not an allowed app HelmRelease (see PATH_* below)
  FAIL   a DB-backed app gets anything but a patch
  FAIL   a major, or a minor of a 0.x version
  FAIL   `quarantined` label, or a dep+version listed in .github/renovate/quarantine.json
         on main (a version rollout-revert already had to revert once)
  FAIL   the release notes contain breaking-change wording (KEYWORDS)

A FAIL blocks GitHub auto-merge, adds `needs-planning`, and leaves one sticky comment
with the reasons. The PR then falls back to the manual flow: read it, plan it, and
either merge it by hand or add `gate-approved`.

Usage:
  automerge-gate.py --pr N             # CI: evaluate, label, comment, exit 1 on FAIL
  automerge-gate.py --pr N --dry-run   # locally: evaluate and print, touch nothing
                                       # (GITHUB_TOKEN=$(gh auth token) ...)
  automerge-gate.py --pr N --dry-run --as-automerge
                                       # ...as if Renovate had marked it for automerge
See docs/updates.md.
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from renovate_pr import automerge_enabled, parse_deps, strip_boilerplate  # noqa: E402

RENOVATE = "renovate[bot]"
MARKER = "<!-- automerge-gate -->"
QUARANTINE = ".github/renovate/quarantine.json"

# Only HelmRelease files under kubernetes/apps can automerge: a HelmRelease gets a
# Helm rollback on failure and is what rollout-revert knows how to revert. Raw
# manifests (e.g. the redis.yaml Deployments) get neither.
PATH_ALLOWED = re.compile(r"^kubernetes/apps/.+/helmrelease[^/]*\.yaml$")
# Kept in step with the "never automerge" rule in renovate.json — this is the
# backstop for a rule mistake there, not the primary control.
PATH_NEVER = [
    "kubernetes/apps/authentik/",      # SSO for everything
    "kubernetes/apps/technitium/",     # DNS; version parity with the VM primary
    "kubernetes/apps/bambustudio/",    # fails silently (see renovate.json)
    "kubernetes/apps/monitoring/kube-prometheus-stack/",  # the detection layer
    "kubernetes/apps/monitoring/loki/",
    "kubernetes/apps/monitoring/thanos/",
    "kubernetes/apps/monitoring/alloy/",
    "kubernetes/apps/monitoring/blackbox/",
]
# Apps with a database: patches only (schema migrations; no in-place downgrade).
PATH_PATCH_ONLY = [
    "kubernetes/apps/immich/",
    "kubernetes/apps/paperless/",
    "kubernetes/apps/gitea/",
    "kubernetes/apps/n8n/",
    "kubernetes/apps/tandoor/",
    "kubernetes/apps/uptime-kuma/",
    "kubernetes/apps/media/tracearr/",
]

# Case-insensitive. Deliberately broad: a false positive costs one manual merge, a
# false negative can cost an outage. Matched against the PR body MINUS Renovate's
# footer, i.e. the update table and the release notes.
KEYWORDS = [
    r"\bbreaking[\s_-]*changes?\b",
    r"\bBREAKING\b",
    r"\bbackwards?[\s-]*incompatib",
    r"\bnot\s+backwards?[\s-]*compatible\b",
    r"\bmigration\s+(guide|required|needed|steps?|notes?)\b",
    r"\bmanual(ly)?\s+migrat",
    r"\bmigrate\s+(your|the|existing)\b",
    r"\baction\s+required\b",
    r"\brequires?\s+(manual|user)\s+(action|intervention|steps?)\b",
    r"\bupgrade\s+(notes?|guide|instructions)\b",
    r"\b(removed|dropped|renamed)\s+(the\s+)?(support|config(uration)?|options?|settings?|flags?|"
    r"env(ironment)?\s+var(iable)?s?|parameters?|keys?|values?)\b",
    r"\bno\s+longer\s+(supported|available|works)\b",
    r"\bdeprecated\s+(config(uration)?|options?|settings?|flags?|env|parameters?|values?)\b",
    r"\b(database|schema)\s+(migration|change)s?\b",
]
KEYWORD_RE = re.compile("|".join(f"(?:{k})" for k in KEYWORDS), re.I)


class GitHub:
    def __init__(self, repo, token, dry_run):
        self.repo, self.token, self.dry_run = repo, token, dry_run

    def call(self, method, path, body=None, ok404=False):
        url = path if path.startswith("https://") else f"https://api.github.com/repos/{self.repo}/{path}"
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req) as r:
                data = r.read()
                return json.loads(data) if data else None
        except urllib.error.HTTPError as e:
            if ok404 and e.code == 404:
                return None
            raise

    def write(self, method, path, body=None):
        if self.dry_run:
            print(f"  [dry-run] would {method} {path}")
            return None
        return self.call(method, path, body)

    def paged(self, path):
        out, page = [], 1
        while True:
            sep = "&" if "?" in path else "?"
            batch = self.call("GET", f"{path}{sep}per_page=100&page={page}")
            out += batch
            if len(batch) < 100:
                return out
            page += 1


def regex_or_exact(pattern, value):
    """Renovate string matching: `/re/` is a regex, anything else is exact."""
    if len(pattern) > 1 and pattern.startswith("/") and pattern.rstrip("i").endswith("/"):
        flags = re.I if pattern.endswith("i") else 0
        return re.search(pattern[1:pattern.rstrip("i").rindex("/")], value, flags) is not None
    return pattern == value


def quarantined(gh, deps):
    data = gh.call("GET", f"contents/{QUARANTINE}?ref=main", ok404=True)
    if not data:
        return []
    rules = json.loads(base64.b64decode(data["content"])).get("packageRules", [])
    hits = []
    for d in deps:
        for rule in rules:
            names = rule.get("matchDepNames", []) + rule.get("matchPackageNames", [])
            if not any(regex_or_exact(n, d["dep"]) for n in names):
                continue
            # rollout-revert writes digest quarantines as matchUpdateTypes: ["digest"]
            # (a digest update has no new version to pin).
            if "matchUpdateTypes" in rule and d["update"] not in rule["matchUpdateTypes"]:
                continue
            nv = rule.get("matchNewValue")
            if nv is None or regex_or_exact(nv, d["to"]):
                hits.append(f"`{d['dep']}` `{d['to']}` is quarantined: "
                            + " ".join(rule.get("description", [])))
    return hits


def evaluate(gh, pr, files, as_automerge=False):
    labels = {lab["name"] for lab in pr["labels"]} | ({"automerge"} if as_automerge else set())
    body = pr.get("body") or ""

    # Returns (verdict, reasons, matched lines, eligible). `eligible` = a Renovate PR
    # marked for automerge — the only kind that gets labels and a sticky comment.
    if pr["user"]["login"] != RENOVATE:
        return "pass", ["not a Renovate PR"], [], False
    if "automerge" not in labels and not automerge_enabled(body):
        return "pass", ["Renovate PR not marked for automerge — merged by hand"], [], False
    if "gate-approved" in labels:
        return "pass", ["`gate-approved` label — approved by a human"], [], True

    reasons, matches = [], []
    if os.environ.get("AUTOMERGE_ENABLED", "true").lower() == "false":
        reasons.append("automerge is paused (repo variable `AUTOMERGE_ENABLED=false`)")

    deps = parse_deps(body)
    if not deps:
        reasons.append("could not read Renovate's update table from the PR body")

    for f in files:
        p = f["filename"]
        if not PATH_ALLOWED.match(p):
            reasons.append(f"`{p}` is not an app HelmRelease (no Helm rollback, no auto-revert)")
        elif any(p.startswith(n) for n in PATH_NEVER):
            reasons.append(f"`{p}` is in a never-automerge app")
        elif any(p.startswith(n) for n in PATH_PATCH_ONLY):
            for d in deps:
                if d["update"] != "patch":
                    reasons.append(f"`{p}` is a DB-backed app; `{d['dep']}` is a {d['update']} update (patch only)")

    for d in deps:
        if d["update"] == "major":
            reasons.append(f"`{d['dep']}` is a major update ({d['from']} → {d['to']})")
        elif d["update"] == "minor" and re.match(r"v?0\.", d["from"]):
            reasons.append(f"`{d['dep']}` is a 0.x minor update ({d['from']} → {d['to']}), i.e. breaking by semver")

    if "quarantined" in labels:
        reasons.append("`quarantined` label")
    reasons += quarantined(gh, deps)

    for line in strip_boilerplate(body).splitlines():
        if KEYWORD_RE.search(line):
            matches.append(line.strip()[:200])
    if matches:
        reasons.append(f"release notes mention breaking-change wording ({len(matches)} line(s))")

    return ("fail" if reasons else "pass"), list(dict.fromkeys(reasons)), matches, True


def comment(verdict, reasons, matches):
    if verdict == "pass":
        why = "; ".join(reasons) or "allowed app HelmRelease, allowed update type, no breaking-change wording"
        return f"{MARKER}\n✅ **Automerge gate passed** ({why})."
    out = [MARKER, "🛑 **Automerge gate: needs planning.** This update will not merge on its own.", ""]
    out += [f"- {r}" for r in reasons]
    if matches:
        out += ["", "<details><summary>Matched release-note lines</summary>", ""]
        out += [f"- `{m.replace('`', '')}`" for m in matches[:10]]
        out += ["", "</details>"]
    out += ["", "**To proceed:** read the release notes, then merge by hand, or add the "
            "`gate-approved` label to let auto-merge finish. See `docs/updates.md`."]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pr", type=int, required=True)
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "calebbutcher/home-ops"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--as-automerge", action="store_true",
                    help="with --dry-run: evaluate as if Renovate had marked the PR for automerge")
    args = ap.parse_args()
    if args.as_automerge and not args.dry_run:
        ap.error("--as-automerge is a testing aid and needs --dry-run")

    gh = GitHub(args.repo, os.environ.get("GITHUB_TOKEN"), args.dry_run)
    pr = gh.call("GET", f"pulls/{args.pr}")
    files = gh.paged(f"pulls/{args.pr}/files")
    verdict, reasons, matches, eligible = evaluate(gh, pr, files, args.as_automerge)

    print(f"PR #{args.pr}: {verdict.upper()}")
    for r in reasons:
        print(f"  - {r}")
    for m in matches[:10]:
        print(f"    > {m}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and not args.dry_run:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(comment(verdict, reasons, matches).replace(MARKER, "") + "\n")

    # Only automerge-marked Renovate PRs get labels/comments; everything else is a
    # silent green check.
    if eligible:
        labels = {lab["name"] for lab in pr["labels"]}
        sticky = next((c for c in gh.paged(f"issues/{args.pr}/comments")
                       if MARKER in (c.get("body") or "")), None)
        if verdict == "fail":
            gh.write("POST", f"issues/{args.pr}/labels", {"labels": ["needs-planning"]})
        elif "needs-planning" in labels:
            gh.write("DELETE", f"issues/{args.pr}/labels/needs-planning")
        text = comment(verdict, reasons, matches)
        if sticky:
            if sticky["body"] != text:
                gh.write("PATCH", f"issues/comments/{sticky['id']}", {"body": text})
        elif verdict == "fail":
            gh.write("POST", f"issues/{args.pr}/comments", {"body": text})

    return 1 if verdict == "fail" else 0


if __name__ == "__main__":
    sys.exit(main())
