# Programmatic SSO with Authentik (blueprints)

Authentik in this cluster is configured **as code**. Onboarding an app to SSO is a
Git change: add (or extend) a **blueprint** YAML file, commit, and the Authentik
worker applies it automatically. No clicking through the admin UI.

## How it works

- Blueprint source lives in `kubernetes/apps/authentik/blueprints/*.yaml`.
- The app's `kustomization.yaml` wraps those files into a ConfigMap
  (`authentik-blueprints`) via a `configMapGenerator`.
- The HelmRelease mounts that ConfigMap (`blueprints.configMaps`) at
  `/blueprints/custom/` on the **server and worker**; the worker discovers every
  `*.yaml` key and reconciles it (create/update) on a schedule and on startup.
- **Secrets never go in a blueprint file.** Put the value in a SOPS secret, inject
  it into the worker as an env var, and reference it from the blueprint with the
  `!Env` tag. Other handy tags: `!Find [model, [field, value]]` to reference
  existing objects (flows, scope mappings, certs), and `!KeyOf <id>` to reference
  another entry in the same blueprint.

Two SSO styles are supported, depending on whether the app speaks OIDC/OAuth2
itself.

---

## Style A — OIDC / OAuth2 (apps with native SSO)

Use this for apps that have an OAuth2/OIDC login option (Grafana, etc.).

**Worked example: Grafana** — already wired in this repo:

- Blueprint: `kubernetes/apps/authentik/blueprints/grafana-oauth2.yaml` defines an
  `oauth2provider` (`client_id: grafana`, `client_secret: !Env
  GRAFANA_OAUTH2_CLIENT_SECRET`, redirect URI
  `https://grafana.int.nerdbox.dev/login/generic_oauth`) and the matching
  `application`.
- The client secret is one generated value stored in **two** SOPS secrets — the
  same value on both sides:
  - `kubernetes/apps/authentik/secret.sops.yaml` → `GRAFANA_OAUTH2_CLIENT_SECRET`
    (injected into the worker as env, read by the blueprint via `!Env`).
  - `kubernetes/apps/monitoring/grafana-oauth-secret.sops.yaml` → `client-secret`
    (injected into Grafana as `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`, which Grafana
    maps to `[auth.generic_oauth] client_secret`).
- Grafana's `auth.generic_oauth` block (in the kube-prometheus-stack HelmRelease)
  points at `https://authentik.int.nerdbox.dev/application/o/{authorize,token,userinfo}/`
  and maps the `authentik Admins` group to the Grafana Admin role.

### Recipe: add OIDC to another app

1. **Generate a client secret** and store it in both places (no value through the
   shell history if you can avoid it):
   - add a key to `authentik-secret.sops.yaml`, e.g. `MYAPP_OAUTH2_CLIENT_SECRET`;
   - add a secret in the app's namespace with the **same** value.
2. **Inject it into the worker** — add to `worker.env` in the HelmRelease:
   ```yaml
   - name: MYAPP_OAUTH2_CLIENT_SECRET
     valueFrom: { secretKeyRef: { name: authentik-secret, key: MYAPP_OAUTH2_CLIENT_SECRET } }
   ```
3. **Add a blueprint** `blueprints/myapp-oauth2.yaml` (copy `grafana-oauth2.yaml`),
   changing `client_id`, the `!Env` key, and `redirect_uris`. Add the file to the
   `configMapGenerator` list in `kustomization.yaml`.
4. **Configure the app** with `client_id`, the client secret (from its own secret),
   and the Authentik endpoints under `authentik.int.nerdbox.dev/application/o/`.

---

## Style B — Forward-auth (apps with NO native SSO)

Use this for apps that have no login of their own. Authentik's **embedded
outpost** (in the server pod) authenticates the request and Traefik enforces it
via a **ForwardAuth middleware**.

The shared middleware already exists:
`kubernetes/apps/authentik/middleware.yaml` →
`authentik-forwardauth` (references the embedded outpost at
`authentik-server:80/outpost.goauthentik.io/auth/traefik`). Traefik has
`allowCrossNamespacedIngresses: true`, so apps in other namespaces can use it as
`authentik-authentik-forwardauth@kubernetescrd`.

### This cluster uses **domain-wide** forward-auth

A single proxy provider — **"Provider for Nerdbox Auth"** (mode `forward_domain`,
`external_host https://authentik.int.nerdbox.dev`, `cookie_domain nerdbox.dev`),
bound to the embedded outpost — covers **every** `*.nerdbox.dev` host. There is
**no per-app proxy provider**. When an unauthenticated request hits a protected
app, the outpost redirects to `authentik.int.nerdbox.dev` to sign in, then sends
the user back with a session cookie scoped to `nerdbox.dev` (so the login is
shared across all apps on the domain). Login happens centrally, so a protected
app needs **no** `/outpost.goauthentik.io` routing of its own.

> The `forward_domain` provider is a migration-era object (carried in from the
> old Compose stack); it is not defined by a blueprint. It is the single source
> of forward-auth for the whole domain, so don't delete it.

### Recipe: protect an app with forward-auth (domain-wide)

Just **one annotation** on the app's Ingress — nothing else:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: authentik-authentik-forwardauth@kubernetescrd
```

No blueprint, no per-app provider, no `ExternalName` service, no extra path.

**Worked example: it-tools** — `kubernetes/apps/tools/it-tools/ingress.yaml`
carries exactly that annotation and nothing more. it-tools has no native login,
so the whole site now requires an Authentik session.

That's it — the app requires an Authentik login, and identity is passed
downstream via the `X-authentik-*` headers the middleware copies through.

### Alternative: per-app provider (`forward_single`)

Only needed if you want an app **isolated** from the shared domain session (its
own provider, its own authorization policy/consent). It is **not** how this
cluster is set up, and it does **not** mix cleanly with the domain-wide provider:
`forward_domain` matches the whole `cookie_domain`, so on the same outpost it can
shadow a `forward_single` provider for a host under that domain. Adopting this
pattern means retiring "Provider for Nerdbox Auth" first.

If you go this route, you'd add a blueprint with a `forward_single` proxy
provider + application bound to the embedded outpost, and on the app's Ingress
both the middleware annotation **and** a `/outpost.goauthentik.io` path routed to
the Authentik server (via an `ExternalName` service for apps in another
namespace), because with per-app providers the login callback resolves on the
app's own host rather than centrally.
