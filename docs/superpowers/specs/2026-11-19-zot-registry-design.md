# Zot container registry — design

Approved 2026-11-19.

## Intent

Push images from the laptop (`docker push`) to a registry in the homelab and have
the cluster pull them, with no GitHub in the loop. Quick to stand up; hardening
comes later.

## Goals / non-goals

- Goal: authenticated push from the laptop to `registry.int.nerdbox.dev`.
- Goal: the cluster pulls those images without per-namespace pull secrets.
- Non-goal (for now): metrics/alerts, S3 backend, Renovate rules for own images,
  internet exposure.
- Anti-goal: anyone other than the owner can push.

## Approaches

| Option | Trade-off | Verdict |
|---|---|---|
| Gitea built-in registry (storage on RustFS) | No new app, but couples images to Gitea | Not picked |
| **Zot** | Standalone, light; one more app to maintain | **Picked** (quick, independent) |
| Harbor | Scanning/RBAC, but Postgres + Redis + many services | Dropped, too heavy |

## Design

- `kubernetes/apps/registry/`: namespace (PSA baseline), bjw-s app-template
  HelmRelease with upstream `ghcr.io/project-zot/zot` pinned, config in a
  ConfigMap, Ingress on `registry.int.nerdbox.dev` (letsencrypt-prod, external-dns
  CNAME to `ingress.int.nerdbox.dev`, `security-headers` + `internal-only`
  middlewares). Listed in `kubernetes/apps/kustomization.yaml`.
- Auth: Zot htpasswd, one push user. Anonymous read (LAN-only via the ingress
  middleware) so the cluster pulls without imagePullSecrets. No Authentik
  forwardAuth: `docker login` cannot follow a browser redirect.
- Storage: `longhorn-scratch` PVC (30Gi, single replica, trim job, out of the backup group),
  no VolSync — images are rebuildable from source. Zot GC enabled. (Changed from
  longhorn-single at plan time: GC churn would make backup snapshots pin deleted
  blobs until the volume reaches its declared size.)
- Zot web UI/search extensions enabled for browsing.
- The htpasswd SOPS secret is created by the owner, not by hand-editing here.

## Calls made by Claude

Anonymous pull, longhorn-scratch without backups, no forwardAuth, UI enabled.

## Left to the builder / risks

- Traefik's default entrypoint timeouts may cut long layer pushes; verify with a
  large test push and raise timeouts if needed.
- Exact Zot version and config keys checked against upstream docs at build time.
