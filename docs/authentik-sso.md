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

### Recipe: protect an app with forward-auth

1. **Blueprint** — add a proxy provider + application and bind it to the embedded
   outpost (extend a single `proxy-forwardauth.yaml`, listing all proxy providers
   in the one embedded-outpost entry):
   ```yaml
   version: 1
   metadata:
     name: proxy-forwardauth
   entries:
     - model: authentik_providers_proxy.proxyprovider
       id: myapp-proxy
       identifiers: { name: myapp }
       attrs:
         name: myapp
         mode: forward_single
         external_host: https://myapp.int.nerdbox.dev
         authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
         invalidation_flow: !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
     - model: authentik_core.application
       id: myapp-app
       identifiers: { slug: myapp }
       attrs: { name: MyApp, slug: myapp, provider: !KeyOf myapp-proxy }
     - model: authentik_outposts.outpost
       identifiers: { name: authentik Embedded Outpost }
       attrs:
         providers:
           - !KeyOf myapp-proxy   # list ALL forward-auth providers here
   ```
2. **Ingress** — on the protected app's Ingress:
   - add the middleware annotation:
     ```yaml
     traefik.ingress.kubernetes.io/router.middlewares: authentik-authentik-forwardauth@kubernetescrd
     ```
   - route `/outpost.goauthentik.io` on the **same host** to the Authentik server
     so the login redirect/callback resolves on the app's domain. For an app in a
     **different namespace** than `authentik`, add a small `ExternalName` Service
     and back the path with it:
     ```yaml
     # in the app's namespace
     apiVersion: v1
     kind: Service
     metadata: { name: authentik-server, namespace: <app-ns> }
     spec:
       type: ExternalName
       externalName: authentik-server.authentik.svc.cluster.local
       ports: [{ name: http, port: 80 }]
     ```
     ```yaml
     # in the app's Ingress rules, before the catch-all "/" path
     - path: /outpost.goauthentik.io
       pathType: Prefix
       backend: { service: { name: authentik-server, port: { number: 80 } } }
     ```

That's it — the app now requires an Authentik login, and identity is passed
downstream via the `X-authentik-*` headers the middleware copies through.
