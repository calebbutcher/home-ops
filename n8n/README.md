# n8n workflows

Exported workflows for the in-cluster n8n (`kubernetes/apps/n8n`). n8n keeps the live
copy in its Postgres; these files are the reviewable/restorable copy. Credentials are
never exported; nodes only reference them by name.

## weekly-digest.json

Sunday 14:00 UTC digest to the `#weekly-digest` Discord channel: backup/compactor
health, open PRs, disk and cert headroom, restarts, and week-over-week speedtest,
Longhorn and CrowdSec numbers, with a short Claude-written summary on top.

Credentials to create in n8n (Credentials → Add):

- **Discord Webhook**: the `#weekly-digest` channel webhook URL.
- **Anthropic**: an API key (used with Sonnet). If this call fails the digest still
  posts, just without the summary.

Queries live in the `Queries` node (one per line); formatting is in `Build digest`.

## threat-intel.json

Daily 07:00 Eastern briefing to the `#threat-intel` Discord channel. It reads the security news,
mailing-list, and research feeds in the `Sources` node, plus CISA KEV, NVD, and GitHub
advisories. Claude (Sonnet) then picks and writes up what matters, in four sections: your lab
(matched against running images), identity & access, offensive research, and big picture. Weekends
only post exploited issues that touch the lab. Stories already covered are remembered for 45 days
and only come back when something material changes. `threat-intel-errors.json` posts failed runs
to the same channel.

Credentials: a **Discord Webhook** named `Discord Threat Intel` (the `#threat-intel` webhook
URL), and the **Anthropic** credential above.

The `Reader profile` node (who the briefing is for, plus private keywords and feeds) is kept out
of git. Importing from git resets it to the placeholder; fill it in again in the UI. Critical items
also get a deep dive (Claude with web search, up to 3 a day) posted as a follow-up message; set
`ENABLED = false` in `Deep dive items` to turn it off.

## alert-remediation*.json

Selected alerts start a Claude Code **routine**, which runs on Claude subscription usage
rather than API credits. It diagnoses the alert and may open a draft PR. You approve or
reject the merge with buttons in Discord.

```
Alertmanager ─(allowlisted alerts, bearer token)─▶ Alert remediation
   allowlist + 24h dedupe per alert group + 6 fires/h cap
   → Thanos / Loki / recent commits → redacted payload → routine /fire → Discord "investigating"
routine (cloud, repo only) → diagnosis, or a draft PR on claude/alert-*
Alert remediation approval (every 5 min) → Discord [Approve] [Reject], waits up to 24h
   Approve → mark ready + `gate-approved` → required checks green → squash-merge
   Reject  → close PR + delete branch
```

- **The allowlist lives in two places:** the `n8n` route in
  `kubernetes/apps/monitoring/kube-prometheus-stack/alertmanagerconfig.yaml` and
  `ALLOW` in the `Gate` node. Keep them in step.
- **Mode:** `MODE` in `Gate` starts at `diagnose`, so the routine reports but never
  pushes. Switch it to `pr` once a few diagnoses look right.
- **The routine** (prompt and settings) is in `n8n/routines/alert-remediation.md`.
- **The gate:** `automerge gate` fails every `claude/*` PR until it has
  `gate-approved`, which the Approve button adds.
- **Approve/Reject links** resume through `/webhook-waiting`, which is behind
  Authentik (`kubernetes/apps/n8n/ingress.yaml`), so clicking one needs an SSO session.

### Setup (once, in this order)

Do this **before** merging the Alertmanager route. While nothing listens on the
webhook, Alertmanager's notifications fail and `AlertmanagerFailedToSendAlerts` fires.

1. **Discord**
   - Create a channel `#alert-remediation` with a webhook. Save the webhook URL as a
     **Discord Webhook** credential named `Discord Alert Remediation`.
   - Create a Discord application with a bot (no privileged intents) and invite it to
     the server with View Channel + Send Messages on that channel. Save its token as
     a **Discord Bot** credential named `Discord alert bot`.
   - With Developer Mode on, copy the server and channel IDs into the
     `Ask in Discord` node.
2. **GitHub**
   - Create a fine-grained PAT for `home-ops` only, with Contents, Pull requests and
     Issues read/write, and Checks and Metadata read. Save it as a **GitHub** credential
     named `GitHub home-ops`.
   - Create the `claude-announced` label (command in `docs/updates.md`).
3. **Routine**
   - Create it from `n8n/routines/alert-remediation.md` and add an **API** trigger.
   - Paste the URL into `ROUTINE_URL` in `Gate`.
   - Save the token as a **Header Auth** credential named `Claude routine token`:
     name `Authorization`, value `Bearer sk-ant-oat01-…`.
4. **Alertmanager token**
   - Create a **Header Auth** credential named `Alertmanager webhook`: name
     `Authorization`, value `Bearer <token>`.
   - The token is `token` in `kubernetes/apps/monitoring/alertmanager-n8n.sops.yaml`.
5. **Import and publish**
   - Import `alert-remediation-errors.json` first, since the other two point at its
     fixed id. Then import `alert-remediation.json` and `alert-remediation-approval.json`.
   - Attach the credentials, then publish all three.
6. **Test**
   - Send a sample payload into the webhook and check the execution and the Discord post:

   ```sh
   kubectl -n monitoring exec -i sts/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager -- \
     wget -qO- --header "Authorization: Bearer $TOKEN" --header 'Content-Type: application/json' \
     --post-data '{"status":"firing","groupLabels":{"alertname":"ContainerOOMKilled","namespace":"immich"},"alerts":[{"status":"firing","labels":{"alertname":"ContainerOOMKilled","namespace":"immich","container":"immich-server"},"annotations":{"summary":"test"}}]}' \
     http://n8n.n8n.svc.cluster.local:5678/webhook/alert-remediation
   ```

   - Running it a second time should do nothing (dedupe is 24h per alertname and
     namespace). To test again, change `namespace` in the payload.

## Import / export

```sh
P=$(kubectl -n n8n get pod -l app.kubernetes.io/name=n8n -o name | head -1)

# import (lands unpublished; attach credentials and publish in the UI)
kubectl -n n8n exec -i "$P" -c app -- sh -c 'cat > /tmp/wf.json && n8n import:workflow --input=/tmp/wf.json' < n8n/workflows/weekly-digest.json

# export after editing in the UI
n8n/export.sh <id> n8n/workflows/weekly-digest.json
```
