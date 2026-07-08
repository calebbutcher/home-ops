# paperless-ngx: deploying on the cluster

This runbook covers the **net-new** paperless-ngx deployment under
`kubernetes/apps/paperless/`. It uses the [`bjw-s` app-template](https://bjw-s-labs.github.io/helm-charts/)
with **external Postgres (CloudNativePG)** and **our own Redis** broker, plus
**Tika + Gotenberg** for Office/email parsing, reached at
<https://paperless.int.nerdbox.dev> (internal only).

paperless keeps three kinds of state:

- **Documents** (originals + archived PDFs, thumbnails) on TrueNAS NFS
  (`10.2.40.10:/mnt/mainPool/paperless`, the `media/` subdir). The NAS handles
  durability — the PVC is **not** VolSync'd.
- **PostgreSQL** — tags, correspondents, document types, dates, the full document
  metadata + content. Backed up nightly via CNPG barman → RustFS
  (`s3://postgres-backups/`, server name `paperless-postgres`, cron `0 0 5 * * *`).
- **Data dir** (`paperless-data`, local-path) — the Whoosh search index + ML
  classifier model. **Derived and rebuildable**, so not backed up (see Recovery).

The paperless image runs the webserver + Celery workers + scheduler + consumer in
**one container** (s6/supervisord); only Postgres and Redis are external.

## Prerequisites (NAS + DNS)

1. **NFS export** at `10.2.40.10:/mnt/mainPool/paperless`, same config as the Immich
   export (**no_root_squash**, cluster subnet allowed). The container starts as root
   and `gosu`-drops to **uid/gid 1000** (`USERMAP_UID/GID`), so the export must accept
   uid 1000 writes — simplest is `chown 1000:1000` the dataset. The export is mounted
   once at `/nfs` in the pod; paperless creates the `media/` and `consume/` subdirectories
   itself on first boot (`PAPERLESS_MEDIA_ROOT` / `PAPERLESS_CONSUMPTION_DIR`). To use a
   different path, edit `media-pv.yaml`.

   > **Why a single `/nfs` mount and not subPaths:** mounting the export three times with
   > `subPath:` (media/consume/export) makes the kubelet hang at `ContainerCreating` with no
   > error event on this NFS server. A single plain mount (like Immich's) avoids that.
2. **DNS**: `paperless.int.nerdbox.dev` → cluster ingress (like the other `*.int` hosts).
3. **`nfs-common`** present on every node (already true cluster-wide; a fresh worker
   without it leaves the pod stuck `ContainerCreating`).

## What's in `kubernetes/apps/paperless/`

| File | Role |
|------|------|
| `namespace.yaml` | `paperless` namespace. |
| `postgres-cluster.yaml` / `postgres-objectstore.yaml` / `postgres-scheduledbackup.yaml` | CNPG `paperless-postgres` (PG17) + barman → RustFS + nightly backup. |
| `cnpg-rustfs-creds.sops.yaml` | RustFS S3 creds for barman. |
| `media-pv.yaml` / `media-pvc.yaml` | Static NFS PV/PVC `paperless-media` (RWX, Retain). |
| `pvc.yaml` | local-path `paperless-data` (index + classifier). |
| `redis.yaml` | `paperless-redis` Celery broker (emptyDir, not persisted). |
| `gotenberg.yaml` / `tika.yaml` | Office/email → PDF render + content extraction. |
| `secret.sops.yaml` | `paperless-secret`: Django secret key, bootstrap admin creds, OIDC providers JSON. |
| `helmrelease.yaml` | The webserver controller → Service `paperless:8000`. |
| `ingress.yaml` | `paperless.int.nerdbox.dev` (no forward-auth — paperless has its own login + OIDC). |

## Deploy

1. Merge the PR to `main`, then `flux reconcile kustomization apps --with-source`
   (or wait for the interval).
2. Watch it come up:
   ```sh
   kubectl -n paperless get pods,cluster,ingress
   ```
   Expect `paperless-postgres-1`, `paperless-redis`, `paperless-gotenberg`,
   `paperless-tika`, and `paperless-*` (the webserver) all Ready. First boot runs DB
   migrations and creates the **bootstrap superuser** from the secret.
3. The bootstrap admin password (key `PAPERLESS_ADMIN_PASSWORD`) can be read with:
   ```sh
   kubectl -n paperless get secret paperless-secret \
     -o jsonpath='{.data.PAPERLESS_ADMIN_PASSWORD}' | base64 -d; echo
   ```
   (User is `admin`.) Log in at <https://paperless.int.nerdbox.dev>.

## OAuth / OIDC (Authentik)

SSO is wired the same way as Immich (see `authentik-sso.md`). The Authentik side is
fully GitOps:

- Blueprint `kubernetes/apps/authentik/blueprints/paperless-oauth2.yaml` — group
  `paperless-users`, an OAuth2 provider (`client_id: paperless`), the `paperless`
  application, and a policy binding restricting access to `paperless-users`.
- The client secret is one generated value stored in **two** SOPS secrets:
  `authentik-secret` → `PAPERLESS_OAUTH2_CLIENT_SECRET` (injected into the worker,
  read by the blueprint via `!Env`) and `paperless-secret` →
  `PAPERLESS_SOCIALACCOUNT_PROVIDERS` (the allauth provider JSON, with the same
  secret inline).
- paperless reads OIDC from env (`PAPERLESS_APPS` + `PAPERLESS_SOCIALACCOUNT_PROVIDERS`),
  the allauth callback being `/accounts/oidc/authentik/login/callback/` (registered
  in the blueprint).

To use it: add your Authentik user to the **paperless-users** group, then click
**"Sign in with Authentik"** on the paperless login page. `PAPERLESS_SOCIAL_AUTO_SIGNUP`
auto-creates the paperless user on first login. Password login stays enabled
(`PAPERLESS_DISABLE_REGULAR_LOGIN: "false"`) as a fallback.

> **Admin via SSO:** paperless does not grant Django superuser from an OIDC claim, so
> the **bootstrap `admin`** account remains the superuser. To run paperless day-to-day
> as your SSO identity, promote that user to staff/superuser in
> Settings → Users (or the Django admin) once.

## The consume workflow

Drop files into the NFS `consume/` directory (`10.2.40.10:/mnt/mainPool/paperless/consume`)
from any host — a network scanner, another machine, etc. — and paperless ingests, OCRs,
and files them automatically. Because the dir is on NFS (where inotify is unreliable),
`PAPERLESS_CONSUMER_POLLING: "60"` makes paperless poll every 60s instead.

## Email-in (mail consumption)

paperless can pull documents from a mailbox over **IMAP** — email/forward bills, receipts,
or a phone photo and they get filed automatically. paperless polls every 5 min
(`PAPERLESS_EMAIL_TASK_CRON: "*/5 * * * *"`); inline-body emails render to a PDF via
Tika/Gotenberg (already deployed).

**Mailbox:** a **dedicated Gmail** used only for intake. Enable 2-Step Verification and
generate an **App Password** (Google → Security → App passwords); IMAP is on by default.
The mail account + rule live in **paperless' DB**, configured in the **UI**
(Settings → *Mail*) — there is **no SOPS secret**. The app password is held only in the
barman-backed Postgres (re-enter it on a from-scratch rebuild; revoke it in Google to cut
access).

**Mail Account** — `imap.gmail.com` : `993`, security **SSL**, username = the Gmail
address, password = the **app password**.

**Mail Rule** — one rule covers both attachments and inline bodies:

| Field | Value |
| --- | --- |
| Folder | `INBOX` |
| Attachment type | *All files, incl. inline* |
| Consumption scope | *Process full Mail as `.eml` **+** attachments as separate documents* |
| Action | *Mark as read* (non-destructive; won't reprocess) |
| Filter "from" *(recommended)* | your own sending address(es) — stops stray mail becoming docs |
| Assign tag *(optional)* | e.g. `email-in` |

The "`.eml` + attachments" scope is the key: the **body** becomes a PDF (inline receipts/text)
**and** attached photos/PDFs are consumed as their own OCR'd documents.

> ⚠️ **HEIC photos won't OCR** — the image lacks `pillow_heif`, so iPhone "Actual Size"
> (HEIC) photos are skipped. On the phone set **Camera → Formats → "Most Compatible"** (saves
> JPEG), or when emailing pick a size other than "Actual Size" (Mail re-encodes to JPEG).
> **JPEG/PNG/TIFF/AVIF/PDF** all work.

## Recovery

- **Documents** live on the NAS (`media/`) — restore from the NAS's own backups.
- **Postgres** — restore the latest barman backup into a fresh CNPG cluster (see
  `backup-recovery.md`).
- **Data dir** (`paperless-data`) is **not** backed up by design. After a restore, or
  if the index is corrupt, rebuild it from Postgres + media:
  ```sh
  kubectl -n paperless exec deploy/paperless -- document_index reindex
  kubectl -n paperless exec deploy/paperless -- document_create_classifier
  ```

## Rollback

Net-new and self-contained: remove `- paperless` from
`kubernetes/apps/kustomization.yaml` (Flux prunes the namespace) and revert the
Authentik blueprint/secret/worker-env additions (purely additive). The NFS data on
the NAS is `Retain`'d.
