# Pricewatch (changedetection.io): deploying on the cluster

This runbook covers the **net-new** [changedetection.io](https://github.com/dgtlmoon/changedetection.io)
deployment under `kubernetes/apps/pricewatch/`, used to catch price drops / sale prices on
specific products (first target: the Owlet baby monitor). It uses the
[`bjw-s` app-template](https://bjw-s-labs.github.io/helm-charts/), reached at
<https://pricewatch.int.nerdbox.dev> (internal only, gated by Authentik).

changedetection.io keeps **all** state on disk under `/datastore` — there is no database.
It runs two containers in one pod:

- **app** (`ghcr.io/dgtlmoon/changedetection.io`) — the web UI + scheduler on port 5000. The
  image ships **only** the fast non-JS fetcher.
- **browser** (`dgtlmoon/sockpuppetbrowser`) — a headless-Chrome sidecar on port 3000 for the
  "Chrome/Playwright" fetcher, reached from the app over `ws://localhost:3000`
  (`PLAYWRIGHT_DRIVER_URL`). Needed for JS-heavy / bot-protected retailers.

State: **`pricewatch-data`** (local-path PVC, mounted at `/datastore`) holds watch definitions,
price/text history, page snapshots and notification config. **Non-rebuildable**, so it's backed
up nightly by **VolSync restic** → RustFS (`s3:.../volsync/pricewatch`, cron `50 7 * * *`).

## Prerequisites

- **DNS**: `pricewatch.int.nerdbox.dev` → cluster ingress (like the other `*.int` hosts).
- **Discord webhook** (for alerts): create a channel (e.g. `#price-alerts`) → Channel Settings →
  Integrations → Webhooks → New Webhook → Copy URL. You'll paste it into the UI (below) as an
  Apprise URL — it is **not** stored in git (it lives in the VolSync-backed datastore, same as
  the watches themselves and your Uptime Kuma monitors).

## What's in `kubernetes/apps/pricewatch/`

| File | Role |
|------|------|
| `namespace.yaml` | `pricewatch` namespace. |
| `pvc.yaml` | local-path `pricewatch-data` (RWO, `/datastore`). |
| `pricewatch-restic-secret.sops.yaml` / `replicationsource.yaml` | VolSync restic backup of `pricewatch-data`. |
| `helmrelease.yaml` | app + browser sidecar → Service `pricewatch:5000`. |
| `ingress.yaml` | `pricewatch.int.nerdbox.dev`, gated by the Authentik forward-auth middleware. |

The image runs as **root** and owns `/datastore` with normal read bits, so the VolSync mover
runs as root **without** privileged movers (unlike gitea). If the first backup ever fails on
permissions, annotate the namespace with `volsync.backube/privileged-movers: "true"`.

## Deploy

1. Merge the PR to `main`, then `flux reconcile kustomization apps --with-source`
   (or wait for the interval).
2. Watch it come up (pod should be `2/2` Ready):
   ```sh
   kubectl -n pricewatch get pods,pvc,ingress,certificate
   ```
3. Browse <https://pricewatch.int.nerdbox.dev> → you're redirected to Authentik → after login
   the changedetection dashboard loads.

## Post-deploy configuration (in the UI)

1. **Confirm the browser fetcher** — Settings → Fetching: the "Playwright/Chrome (…)" fetcher
   should be selectable (confirms the app reached the sidecar over `ws://localhost:3000`).
2. **Add the Discord notification** — Settings → Notifications → add an Apprise URL of the form
   `discord://<webhook_id>/<webhook_token>` (the two path segments from the webhook URL you
   copied). Click **Send test notification** and confirm it lands in the channel.
3. **Add a watch** — paste the product URL, then in the watch's **Edit**:
   - Set the request/fetcher to **Chrome/Playwright** (for Target/Walmart/Best Buy/Amazon).
   - Enable **"Re-stock & Price detection"** so it parses the price/availability.
   - Set a **lower-price trigger** (notify when price drops below your target) and/or a
     percentage drop.
   - Set a sensible **recheck interval** (e.g. every few hours — don't hammer retailers).

### Retailer notes (anti-bot)

- **Owlet.com** (Shopify) and **Target** are usually reliable via the browser fetcher.
- **Amazon / Walmart / Best Buy** aggressively block bots and may intermittently fail even with
  the headless browser. Fixes: set a **proxy** on that watch (Edit → Request → proxy), slow the
  recheck interval, or — for Amazon — watch a **Keepa** price page instead of Amazon directly.

## Verify backups

After the first scheduled run (or trigger one), confirm a snapshot was taken:
```sh
kubectl -n pricewatch get replicationsource pricewatch-data \
  -o jsonpath='{.status.lastSyncTime}{"\n"}'
```
Recovery follows the standard VolSync `ReplicationDestination` flow in
[`docs/backup-recovery.md`](./backup-recovery.md).

## Rollback

Remove the `- pricewatch` line from `kubernetes/apps/kustomization.yaml` and reconcile; Flux
prunes the namespace (`prune: true`). The restic repository at `s3:.../volsync/pricewatch`
is retained for restore.
