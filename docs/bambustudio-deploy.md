# Bambu Studio: deploying on the cluster

This runbook covers the **net-new** [Bambu Studio](https://github.com/bambulab/BambuStudio)
deployment under `kubernetes/apps/bambustudio/`, which runs the Bambu Lab slicer as a
container and streams its desktop to the browser. It uses the
[`bjw-s` app-template](https://bjw-s-labs.github.io/helm-charts/) with the
[LinuxServer image](https://docs.linuxserver.io/images/docker-bambustudio/), reached at
<https://bambustudio.int.nerdbox.dev> (internal only, gated by Authentik **and** the
image's own basic auth).

The point is to stop the slicer being tied to one workstation: profiles, printer
definitions and project files live on a Longhorn volume with the same VolSync backup
treatment as every other stateful app, and any browser on the LAN or over Tailscale gets
the same session.

## This is the first desktop container in the cluster

`linuxserver/bambustudio` is a **Selkies** image — rebased off KasmVNC on 2025-07-12 —
which runs the full GTK application against a Wayland compositor inside the container and
streams the framebuffer to the browser over a websocket. Nothing else here does that, so
three things in the manifests look unlike the rest of the repo and are deliberate:

- a **1Gi memory-backed `/dev/shm`**, which upstream requires (`--shm-size=1gb`),
- **`tcpSocket` probes** instead of the usual `httpGet`,
- a **6Gi memory limit**, sized for a slicer plus that tmpfs rather than for a web app.

Each is explained below and commented in place.

## Prerequisites

- **DNS**: `bambustudio.int.nerdbox.dev` → cluster ingress (handled by external-dns via
  the `external-dns.alpha.kubernetes.io/target` annotation, like the other `*.int` hosts).
- **Secrets** generated *before* the first apply — both are already committed:
  `bambustudio-secret` (basic auth) and `bambustudio-restic-secret` (VolSync).
- **Printer access code**, if you intend to drive a printer in LAN mode — see Caveats.

## What's in `kubernetes/apps/bambustudio/`

| File | Role |
|------|------|
| `namespace.yaml` | `bambustudio` namespace, PSA `baseline`. |
| `bambustudio-secret.sops.yaml` | `CUSTOM_USER` / `PASSWORD` — the image's own HTTP basic auth. |
| `bambustudio-restic-secret.sops.yaml` | VolSync restic repository + credentials (RustFS). |
| `pvc.yaml` | Longhorn `bambustudio-config` (RWO, 10Gi, `/config`) — the container user's home directory. |
| `replicationsource.yaml` | Nightly VolSync restic backup at 08:05. |
| `helmrelease.yaml` | app-template → Deployment + Service `bambustudio:3000`. |
| `ingress.yaml` | `bambustudio.int.nerdbox.dev`, security-headers + internal-only + Authentik forward-auth. |

Plus, elsewhere in the repo:

| File | Change |
|------|--------|
| `kubernetes/apps/kustomization.yaml` | `- bambustudio` added to `resources`. |
| `kubernetes/apps/monitoring/blackbox/probe-app.yaml` | `http://bambustudio.bambustudio:3000` added. |
| `renovate.json` | A `versioning:` regex for the image's non-semver tags. |

## Auth

Two layers, which is one more than any other app here:

1. **Authentik forwardAuth** at the ingress — `authentik-authentik-forwardauth@kubernetescrd`,
   the standard domain-wide proxy provider. No blueprint or per-app provider needed.
2. **HTTP basic auth** inside the container, via `CUSTOM_USER` / `PASSWORD`.

Expect **two prompts** on first load: the Authentik login, then a browser basic-auth
dialog.

The second layer is not redundancy for its own sake. The streamed desktop includes a
terminal with **passwordless sudo**, which makes this the most powerful surface on any
ingress in the cluster. forwardAuth is a Traefik-edge control and does nothing about a
request that originates inside the cluster and hits the ClusterIP directly; basic auth
closes that gap. The ingress also carries `traefik-internal-only@kubernetescrd`, so the
router rejects anything outside RFC1918 regardless of Host header.

Basic auth does **not** break the blackbox probe: the `http_app` module already lists
`401` in `valid_status_codes`, so an unauthenticated 401 still proves the app is
answering.

## Why port 3000 and not 3001

Upstream exposes 3000 as "HTTP, must be proxied" and 3001 as the same UI behind a
self-signed certificate. The Ingress targets **3000**. Traefik terminates TLS at the edge,
so the browser still gets the secure context Selkies needs for WebCodecs and clipboard
access; routing to 3001 would only add a self-signed backend certificate for Traefik to
ignore.

The desktop stream is a websocket on the same host and path prefix. Traefik proxies the
`Upgrade` handshake natively — no annotation — and forwardAuth runs on the upgrade request
like any other, with the session cookie already present.

## Probes

**`tcpSocket`, not `httpGet` — and this is load-bearing.** With `CUSTOM_USER`/`PASSWORD`
set, Selkies answers an unauthenticated `GET /` with 401, and the kubelet treats any status
≥ 400 as a probe failure. An `httpGet` probe here would `CrashLoopBackOff` a completely
healthy pod while the logs showed a working application.

A TCP connect is a weaker signal, but the real health check for a desktop stream is "does
the canvas render", which no probe can express. The blackbox `Probe` does the HTTP half.

The startup probe allows 5 minutes: first boot chowns `/config` and initialises the home
directory from scratch before the compositor comes up.

## securityContext

`fsGroup: 1000` only. **Do not** add `runAsUser` / `runAsNonRoot` / `readOnlyRootFilesystem`.
LinuxServer images boot s6-overlay as root, chown `/config`, then drop to `PUID`/`PGID`
themselves; forcing a non-root uid breaks the init before the app starts, and s6 needs a
writable rootfs. This is also why the namespace is PSA `baseline` rather than `restricted`.

There is deliberately **no container-level `securityContext`** on the initial deploy.
`allowPrivilegeEscalation: false` would set `no_new_privs` and disable the image's `sudo`
— arguably a feature here, but it is a change to make and verify on its own, after the
desktop is confirmed working. If you do it, land it as its own commit so it is trivially
revertible.

## Storage

`/config` is the container user's entire home directory: settings, printer and filament
profiles, the Bambu account session, and any project or sliced output left in the desktop.
None of it is reproducible from git, so it gets **VolSync** on top of the Longhorn
`daily-backup` RecurringJob that every volume joins.

The mover runs as `1000:1000` because the s6 init chowns `/config` to `PUID`/`PGID` — same
as audiobookshelf and tandoor, unlike pricewatch/technitium whose apps run as root. If a
backup ever fails on permissions, annotate the namespace
`volsync.backube/privileged-movers=true`.

⚠️ **10Gi is really 10Gi.** Longhorn schedules against the *declared* size, not the used
size (issue #349 — the cluster is already ~250% over-provisioned), so this consumes 10Gi
of scheduling budget across two replicas the moment it is created. Shrinking later means a
new PVC and a restic restore.

## Verify

Local, before opening the PR:

```bash
kubectl kustomize --load-restrictor LoadRestrictionsNone kubernetes/apps/bambustudio >/tmp/build.yaml
kubeconform -strict -ignore-missing-schemas -kubernetes-version 1.32.0 /tmp/build.yaml
yamllint kubernetes/apps/bambustudio
python3 .github/scripts/check-orphaned-manifests.py
sops -d kubernetes/apps/bambustudio/bambustudio-secret.sops.yaml   # decrypts clean
```

`flux build` is unusable in this repo (SOPS encrypts `kind:`), so kustomize + kubeconform
is the ceiling. To also catch a bad *chart values* key — which kubeconform cannot see,
since it only validates the HelmRelease CRD — render the chart directly:

```bash
helm template bambustudio app-template --version 5.1.0 \
  --repo https://bjw-s-labs.github.io/helm-charts/ -n bambustudio -f <(yq '.spec.values' kubernetes/apps/bambustudio/helmrelease.yaml)
```

After merge:

```bash
flux reconcile kustomization apps --with-source
kubectl -n bambustudio get pod,pvc,ingress,certificate
kubectl -n bambustudio logs deploy/bambustudio     # s6 init, then Selkies listening on 3000
```

End to end:

1. `https://bambustudio.int.nerdbox.dev` → Authentik login → basic-auth prompt → the Bambu
   Studio desktop renders. Confirm mouse, keyboard and the canvas stream respond — this is
   the part no manifest check can prove.
2. Add the printer by IP (see Caveats), or sign in to Bambu Cloud.
3. Slice a test model; confirm the output is under `/config` and survives
   `kubectl -n bambustudio rollout restart deploy/bambustudio`.
4. Force the first backup rather than waiting for 08:05:
   ```bash
   kubectl -n bambustudio patch replicationsource bambustudio-config --type merge \
     -p '{"spec":{"trigger":{"manual":"first"}}}'
   kubectl -n bambustudio get replicationsource bambustudio-config -o yaml | yq '.status'
   ```
5. Confirm the blackbox probe is green in Grafana:
   `probe_success{instance="http://bambustudio.bambustudio:3000"}`.

## Caveats

- **No printer auto-discovery.** Bambu Studio finds printers over SSDP multicast, which
  does not cross from the pod network to the printer's VLAN. Add the printer **by IP** in
  LAN mode — enable LAN Mode on the printer and read its Access Code off the screen — or
  sign into a Bambu account for cloud mode. This is why the pod is *not* on `hostNetwork`:
  that would fix discovery but breaks the Service/Ingress model, forces PSA `privileged`,
  and pins the pod to one node, which is a lot to pay for a slicer.
- **Two login prompts** (Authentik, then basic auth).
- **The web terminal has passwordless sudo.** Inside the container only, but it is why the
  ingress is `internal-only` and why basic auth is on.
- **Software rendering.** No `/dev/dri` on these Proxmox VMs, so rendering is llvmpipe.
  `DRINODE` / `DRI_NODE` / `AUTO_GPU` are deliberately unset — setting them without the
  device only produces a confusing startup failure. Expect 3D preview and slicing to feel
  slower than a desktop with a GPU.
- **AVX2 / Wayland fallback.** The image defaults to a Wayland stack and falls back to X11
  on its own if the CPU lacks AVX2, which is the behaviour we want either way. Set
  `PIXELFLUX_WAYLAND=false` to force X11 if the Wayland path misbehaves.
- **amd64 only** — no ARM64 image is published. Fine here; all nodes are x86-64.
- **`/dev/shm` is charged to the memory limit.** It is a `medium: Memory` emptyDir, so the
  1Gi tmpfs comes out of the pod's 6Gi cgroup rather than node page cache. Raising one
  without the other is a mistake.
- **Tag format.** Upstream tags are `v<zero-padded 4-part version>-ls<build>`, e.g.
  `v02.08.02.61-ls167`. Leading zeros are not semver, so `renovate.json` carries an
  explicit `versioning:` regex for this package — without it, a bump from `02.08` to
  `02.10` is not reliably seen as newer. The other `lscr.io` images here need no such rule.
