# Backup & Recovery Runbook

This cluster is GitOps-managed (Flux). Most state is reconstructable from this
Git repo. This document covers the state that is **not** in Git and how to
recover it.

## What is backed up, and where

| State | Mechanism | Destination |
| --- | --- | --- |
| Desired state (manifests, HelmReleases) | Git | GitHub |
| App config PVCs (`*-config` in `media`) | VolSync (restic) | RustFS `volsync` bucket on NAS |
| etcd (cluster runtime state) | k3s `--etcd-s3` snapshots | RustFS `etcd-snapshots` bucket + local on each control node |
| Media / downloads | NAS-level (out of scope here) | NAS `mainPool` |
| SOPS age key | **Manual / offline** | Password manager + offline copy |

RustFS (S3-compatible object storage) runs on the TrueNAS at
`10.2.40.10:30292`, intentionally independent of the cluster it protects.

## Critical secrets (the things that make recovery possible)

1. **SOPS age private key** — `~/.config/sops/age/keys.txt`
   (pubkey `age1wcyzl9vjwakzxtxzw2qupn5332q7kpe8j4zyz434dcx2frqwd58qeutllz`).
   Without it, every `*.sops.yaml` in Git is permanently undecryptable.
   **Store it in the password manager and keep one offline copy.**
2. **Restic repository password(s)** — in the VolSync secret
   (`kubernetes/apps/media/backup/s3-secret.sops.yaml`). Without it the restic
   repos cannot be opened even with RustFS access. Store in the password
   manager.
3. **RustFS access/secret keys** — used by both VolSync and k3s etcd-s3.
4. **`k3s_token`** — must live in the ansible-vaulted secrets file, never
   committed in plaintext.

## Restore: a single app config PVC (VolSync)

1. Suspend the app's HelmRelease and scale the deployment to 0 so nothing holds
   the PVC.
2. Create a `ReplicationDestination` in `media` with `copyMethod: Direct`
   pointing at the same restic secret, e.g.:

   ```yaml
   apiVersion: volsync.backube/v1alpha1
   kind: ReplicationDestination
   metadata:
     name: seerr-config-restore
     namespace: media
   spec:
     trigger:
       manual: restore-once
     restic:
       repository: seerr-restic-secret
       copyMethod: Direct
       destinationPVC: seerr-config   # restore in place, or a scratch PVC
       cacheCapacity: 1Gi
       moverSecurityContext:
         runAsUser: 1000
         runAsGroup: 1000
         fsGroup: 1000
   ```

3. Wait for the mover job to complete (`kubectl get replicationdestination -n media`).
4. Remove the `ReplicationDestination`, scale the app back up, resume the HR.

## Restore: etcd (cluster-level disaster)

On a control node, with the cluster stopped:

```bash
k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=<snapshot> \
  --etcd-s3 \
  --etcd-s3-endpoint=10.2.40.10:30292 \
  --etcd-s3-bucket=etcd-snapshots \
  --etcd-s3-access-key=<key> \
  --etcd-s3-secret-key=<secret> \
  --etcd-s3-insecure
```

Then restart k3s on that node and rejoin the other servers. See the k3s docs on
cluster reset for the multi-server rejoin sequence.

> **Token caveat:** a snapshot can only be restored with the **server token that
> was in effect when it was taken**. Snapshots predating a token rotation need
> the old token; keep retired tokens in the password manager until their
> snapshots age out.

## Rotate the k3s cluster token

The cluster token encrypts etcd bootstrap data and authorises node joins. Rotate
it if it leaks (e.g. was committed in plaintext). **Do not** just change
`k3s_token` and re-run the playbook — the server role re-invokes `k3s-init`,
which is unsafe on a live cluster. Use k3s's built-in rotation and roll it
node-by-node:

1. **Save both tokens** (old + new) to the password manager. Existing snapshots
   need the old one.
2. On one server: `sudo k3s token rotate --token <old> --new-token <new>`.
   This re-encrypts the bootstrap data; nodes keep running on the old key until
   restarted.
3. **Servers** read their token from `/var/lib/rancher/k3s/server/token` (the
   persistent `k3s.service` has no `--token`). For each server, one at a time,
   write the new token to config and restart:
   ```bash
   sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
   token: "<new>"
   EOF
   sudo systemctl restart k3s
   ```
   Verify `EtcdIsVoter=True` + `Ready=True` before moving on
   (`kubectl get node <name> -o jsonpath='{.status.conditions[*].type}'`).
   Do the rotate node last.
4. **Agents** have `--token` hardcoded in `/etc/systemd/system/k3s-node.service`
   (the agent unit is `k3s-node`, not `k3s`). Get the authoritative new token
   from a server (`sudo cat /var/lib/rancher/k3s/server/node-token`), then on
   each worker edit that `--token` value (keep the trailing backslash),
   `systemctl daemon-reload && systemctl restart k3s-node`.
5. Take a fresh snapshot keyed to the new token:
   `sudo k3s etcd-snapshot save --name post-token-rotation`.
6. Update `k3s_token` in the Ansible inventory (ansible-vaulted) so future
   playbook runs use the new token; never commit it in plaintext.

## Full disaster recovery (rebuild from scratch)

1. **Restore the age key** to `~/.config/sops/age/keys.txt` from the password
   manager.
2. Re-provision nodes and install k3s via the Ansible playbook
   (`ansible/`). Restore etcd from the RustFS snapshot if preserving cluster
   identity, or start fresh.
3. **`flux bootstrap`** against this Git repo — Flux reconciles all
   infrastructure and apps, decrypting secrets with the restored age key.
4. VolSync ReplicationSources come up; restore each `*-config` PVC from RustFS
   via the per-app `ReplicationDestination` procedure above before/while the
   apps start.

## Verifying backups are healthy

- `kubectl get replicationsource -n media` → `LAST SYNC` recent for all four.
- `kubectl get etcdsnapshotfiles.k3s.cattle.io` → entries with `s3://` locations.
- Objects present in RustFS `volsync` and `etcd-snapshots` buckets.
- Periodically run a restore drill (restore `seerr-config` into a scratch PVC
  and confirm `db/db.sqlite3` + `settings.json` are intact).
