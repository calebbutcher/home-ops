# Gitea: deploying on the cluster

This runbook covers the **net-new, greenfield** Gitea deployment under
`kubernetes/apps/gitea/` (no repos migrated from the old standalone GitLab). It uses
the [`bjw-s` app-template](https://bjw-s-labs.github.io/helm-charts/) with **external
Postgres (CloudNativePG)**, reached at <https://gitea.int.nerdbox.dev> (internal
only), with **git-over-SSH** exposed on a dedicated MetalLB LoadBalancer IP and
**Authentik OIDC** for SSO.

Gitea keeps two kinds of state:

- **`/data` PVC** (`gitea-data`, local-path) — git repositories, LFS objects,
  avatars/attachments, and the generated `app.ini` (which holds Gitea's
  auto-generated `SECRET_KEY` / `INTERNAL_TOKEN` / oauth2 `JWT_SECRET`). The repos
  are the crown jewels, so this PVC **is** backed up nightly by VolSync → RustFS
  (`s3://volsync/gitea`, cron `35 6 * * *`).
- **PostgreSQL** — users, orgs, issues, PRs, metadata. Backed up nightly via CNPG
  barman → RustFS (`s3://postgres-backups/`, server `gitea-postgres`, cron `0 0 6 * * *`).

The Gitea image runs the web server + built-in SSH server in **one container**
(s6-overlay); only Postgres is external. Internal crypto secrets are **not** in Git —
Gitea generates them on first boot into the persisted `app.ini`.

## Prerequisites (DNS + MetalLB)

1. **DNS — web**: `gitea.int.nerdbox.dev` → the Traefik LoadBalancer IP
   (`10.2.169.81`), like the other `*.int` hosts. Serves the UI and git-over-HTTPS.
2. **DNS — SSH**: `gitea-ssh.int.nerdbox.dev` → the Gitea SSH LoadBalancer IP
   (`10.2.169.82`). A **separate** record is required because a hostname has one A
   record and the web name already points at Traefik. (Clone URLs will read
   `git@gitea-ssh.int.nerdbox.dev`.)
3. **MetalLB IP**: `service.ssh` requests `10.2.169.82` via
   `metallb.universe.tf/loadBalancerIPs`. Traefik holds `.81`; `.82` is the next free
   IP in the pool `10.2.169.80-10.2.169.90`. Confirm it's free before deploy:
   ```sh
   kubectl get svc -A -o wide | grep LoadBalancer
   ```
   TLS is issued automatically by cert-manager (DNS-01) as `gitea-tls`.

## What's in `kubernetes/apps/gitea/`

| File | Role |
|------|------|
| `namespace.yaml` | `gitea` namespace. |
| `postgres-cluster.yaml` / `postgres-objectstore.yaml` / `postgres-scheduledbackup.yaml` | CNPG `gitea-postgres` (PG17, HA x3) + barman → RustFS + nightly backup. |
| `cnpg-rustfs-creds.sops.yaml` | RustFS S3 creds for barman (same creds as other apps). |
| `pvc.yaml` | local-path `gitea-data` (repos + LFS + app.ini), 20Gi. |
| `gitea-restic-secret.sops.yaml` / `replicationsource.yaml` | VolSync restic repo creds + nightly backup of `gitea-data` → RustFS. |
| `secret.sops.yaml` | `gitea-secret`: bootstrap admin creds + the gitea-side OIDC client secret (consumed by the post-deploy CLI steps, not mounted by the pod). |
| `helmrelease.yaml` | The Gitea controller → Service `gitea:3000` (web) + `gitea-ssh` LoadBalancer (`:22`→`2222`). |
| `ingress.yaml` | `gitea.int.nerdbox.dev` (no forward-auth — Gitea has its own login + OIDC). |

Authentik side (SSO): `kubernetes/apps/authentik/blueprints/gitea-oauth2.yaml`
(+ its entry in the authentik `configMapGenerator`), the `GITEA_OAUTH2_CLIENT_SECRET`
worker env var, and the matching key in `authentik-secret`.

## Deploy

1. Merge the PR to `main`, then `flux reconcile kustomization apps --with-source`
   (or wait for the interval).
2. Watch it come up:
   ```sh
   kubectl -n gitea get pods,cluster,ingress,svc
   ```
   Expect `gitea-postgres-1/-2/-3` and `gitea-*` (the app) Ready, and the `gitea-ssh`
   Service showing EXTERNAL-IP `10.2.169.82`. First boot runs DB migrations and writes
   `app.ini` with the generated internal secrets onto the PVC.
3. Verify TLS + reachability: `curl -I https://gitea.int.nerdbox.dev` → 200.

## Post-deploy (one-time CLI steps)

Gitea's admin account and OAuth login source are **DB-stored**, not GitOps-managed, so
create them once via the CLI. Both commands pull their secret values from
`gitea-secret`, so nothing sensitive is typed on the shell.

1. **Bootstrap admin** (the web installer is locked via `INSTALL_LOCK`):
   ```sh
   kubectl -n gitea exec deploy/gitea -- gitea admin user create \
     --username "$(kubectl -n gitea get secret gitea-secret -o jsonpath='{.data.GITEA_ADMIN_USERNAME}' | base64 -d)" \
     --email    "$(kubectl -n gitea get secret gitea-secret -o jsonpath='{.data.GITEA_ADMIN_EMAIL}' | base64 -d)" \
     --password "$(kubectl -n gitea get secret gitea-secret -o jsonpath='{.data.GITEA_ADMIN_PASSWORD}' | base64 -d)" \
     --admin --must-change-password=false
   ```
   Log in at <https://gitea.int.nerdbox.dev> (user `admin`).
2. **Add the Authentik OAuth source** (name `authentik` → matches the blueprint's
   redirect URI `/user/oauth2/authentik/callback`):
   ```sh
   kubectl -n gitea exec deploy/gitea -- gitea admin auth add-oauth \
     --name authentik \
     --provider openidConnect \
     --key gitea \
     --secret "$(kubectl -n gitea get secret gitea-secret -o jsonpath='{.data.GITEA_OAUTH2_CLIENT_SECRET}' | base64 -d)" \
     --auto-discover-url https://authentik.int.nerdbox.dev/application/o/gitea/.well-known/openid-configuration \
     --scopes "openid email profile"
   ```
   A **"Sign in with authentik"** button then appears on the login page.

## OAuth / OIDC (Authentik)

SSO is wired like Paperless/Immich (see `authentik-sso.md`). The Authentik side is
fully GitOps:

- Blueprint `blueprints/gitea-oauth2.yaml` — group `gitea-users`, an OAuth2 provider
  (`client_id: gitea`), the `gitea` application, and a policy binding restricting access
  to `gitea-users`.
- The client secret is one generated value stored in **two** SOPS secrets:
  `authentik-secret` → `GITEA_OAUTH2_CLIENT_SECRET` (injected into the worker, read by
  the blueprint via `!Env`) and `gitea-secret` → `GITEA_OAUTH2_CLIENT_SECRET` (used by
  the `add-oauth` step above).

To use it: add your Authentik user to the **gitea-users** group, then click **"Sign in
with authentik"**. `oauth2_client.ENABLE_AUTO_REGISTRATION` auto-creates the Gitea user
on first login (`ACCOUNT_LINKING: auto` links to an existing account by email). Open
local sign-up stays disabled (`ALLOW_ONLY_EXTERNAL_REGISTRATION`); the bootstrap `admin`
remains the Gitea admin (Gitea does not grant admin from an OIDC claim — promote an SSO
user in Site Administration → Users if desired).

## Using git

- **HTTPS**: `git clone https://gitea.int.nerdbox.dev/<user>/<repo>.git` — authenticate
  with a **Personal Access Token** (Settings → Applications) as the password.
- **SSH**: add your public key (Settings → SSH Keys), then
  `git clone git@gitea-ssh.int.nerdbox.dev:<user>/<repo>.git`. Traffic hits the
  `gitea-ssh` LoadBalancer (`10.2.169.82:22`) → Gitea's built-in SSH server on `2222`.

## Recovery

- **Repos + LFS** (`gitea-data`): restore the latest VolSync restic snapshot into a
  fresh `gitea-data` PVC (see `backup-recovery.md`). This also restores `app.ini`, so
  the internal secrets survive.
- **Postgres**: restore the latest barman backup into a fresh CNPG cluster (see
  `backup-recovery.md`).

## Rollback

Net-new and self-contained: remove `- gitea` from
`kubernetes/apps/kustomization.yaml` (Flux prunes the namespace) and revert the
Authentik blueprint / `configMapGenerator` / worker-env / `authentik-secret` additions
(all purely additive).

## Follow-ups (out of scope here)

- **Gitea Actions** (built-in GitHub-Actions-compatible CI) — deploy an `act_runner`
  later as a separate change (registration token + privileged/DinD considerations).
- **External exposure** — to reach Gitea off-LAN, add `gitea.nerdbox.dev` to the
  Ingress `tls` + `rules` (immich is the model) and open SSH accordingly.
