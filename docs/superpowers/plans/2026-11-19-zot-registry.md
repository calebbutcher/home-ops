# Zot Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Zot OCI registry at `registry.int.nerdbox.dev` that the owner pushes to from the laptop and the cluster pulls from anonymously.

**Architecture:** New `kubernetes/apps/registry/` app, built like `kubernetes/apps/speedtest/`: namespace, SOPS htpasswd secret, `longhorn-scratch` PVC, bjw-s app-template HelmRelease (Zot config inline via app-template `configMaps:` so a config change rolls the pod), Traefik Ingress.

**Tech Stack:** Zot v2.1.23 (`ghcr.io/project-zot/zot`), bjw-s app-template 5.2.1, Flux, Longhorn, Traefik 3, cert-manager, external-dns.

**Spec:** `docs/superpowers/specs/2026-11-19-zot-registry-design.md`

## Global Constraints

- Branch `feat/zot-registry`, PR to `main`; conventional commits, short plain bodies.
- Never create or edit `*.sops.yaml` by hand; the owner runs the sops command (Task 1).
- No top-level kustomize `namespace:`/labels transformers in `kubernetes/apps/registry/kustomization.yaml`; every manifest sets `namespace: registry`.
- Image `ghcr.io/project-zot/zot:v2.1.23` (verified to exist). Container port 5000.
- Hostname `registry.int.nerdbox.dev`; no Authentik forwardAuth; middlewares `traefik-security-headers@kubernetescrd,traefik-internal-only@kubernetescrd`.
- Push user name: `caleb`.
- No CVE scanning extension (no trivy DB download).

## Review Focus

1. Anonymous `docker push` must be rejected (401), while anonymous pull succeeds. Task 3, step 3.
2. A push of a layer that takes over 60s through Traefik (v3 default `readTimeout: 60s`, not overridden in `kubernetes/infrastructure/controllers/traefik/helmrelease.yaml`) must not fail mid-upload. Task 3, step 4.
3. A cluster node's containerd must resolve and pull `registry.int.nerdbox.dev/...` without a pull secret. Task 3, step 5.
4. Config typos must fail before deploy rather than CrashLoop. Task 2, step 1 (`zot verify`).
5. The pod must survive a restart with its images intact (RWO volume, `Recreate`). Task 3, step 6.

---

### Task 1: htpasswd secret (owner runs this)

**Files:**
- Create (by the owner): `kubernetes/apps/registry/secret.sops.yaml`

**Interfaces:**
- Produces: Secret `registry-auth` in namespace `registry`, key `htpasswd` (bcrypt line for user `caleb`).

- [ ] **Step 1: Owner generates and encrypts the secret**

```bash
mkdir -p kubernetes/apps/registry
read -s "PW?registry password for caleb: "; echo
kubectl create secret generic registry-auth -n registry \
  --from-literal=htpasswd="$(htpasswd -nbB caleb "$PW")" \
  --dry-run=client -o yaml > kubernetes/apps/registry/secret.sops.yaml
unset PW
sops --encrypt --in-place kubernetes/apps/registry/secret.sops.yaml
```

The owner also saves the password in their password manager.

- [ ] **Step 2: Verify it is encrypted**

Run: `grep -c 'ENC\[' kubernetes/apps/registry/secret.sops.yaml && grep -q 'sops:' kubernetes/apps/registry/secret.sops.yaml && echo ok`
Expected: a count ≥1 and `ok`; no plaintext `$2y$` hash visible.

---

### Task 2: Registry manifests

**Files:**
- Create: `kubernetes/apps/registry/{kustomization,namespace,pvc,helmrelease,ingress}.yaml`
- Modify: `kubernetes/apps/kustomization.yaml` (add `- registry`)
- Modify: `kubernetes/infrastructure/configs/flux-discord-alert.yaml` and `kubernetes/infrastructure/configs/github-dispatch-alert.yaml` (add `{kind: HelmRelease, name: "*", namespace: registry}` in alphabetical position)

**Interfaces:**
- Consumes: Secret `registry-auth` key `htpasswd` (Task 1).
- Produces: Service `zot` port 5000 (single service ⇒ release name), Ingress host `registry.int.nerdbox.dev`, PVC `zot-data`.

Zot config (the values the implementer must use; JSON inside `configMaps.config.data."config.json"`):

```json
{
  "distSpecVersion": "1.1.1",
  "storage": { "rootDirectory": "/var/lib/registry", "dedupe": true,
               "gc": true, "gcDelay": "1h", "gcInterval": "24h" },
  "http": {
    "address": "0.0.0.0", "port": "5000", "realm": "zot",
    "auth": { "htpasswd": { "path": "/etc/zot-auth/htpasswd" }, "failDelay": 5 },
    "accessControl": {
      "repositories": { "**": { "anonymousPolicy": ["read"], "defaultPolicy": ["read"] } },
      "adminPolicy": { "users": ["caleb"], "actions": ["read", "create", "update", "delete"] }
    }
  },
  "log": { "level": "info" },
  "extensions": { "search": { "enable": true }, "ui": { "enable": true } }
}
```

- [ ] **Step 1: Validate the Zot config with Zot itself**

Write the JSON above to the scratchpad and run
`docker run --rm -v <scratch>/config.json:/etc/zot/config.json:ro -v <scratch>/htpasswd:/etc/zot-auth/htpasswd:ro ghcr.io/project-zot/zot:v2.1.23 verify /etc/zot/config.json`
(any throwaway bcrypt htpasswd file).
Expected: exit 0, no "invalid" errors. If a key is rejected, fix it against the v2.1.23 `examples/` dir and record the change here.

- [ ] **Step 2: Write the manifests**, following `kubernetes/apps/speedtest/` comment style (explain the why for each non-obvious choice):
  - `namespace.yaml`: `registry`, PSA `enforce: baseline` + `enforce-version: latest`.
  - `pvc.yaml`: `zot-data`, RWO, `storageClassName: longhorn-scratch`, `30Gi`. Comment: why scratch (GC churn + snapshot pinning; images rebuildable).
  - `helmrelease.yaml`: app-template `5.2.1`, controller `zot`, `strategy: Recreate`. Pod securityContext `runAsUser/runAsGroup/fsGroup: 65532`, `runAsNonRoot: true`, `fsGroupChangePolicy: OnRootMismatch`, `seccompProfile: RuntimeDefault`. Container: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`. Image above. Probes: startup `/startupz`, liveness `/livez`, readiness `/readyz`, all on port 5000. Resources: requests `cpu: 50m, memory: 128Mi`, limit `memory: 1Gi`. Persistence: `config` (configMap → `/etc/zot`), `auth` (secret `registry-auth` → `/etc/zot-auth`), `data` (`existingClaim: zot-data` → `/var/lib/registry`), `tmp` (emptyDir → `/tmp`). Service `app` port 5000.
  - `ingress.yaml`: modeled on `kubernetes/apps/speedtest/ingress.yaml` but without the Authentik middleware, TLS secret `registry-tls`, backend `zot:5000`. Comment why no forwardAuth (docker CLI can't follow redirects; Zot htpasswd is the auth boundary).
  - `kustomization.yaml`: resources namespace, secret.sops.yaml, pvc, helmrelease, ingress; with the SOPS NOTE comment from speedtest.

- [ ] **Step 3: Run local checks (mirror CI)**

```bash
kustomize build kubernetes/apps/registry | kubeconform -strict -ignore-missing-schemas -summary
python3 .github/scripts/check-orphaned-manifests.py kubernetes
python3 .github/scripts/check-alert-coverage.py kubernetes
yamllint -c .yamllint.yaml kubernetes/apps/registry kubernetes/infrastructure/configs
```

Expected: kubeconform 0 invalid/0 errors; both scripts exit 0; yamllint clean.
(kubeconform is not installed on the laptop: run `kustomize build` alone locally and let CI's kubeconform gate the PR.)

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/registry kubernetes/apps/kustomization.yaml kubernetes/infrastructure/configs docs/superpowers
git commit -m "feat(registry): add Zot container registry"
```

---

### Task 3: Ship and verify live

- [ ] **Step 1: Push branch, open PR, owner merges.** PR body: short, what changed.

- [ ] **Step 2: Wait for rollout**

Run: `flux reconcile ks apps --with-source && kubectl -n registry rollout status deploy/zot --timeout=5m && curl -sI https://registry.int.nerdbox.dev/v2/`
Expected: rollout success; `HTTP/2 401` with `www-authenticate: Basic realm="zot"`.

- [ ] **Step 3: Auth behavior**

```bash
docker logout registry.int.nerdbox.dev; docker pull alpine:3.22
docker tag alpine:3.22 registry.int.nerdbox.dev/test/alpine:3.22
docker push registry.int.nerdbox.dev/test/alpine:3.22    # expect: unauthorized
docker login registry.int.nerdbox.dev -u caleb           # owner types password
docker push registry.int.nerdbox.dev/test/alpine:3.22    # expect: pushed
docker logout registry.int.nerdbox.dev
docker pull registry.int.nerdbox.dev/test/alpine:3.22    # expect: anonymous pull OK
```

- [ ] **Step 4: Large-layer push**

Build an image with one ~1.5GB random layer (`dd if=/dev/urandom of=blob bs=1m count=1500` + `FROM scratch` / `COPY blob /`), push it logged in. If it fails with a reset/EOF near 60s, raise `ports.websecure.transport.respondingTimeouts.readTimeout` in the Traefik HelmRelease (separate commit/PR) and retest.
Expected: push completes.

- [ ] **Step 5: Cluster pull**

Run: `kubectl run regtest -n registry --rm -it --restart=Never --image=registry.int.nerdbox.dev/test/alpine:3.22 -- echo pulled`
Expected: prints `pulled`.

- [ ] **Step 6: Persistence across restart**

Run: `kubectl -n registry rollout restart deploy/zot && kubectl -n registry rollout status deploy/zot && docker pull registry.int.nerdbox.dev/test/alpine:3.22`
Expected: pull succeeds after restart.

- [ ] **Step 7: Clean up test images** via the Zot UI or `curl -u caleb -X DELETE https://registry.int.nerdbox.dev/v2/<repo>/manifests/<digest>`.
