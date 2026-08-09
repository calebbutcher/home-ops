# Secrets encryption at rest (k3s)

**Status: NOT enabled. Blocked on a k3s upgrade.** This document records why, and
holds the ready-to-run procedure for when the block clears.

Kubernetes Secrets are stored in etcd. Without encryption at rest they are stored
**base64-encoded, not encrypted** — anyone who can read the etcd data files or an
etcd snapshot can read every secret in the cluster. That matters here because the
etcd snapshots leave the node: they are shipped to RustFS on the NAS
(`--etcd-s3`), so the blast radius of a NAS compromise includes every Kubernetes
secret, not just the backups.

## What protects secrets today

| Layer | Protected? | Notes |
| --- | --- | --- |
| Secrets in Git | ✅ | SOPS + age. The age private key is offline; see [`backup-recovery.md`](backup-recovery.md). |
| Secrets in etcd | ❌ | Base64 only. This is the gap. |
| etcd snapshots on the NAS | ❌ | Inherit the above — a snapshot is a copy of etcd. |
| `/etc/rancher/k3s/config.yaml` | ✅ | Must be `0600`; holds the join token and RustFS keys in plaintext. |

## Why it is not enabled yet

Two independent reasons, both tied to the k3s version. The cluster runs
**v1.32.13+k3s1**.

**1. The documented procedure does not cover this version.** k3s's
[Enable Secrets Encryption on an Existing Cluster](https://docs.k3s.io/cli/secrets-encrypt)
is version-gated to **v1.33.10+k3s1 / v1.34.6+k3s1 / v1.35.3+k3s1** (the March
2026 releases). The 1.32 line is not listed.

**2. There is an unpatched, unrecoverable failure mode on this version.**
[k3s-io/k3s#13763](https://github.com/k3s-io/k3s/issues/13763) — *"Unrecoverable
state from interrupted secrets encryption rotation"* — was reported against "all
supported versions as of 2026 March" and **names HA clusters specifically**. If a
k3s server crashes while `rotate-keys` is reencrypting, the new key is already in
`encryption-config.json` but the datastore has not caught up; the server then
refuses to start with

```text
/var/lib/rancher/k3s/server/cred/encryption-config.json newer than datastore
and could cause a cluster outage. Remove the file(s) from disk and restart to be
recreated from datastore.
```

leaving half the secrets under each key. It was fixed in the 2026-03 release
cycle (closed 2026-03-26). **v1.32.13+k3s1 shipped 2026-03-04 and is the final
1.32 release**, so the fix is not in it and never will be. In the thread that
produced the fix ([#13598](https://github.com/k3s-io/k3s/issues/13598)) the
reporter recovered only by hand-decrypting their secrets with a script.

With ~251 secrets reencrypting at ~5/s, the exposure window is only ~50 seconds —
but the consequence of landing in it is an unrecoverable control plane, and the
mitigation (upgrade) is something the cluster needs anyway.

## Prerequisite: upgrade k3s

Kubernetes 1.32 went **EOL 2026-02-28** — this cluster is past it and receives no
further patches. (1.33 is EOL too, as of 2026-06-28.)

Target **1.35** (supported to 2027-02-28). k3s allows only +1 minor of skew, so
walk it one minor at a time — 1.32 → 1.33 → 1.34 → 1.35 — letting the cluster
settle between each. Renovate raises one PR per minor stream for exactly this;
see [`updates.md`](updates.md). Any of 1.33.10+, 1.34.6+, or 1.35.3+ clears the
block, but stopping short of 1.35 just means doing this again shortly.

## Procedure (run after the upgrade)

Servers are referred to as **S1 = 10.2.169.30**, S2 = `.31`, S3 = `.32`.
Transcribed from the k3s docs; the two ⚠️ notes are the traps that actually broke
people in #13598.

1. **Confirm the starting state, and take the baseline measurement** (any
   server). The grep is the test that step 9 repeats — establish now that it
   returns a **non-zero** count, otherwise passing it later proves nothing:
   ```bash
   sudo k3s secrets-encrypt status
   # Encryption Status: Disabled, no configuration file found

   sudo k3s etcd-snapshot save --name enc-check --dir /tmp/enc-check --s3=false
   sudo grep -ac "BEGIN .* PRIVATE KEY" /tmp/enc-check/enc-check-*
   sudo rm -rf /tmp/enc-check
   ```
   Expect a count > 0 — that is every `kubernetes.io/tls` secret sitting in etcd
   as readable PEM, which is exactly the exposure being closed.

2. **Enable — on S1 only:**
   ```bash
   sudo k3s secrets-encrypt enable
   ```
   > ⚠️ **One server, not three.** Every `secrets-encrypt` command follows
   > *run on one, restart all*. Running `enable` on each server in turn is
   > precisely what corrupted the cluster in #13598 — the servers never converge
   > and `status` reports a permanent hash mismatch.

3. **Add the flag on all three**, then restart **one at a time**:
   ```bash
   sudo sed -i '$a secrets-encryption: true' /etc/rancher/k3s/config.yaml
   sudo chmod 0600 /etc/rancher/k3s/config.yaml
   sudo systemctl restart k3s
   ```
   S1 first. Before moving to the next node, confirm it is back:
   ```bash
   kubectl get node <name> -o jsonpath='{.status.conditions[*].type}'   # Ready
   kubectl get node <name> -o jsonpath='{.status.conditions[?(@.type=="EtcdIsVoter")].status}'
   ```

4. **Check convergence:**
   ```bash
   sudo k3s secrets-encrypt status
   # Encryption Status: Disabled
   # Current Rotation Stage: start
   # Server Encryption Hashes: All hashes match
   ```
   > ⚠️ **Stop here unless it says `All hashes match`.** Continuing past a
   > mismatch is what turns a fixable problem into a restore.

5. **Snapshot before the irreversible step:**
   ```bash
   sudo k3s etcd-snapshot save --name pre-secrets-encryption
   ```

6. **Rotate — on S1 only.** This is the step that encrypts the existing secrets:
   ```bash
   sudo k3s secrets-encrypt rotate-keys
   ```
   Watch it: `journalctl -fu k3s`. ~5 secrets/sec, so ~1 minute at current size.
   **Do not restart anything while this runs** — that is the #13763 window.

7. **Wait for completion, then restart all three** (S1 first, then S2, S3, same
   Ready + EtcdIsVoter check between each):
   ```bash
   sudo k3s secrets-encrypt status   # Current Rotation Stage: reencrypt_finished
   ```

8. **Confirm:**
   ```bash
   sudo k3s secrets-encrypt status
   # Encryption Status: Enabled
   # Current Rotation Stage: reencrypt_finished
   # Server Encryption Hashes: All hashes match
   ```

9. **Prove it for real.** `status` reports what k3s *believes*; this reads what is
   actually on disk. Repeat the step 1 measurement — it must now return **0**:
   ```bash
   sudo k3s etcd-snapshot save --name enc-check --dir /tmp/enc-check --s3=false
   sudo grep -ac "BEGIN .* PRIVATE KEY" /tmp/enc-check/enc-check-*
   sudo rm -rf /tmp/enc-check
   ```
   A non-zero count means at least one of the ~51 `kubernetes.io/tls` secrets is
   still sitting in etcd as readable PEM, i.e. the reencryption did not cover
   everything. `etcdctl` is deliberately not used — it is not installed on these
   nodes and k3s exposes no `etcdctl` subcommand.

10. **Record it in Git** — flip `secrets_encryption: true` in
    [`ansible/inventory/my-cluster/group_vars/all/main.yml`](../ansible/inventory/my-cluster/group_vars/all/main.yml)
    and update the documented `config.yaml` contents, so a rebuild reproduces the
    setting.

## If a rotation is interrupted

Restore the snapshot from step 5 — that is why it is taken. Failing that, the
maintainer's manual workaround in
[#13598](https://github.com/k3s-io/k3s/issues/13598) puts the `identity` provider
first in `encryption-config.json`, copies it to every server, points the API
server at it via `kube-apiserver-arg`, then rewrites every secret in plaintext
(`kubectl get secrets -A -o json | kubectl replace -f -`) before removing the
override. It works because the old key is still present to decrypt whatever was
already converted.

## Out of scope

**API-server audit logging** is deliberately deferred. It is the other half of
finding #19 in the blindspot audit, but at this tier it is high log volume for
low marginal value next to the journald + sshd coverage already shipped. Revisit
if the threat model changes.
