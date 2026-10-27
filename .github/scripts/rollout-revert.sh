#!/usr/bin/env bash
# Revert the automerged Renovate PR behind a failed app rollout, and quarantine the
# version so it can't automerge again. Called by .github/workflows/rollout-revert.yml.
#
# Input (env): HR_NAME HR_NS EV_REASON EV_MESSAGE  — from the Flux event
#              MODE (dry-run|live|off)  DRILL (true|false)
#              GH_TOKEN (GITHUB_TOKEN)  PUSH_TOKEN (PAT)  RUN_URL
#
# Steps, any of which can end in "no action" (exit 0, reason in the job summary):
#   1. Validate the event: a DNS-1123 name/namespace and a rollout-failure message.
#   2. Find the HelmRelease's directory under kubernetes/apps.
#   3. Take the NEWEST first-parent commit on main touching that directory in the
#      last 24h. If a human changed the app after the automerge, that commit is
#      theirs and nothing happens.
#   4. That commit must be the merge of a Renovate PR that was automerged
#      (`automerge` label, merged by renovate[bot]). Manual merges are never
#      reverted. In a drill, `rollout-drill`+`automerge` also counts.
#   5. De-duplicate: one revert per PR, however many events arrive.
#   6. git revert (whole PR, including grouped updates), append quarantine rules,
#      push branch revert/pr-N, open the PR with the PAT.
#   7. MODE=live: enable auto-merge, EXCEPT a soak failure in a DB-backed app.
#      After a soak failure the new version ran, and may have migrated the
#      database, so downgrading needs a human. After a Helm-wait failure Helm has
#      already rolled the cluster back, so the revert only brings git in line, and
#      it always auto-merges.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-calebbutcher/home-ops}"
MODE="${MODE:-dry-run}"
DRILL="${DRILL:-false}"
WINDOW="${WINDOW:-24 hours ago}"  # overridable for testing
# Directories whose soak-failure reverts need a human (DB-backed apps).
MANUAL_AFTER_SOAK=(
  kubernetes/apps/immich
  kubernetes/apps/paperless
  kubernetes/apps/gitea
  kubernetes/apps/n8n
  kubernetes/apps/tandoor
  kubernetes/apps/uptime-kuma
  kubernetes/apps/media/tracearr
)

say() {
  echo "$*"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}
stop() { say ""; say "**No action:** $*"; exit 0; }

# --- 1. validate -------------------------------------------------------------
[[ "$MODE" == off ]] && stop "ROLLOUT_REVERT_MODE=off."
dns='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
[[ "${HR_NAME:-}" =~ $dns && "${HR_NS:-}" =~ $dns ]] || stop "invalid HelmRelease reference."
case "${EV_MESSAGE:-}" in
  "Helm upgrade failed for release "*) KIND=helm ;;
  "Soak check failed for release "*) KIND=soak ;;
  *) stop "not a rollout-failure event." ;;
esac

say "### Rollout failure: \`$HR_NS/$HR_NAME\` (${EV_REASON:-?}, mode \`$MODE\`)"
say '```'
say "$EV_MESSAGE"
say '```'

# --- 2. find the HelmRelease -------------------------------------------------
python3 -c 'import yaml' 2>/dev/null || pip install --quiet pyyaml
FILE=$(git grep -l -E '^kind: HelmRelease' -- kubernetes/apps | grep -v '\.sops\.' | python3 -c '
import os, sys, yaml
for path in sys.stdin.read().split():
    for doc in yaml.safe_load_all(open(path)):
        m = (doc or {}).get("metadata") or {}
        if (doc or {}).get("kind") == "HelmRelease" and m.get("name") == os.environ["HR_NAME"] \
                and m.get("namespace") == os.environ["HR_NS"]:
            print(path)
            sys.exit(0)
')
[[ -n "$FILE" ]] || stop "no HelmRelease \`$HR_NS/$HR_NAME\` under kubernetes/apps (infrastructure never automerges)."
DIR=$(dirname "$FILE")

# --- 3. newest change to that app --------------------------------------------
SHA=$(git log -1 --first-parent --since="$WINDOW" --format=%H HEAD -- "$DIR")
[[ -n "$SHA" ]] || stop "nothing changed in \`$DIR\` in the last 24h, so the failure is not from a recent update."

# --- 4. was it an automerged Renovate PR? ------------------------------------
PR=$(gh api "repos/$REPO/commits/$SHA/pulls" \
  --jq "[.[] | select(.merged_at != null and .merge_commit_sha == \"$SHA\")][0].number // empty")
[[ -n "$PR" ]] || stop "newest change to \`$DIR\` ($SHA) did not come from a merged PR."
PR_JSON=$(gh api "repos/$REPO/pulls/$PR")
TITLE=$(jq -r .title <<<"$PR_JSON")
AUTHOR=$(jq -r .user.login <<<"$PR_JSON")
MERGED_BY=$(jq -r '.merged_by.login // ""' <<<"$PR_JSON")
has_label() { jq -e --arg l "$1" '[.labels[].name] | index($l)' <<<"$PR_JSON" >/dev/null; }

say ""
say "Newest change to \`$DIR\`: #$PR \"$TITLE\" (author $AUTHOR, merged by $MERGED_BY)."
if [[ "$DRILL" == true ]] && has_label rollout-drill && has_label automerge; then
  say "Drill PR, so it's eligible."
elif [[ "$AUTHOR" == "renovate[bot]" ]] && has_label automerge && [[ "$MERGED_BY" == "renovate[bot]" ]]; then
  :
else
  stop "#$PR was not automerged by Renovate. Manual merges are never reverted; a human has to look at this one."
fi

# --- 5. de-duplicate ----------------------------------------------------------
BRANCH="revert/pr-$PR"
if has_label revert \
  || [[ -n "$(gh pr list --repo "$REPO" --state all --head "$BRANCH" --json number --jq '.[0].number // empty')" ]] \
  || git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 \
  || git log -1 --format=%H --grep "This reverts commit $SHA" HEAD | grep -q .; then
  stop "#$PR has already been reverted, or a revert is open (branch \`$BRANCH\` exists)."
fi

[[ -n "${PUSH_TOKEN:-}" ]] || { say "**Error:** secret ROLLOUT_REVERT_TOKEN is not set; can't open a revert PR that runs the required checks."; exit 1; }

# --- 6. revert + quarantine ----------------------------------------------------
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch -c "$BRANCH"
MFLAG=()
if (( $(git rev-list --parents -n1 "$SHA" | wc -w) > 2 )); then MFLAG=(-m 1); fi
if ! git revert --no-edit "${MFLAG[@]}" "$SHA"; then
  git revert --abort || true
  gh pr comment "$PR" --repo "$REPO" --body "⚠️ The rollout of this update failed (\`$HR_NS/$HR_NAME\`), but rollout-revert could not revert it cleanly: later changes conflict with it. Revert it by hand. [Run]($RUN_URL)"
  say "**Error:** \`git revert\` conflicted; commented on #$PR."
  exit 1
fi

# Quarantine every dep+version in the PR table. One rule per row, appended in place.
QUARANTINED=$(PR_BODY=$(jq -r '.body // ""' <<<"$PR_JSON") PR="$PR" python3 - <<'PY'
import json, os, re, sys
from datetime import date
sys.path.insert(0, ".github/scripts")
from renovate_pr import parse_deps

path = ".github/renovate/quarantine.json"
cfg = json.load(open(path))
pr, run = os.environ["PR"], os.environ["RUN_URL"]
why = f'{os.environ.get("EV_REASON", "")}: {os.environ["EV_MESSAGE"]}'[:300]
lines = []
for d in parse_deps(os.environ["PR_BODY"]):
    rule = {
        "description": [f"Quarantined {date.today()} by rollout-revert: #{pr} was reverted. {why} {run}"],
        "matchDepNames": [d["dep"]],
        "addLabels": ["quarantined"],
        "prBodyNotes": [f"⚠️ **Quarantined.** An update of this dependency was automatically reverted after a failed rollout (#{pr}). Automerge is blocked; review it and merge by hand, or add `gate-approved`."],
    }
    if d["update"] == "digest" or not d["to"]:
        # A digest update keeps the same tag, so there is no new version to pin.
        # Quarantine digest updates of this dep until the rule is removed.
        rule["matchUpdateTypes"] = ["digest"]
        lines.append(f"- `{d['dep']}`: digest updates")
    else:
        rule["matchNewValue"] = "/^v?" + re.escape(d["to"].removeprefix("v")) + "$/"
        lines.append(f"- `{d['dep']}` `{d['to']}`")
    cfg["packageRules"].append(rule)
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
print("\n".join(lines))
PY
)
if [[ -n "$QUARANTINED" ]]; then
  git commit -q -am "chore(quarantine): block automerge of #$PR's versions"
else
  QUARANTINED="_none: could not read Renovate's update table from #$PR. Add a rule to \`.github/renovate/quarantine.json\` by hand._"
fi

git push -q origin "$BRANCH"

AUTO=false
REASON_MANUAL=""
if [[ "$MODE" == live ]]; then
  AUTO=true
  if [[ "$KIND" == soak ]]; then
    for d in "${MANUAL_AFTER_SOAK[@]}"; do
      if [[ "$DIR" == "$d" || "$DIR" == "$d/"* ]]; then
        AUTO=false
        REASON_MANUAL="This is a DB-backed app and the new version ran before it failed, so it may have migrated the database. Downgrading needs a human: check the app's DB and its upgrade notes before merging."
      fi
    done
  fi
fi

BODY=$(cat <<EOF
Automatic revert of #$PR (**$TITLE**). Its rollout failed.

| | |
|---|---|
| HelmRelease | \`$HR_NS/$HR_NAME\` (\`$FILE\`) |
| Trigger | \`${EV_REASON:-?}\` |
| Run | $RUN_URL |

\`\`\`
$EV_MESSAGE
\`\`\`

**Quarantined** (in \`.github/renovate/quarantine.json\`; the automerge gate now blocks these):
$QUARANTINED

**What happens next:** $( if [[ "$AUTO" == true ]]; then echo "this PR auto-merges once checks pass, and Flux rolls the app back to the previous version."; elif [[ -n "$REASON_MANUAL" ]]; then echo "⚠️ **not auto-merging.** $REASON_MANUAL"; else echo "\`ROLLOUT_REVERT_MODE=$MODE\`, so this PR waits for you to merge it."; fi )

**To retry this version later:** delete its rule from \`.github/renovate/quarantine.json\` in a PR, or merge Renovate's next PR for it by hand.
EOF
)
NEW_PR=$(GH_TOKEN="$PUSH_TOKEN" gh pr create --repo "$REPO" --base main --head "$BRANCH" \
  --title "revert: $TITLE (#$PR)" --label revert --body "$BODY")
say ""
say "Opened $NEW_PR."

# --- 7. merge ----------------------------------------------------------------
if [[ "$AUTO" == true ]]; then
  GH_TOKEN="$PUSH_TOKEN" gh pr merge "$NEW_PR" --auto --squash
  say "Auto-merge enabled."
else
  say "Not auto-merging. ${REASON_MANUAL:-mode is $MODE.}"
fi

gh pr edit "$PR" --repo "$REPO" --add-label revert >/dev/null
gh pr comment "$PR" --repo "$REPO" --body "⏪ The rollout of this update failed (\`$HR_NS/$HR_NAME\`, \`${EV_REASON:-?}\`). Reverted in $NEW_PR; versions quarantined. [Run]($RUN_URL)" >/dev/null
