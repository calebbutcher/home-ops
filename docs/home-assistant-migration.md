# Home Assistant: migrating from HAOS into the cluster

This runbook covers a **one-time** migration of an existing **Home Assistant OS
(HAOS)** install onto the in-cluster deployment defined under
`kubernetes/apps/home-assistant/`. The in-cluster app uses the
[`ghcr.io/home-operations/home-assistant`](https://github.com/home-operations/containers/pkgs/container/home-assistant)
image, which is **Home Assistant Core only** — it runs as `nobody` (UID/GID
**65534**), keeps everything under `/config`, and builds its own Python venv at
`/config/.venv` on first boot. Discovery works because the pod runs with
`hostNetwork: true`. It is reached at <https://ha.int.nerdbox.dev> (internal only).

For restoring this app's config from a VolSync backup (a different operation —
disaster recovery, not migration) see
[backup-recovery.md → Restore: Home Assistant config](backup-recovery.md#restore-home-assistant-config-volsync).

## ⚠️ Critical caveat: add-ons do NOT migrate

HAOS runs a **Supervisor** that manages **add-ons** (Mosquitto, Zigbee2MQTT/ZHA,
ESPHome, Node-RED, Samba, the File editor, etc.). This image has **no Supervisor
and no add-ons**. Integrations configured *inside* Home Assistant migrate cleanly
with `/config`; anything that was an **add-on must be redeployed separately** as
its own Kubernetes workload (e.g. an MQTT broker, ESPHome, Zigbee2MQTT) and then
re-pointed from HA.

Before cutting over, list the add-ons in use (HAOS → Settings → Add-ons) and plan
a replacement for each. None of them are handled by this migration.

> mDNS-based discovery is the only host-network feature wired up. **USB Zigbee/
> Z-Wave radios and local Bluetooth are not** — those need device passthrough and
> are out of scope. If you depend on a USB coordinator, move to a network-attached
> coordinator (e.g. SLZB-06 / Zigbee2MQTT over IP) first.

## Steps

### 1. Export `/config` from HAOS

Pick one:

- **Full backup (simplest):** HAOS → Settings → System → Backups → *Create
  backup* (full). Download the resulting `.tar`.
- **Direct copy:** install the **Samba share** or **SSH/Terminal** add-on and copy
  the `/config` directory off the appliance.

The payload that matters is the `/config` tree: `configuration.yaml`, the
`.storage/` directory (registries, auth, dashboards), `automations.yaml`,
`scenes.yaml`, `scripts.yaml`, `secrets.yaml`, `custom_components/`, and
`home-assistant_v2.db` (the SQLite recorder history).

### 2. Extract to a raw `/config` directory locally

A HAOS full-backup `.tar` is a tarball of tarballs. Extract the outer archive,
then extract `homeassistant.tar.gz` inside it — its `data/` directory **is**
`/config`:

```bash
mkdir -p ha-restore && tar -xf <backup>.tar -C ha-restore
mkdir -p ha-config && tar -xzf ha-restore/homeassistant.tar.gz -C ha-config
# ha-config/data is the /config tree
ls ha-config/data
```

Delete anything you don't want carried over (there is no `.venv` from HAOS to
worry about; the new image builds its own).

### 3. Seed the PVC before Home Assistant's first start

So the import doesn't race HA, suspend the HelmRelease, then load the config via a
throwaway helper pod that mounts the same PVC. Run from this repo's context with
`kubectl` pointed at the cluster:

```bash
# Stop HA from starting / holding the PVC
flux suspend hr home-assistant -n home-assistant
kubectl -n home-assistant scale deploy/home-assistant --replicas=0 2>/dev/null || true

# Throwaway pod that mounts the config PVC at /config
kubectl -n home-assistant apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: ha-seed
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0          # run as root so we can chown afterwards
  containers:
    - name: seed
      image: busybox:stable
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: config
          mountPath: /config
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: home-assistant-config
EOF
kubectl -n home-assistant wait --for=condition=Ready pod/ha-seed --timeout=120s

# Copy the extracted /config tree in (contents of data/ → /config)
kubectl -n home-assistant cp ha-config/data/. ha-seed:/config

# Hand ownership to the runtime user (the image runs as 65534)
kubectl -n home-assistant exec ha-seed -- chown -R 65534:65534 /config

# Clean up the helper
kubectl -n home-assistant delete pod ha-seed
```

### 4. Fix the `http:` block in `configuration.yaml`

Two changes are needed, and **both matter** — getting this wrong is the most likely
reason a freshly migrated HA won't load.

**a) Remove HAOS's own TLS.** A HAOS `configuration.yaml` often terminates TLS
itself (e.g. via the Let's Encrypt / DuckDNS add-on) with an `http:` block like:

```yaml
http:
  ssl_certificate: /ssl/fullchain.pem
  ssl_key: /ssl/privkey.pem
  server_port: 443
```

Those `/ssl/*` paths don't exist in this container, and `server_port: 443` clashes
with the Service/ingress/probe (all expect **8123**). Left in place, the `http`
integration fails validation — and because almost everything depends on it, HA
drops to **recovery mode** and the frontend never loads (`Setup failed for 'http':
Invalid config` → cascading `Setup failed` for `auth`, `api`, `frontend`,
`onboarding`, …). **Delete the `ssl_certificate`, `ssl_key`, and `server_port`
lines.**

**b) Trust the reverse proxy.** Behind Traefik, HA otherwise rejects requests
("request from a reverse proxy … not set-up for reverse proxies", HTTP **400**).
Because HA runs on `hostNetwork`, Traefik's traffic is **SNAT-ed to the node IP**,
so the source HA sees is a **node IP** (nodes are `10.2.169.30–43`), not a pod IP
— trust the node subnet, plus the pod CIDR in case Traefik is ever co-located on
HA's node.

Net result — edit the migrated `/config/configuration.yaml` (inside the `ha-seed`
pod before deleting it, or via the running container later) so the `http:` block is
exactly:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.2.169.0/24   # node subnet — HA is on hostNetwork, proxy source is the node IP
    - 10.42.0.0/16    # pod CIDR — covers Traefik co-located on HA's node
    - 127.0.0.1
```

After editing, restart Home Assistant (`kubectl rollout restart
deploy/home-assistant -n home-assistant`) so it reloads `configuration.yaml`.

### 5. Start it up

```bash
flux resume hr home-assistant -n home-assistant
kubectl -n home-assistant logs deploy/home-assistant -f
```

First boot builds the venv (a few minutes — the startup probe allows ~10 min).
Watch for `Home Assistant initialized` / the start of the HTTP server.

### 6. Remove HAOS-only integrations (Supervisor)

A restored HAOS instance carries the **`hassio`** (Home Assistant Supervisor)
integration, which cannot run in a Core container. It fails to initialise and drags
down everything that depends on it — expect a cascade in the logs:

```text
Setup failed for 'hassio': Integration failed to initialize.
Setup failed for 'backup': Could not setup dependencies: hassio
Setup failed for 'cloud': Could not setup dependencies: backup
Setup failed for 'default_config': Could not setup dependencies: cloud
```

Discovery (`zeroconf`/`ssdp`/`dhcp`), `recorder`, `mobile_app`, and the rest still
load — they set up independently — but to clear the cascade:

**Settings → Devices & Services → "Home Assistant Supervisor" → ⋮ → Delete**, then
restart HA. Afterwards `cloud` (Nabu Casa) sets up normally if you use it. The
Supervisor-based backup does **not** return — it isn't needed; VolSync backs up
`/config` (see [backup-recovery.md](backup-recovery.md)).

### 7. Verify and cut over

- Browse <https://ha.int.nerdbox.dev>; log in with the migrated credentials.
- Confirm dashboards, automations, and entity history are intact.
- Re-establish any former **add-ons** as separate workloads and re-point HA at them.
- Once satisfied, **power down the old HAOS instance** so the two don't both talk
  to your devices.

## Notes

- **Recorder DB:** kept as SQLite (`home-assistant_v2.db` in `/config`), so it
  migrates as-is and is captured by the VolSync backup. Moving to the cluster's
  CloudNativePG Postgres is an optional future change, not part of this migration.
- **Backups:** the `home-assistant-config` PVC is backed up nightly by VolSync to
  RustFS (`volsync/home-assistant`). See `backup-recovery.md`.
