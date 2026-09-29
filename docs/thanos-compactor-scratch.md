# Thanos compactor: dedicated node-local scratch disk

The compactor needs ~65GiB of working space for a few hours at a time and nothing
in between. Where that space comes from has now broken this cluster twice, so this
documents what it runs on, why it is a `hostPath` rather than a PVC, and the two
things that are easy to get wrong.

> **Part of this is not in git.** Ansible host groups live in
> `ansible/inventory/my-cluster/hosts.ini`, which is `.gitignore`d. The
> `[scratch_disk]` group that `scratch-disk.yml` targets therefore exists only on
> the operator's machine, so the authoritative record of *which* workers carry a
> scratch disk is this document plus the `nodeAffinity` block in
> `kubernetes/apps/monitoring/thanos/helmrelease.yaml`. Those two and the inventory
> group must agree.

## What runs where

| | |
|---|---|
| Disk | 100 GiB, `cephSSD`, attached as **`scsi2`**, `discard=on`, `ssd=1` |
| Workers | `k3s-worker-01` (VM 103, pve-r630-01), `k3s-worker-04` (106, pve-r630-02), `k3s-worker-06` (116, pve-r630-02) |
| Mount | `/var/mnt/scratch`, ext4, `defaults,discard`, `mkfs -m 1` |
| Compactor data-dir | `/var/mnt/scratch/thanos-compact`, owned `1001:1001` |
| Prepared by | `ansible-playbook scratch-disk.yml` (group `[scratch_disk]`) |
| Alerts | `kubernetes/apps/monitoring/kube-prometheus-stack/prometheusrule-thanos-scratch.yaml` |

Three workers, not one, because the compactor is a singleton: it needs somewhere to
land when one node is down and another is cordoned during an `update.yml` roll.
worker-01 sits on a different Proxmox host from 04/06, so losing one PVE host
cannot strand it.

## Why a hostPath and not a PVC

The compactor's data directory is pure scratch — every byte in it is re-downloaded
from RustFS on demand. That makes the usual storage trade-offs run backwards.

**Why not Longhorn (what we came from).** Its scratch volume shared
`/var/lib/longhorn` with live database volumes. On 2026-09-12 a compaction
exhausted worker-03's allocatable space in ~30 minutes; Longhorn's iSCSI target
returned `Space allocation failed write protect` to the *other* volumes on that
disk and the kernel aborted their ext4 journals:

```
critical space allocation error, dev sdf, sector 21309392 op 0x1:(WRITE)
Aborting journal on device sdf-8.
EXT4-fs error (device sdf): comm postgres: Detected aborted journal
```

An aborted journal returns EIO forever and does not recover when space is freed.
`authentik-postgres-3` and `immich-postgres-2` both had to be re-cloned. Every
previous attempt here adjusted the size (20Gi → 100Gi → 90Gi → disabled) while
leaving the volume on a shared filesystem. **The fix was isolation, not capacity.**

**Why not `local-path`.** It provisions into the OS root filesystem, which is
95.8GiB per worker with 17–42GiB free, shared with containerd images and every
other local-path PVC, and kubelet evicts at `nodefs.available < 5%`. A 65GiB
compaction there takes the whole node into DiskPressure — strictly worse than
Longhorn. It is also why the original 20Gi "worked" for months: local-path enforces
no quota, so compaction silently overran the declared size until Longhorn made the
number real.

**Why not a `local` PV on the new disk.** Any PVC binds to one node permanently, so
a dead node leaves the singleton `Pending` — the exact failure moving to Longhorn
was meant to prevent, and which it failed to prevent anyway (the 90Gi declaration
had made the volume unschedulable since 09-09, so the compactor could not have
moved off a failed node). A `hostPath` has no binding at all: the data is
disposable, so nothing has to follow the pod.

On a dedicated filesystem, running out of space halts only the compactor. That is
loud (`thanos_compact_halted`), recoverable, and cannot reach anything else.

## Gotcha 1: never address this disk as `/dev/sdX`

Longhorn presents every attached volume to the node as an iSCSI LUN, so each worker
already carries a shifting set of `sdc`…`sdn` (`model=VIRTUAL-DISK`, vendor `IET`).
The 100G QEMU disk landed on a **different letter on each node** — `sdg` on
worker-01, `sde` on worker-04, `sdf` on worker-06 — and those letters are reassigned
on every boot depending on iSCSI attach order.

A literal `/dev/sdc` in the role would eventually point at a live Longhorn volume,
which is unpartitioned, ext4 and about the right size — so it would pass every
guard before being reformatted. The role therefore uses:

```
/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2
```

and mounts by UUID so `/etc/fstab` does not depend on the letter either. **The disk
must stay on `scsi2`**, because Proxmox derives that symlink from the drive slot.
(`ansible/roles/longhorn` gets away with a literal `/dev/sdb` only because
`scsi0`/`scsi1` are attached at boot, ahead of any iSCSI LUN.)

Because the Longhorn data disk is also ~100 GiB, unpartitioned and ext4, the role's
size and filesystem checks cannot tell the two apart. What does is an assertion that
the resolved device is **not already mounted anywhere** — `sda1` is at `/` and `sdb`
at `/var/lib/longhorn`, always. The whole-disk case (`/dev/sda`, whose *partitions*
are mounted) is caught by the separate no-partitions assertion instead.

## Gotcha 2: `discard=on` has to be set on the QEMU device

Without it, ext4's `discard` mount option is a silent no-op: the ~65GiB a compaction
frees is never returned to the Ceph pool, and every node that has ever compacted
holds that space forever. Across three workers that is ~210GiB usable (~630GiB raw
at `replica:3`) out of roughly 642GiB free.

It is set, but it only takes effect after the VM restarts. Confirm with
`qm config <vmid> | grep scsi2` on the PVE host and, in the guest, `lsblk -D` —
`DISC-GRAN`/`DISC-MAX` must be non-zero. `rotational` flipping to `0` is the
easy tell that the guest picked up the new device model.

## Sizing, and when to grow it

Measured on the 2026-08-13 → 08-27 window, the peak is the whole 14d raw tier on
disk at once:

```
  32.8 GiB   7x 2d source blocks
+ 32.5 GiB   the 14d block they merge into
= ~65.3 GiB  peak
```

The output barely dedupes — do not assume it is smaller than the input. `thanos
compact` has **no `--block-ranges` flag**, so the 2h/8h/2d/14d tiers cannot be
tuned; disk is the only lever.

100 GiB formats to ~97 GiB available, leaving ~32 GiB of headroom. Watch
`ThanosCompactScratchFilling` through the first full 14d merge. If a *completed*
run troughs under ~20 GiB, grow the disk — which is now a safe, isolated operation,
unlike every previous time this number was adjusted:

```sh
qm resize <vmid> scsi2 +50G          # on the PVE host
# then, in the guest, on the resolved device:
resize2fs /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2
```

## Order of operations

1. Attach the disk as `scsi2` with `discard=on,ssd=1`.
2. Rolling reboot so the guest sees the new device model — **not** `reboot.yml`,
   which hits all nine nodes at once with no drain or health gate:
   ```sh
   ansible-playbook update.yml --limit '<the three IPs>' \
     -e reboot=true -e reboot_needed=true
   ```
   `reboot_needed` is normally a `set_fact` from `/var/run/reboot-required`; passing
   it as an extra var forces the reboot, since `-e` outranks `set_fact`.
3. `ansible-playbook scratch-disk.yml` — formats, mounts, creates
   `thanos-compact/` owned `1001:1001`, writes the `.scratch-disk` marker.
4. Merge the Flux change. Do it in this order: `ThanosCompactScratchDiskMissing`
   fires (after 15m) while fewer than three mounts exist.

## The safety interlock

`hostPath` will happily write to whatever is behind the path, so the pod proves the
path is real before Thanos runs:

- The `data` volume is `type: Directory`, **not** `DirectoryOrCreate`.
  `DirectoryOrCreate` would have kubelet create the path root-owned (the compactor
  runs as 1001 and could not write to it) and, worse, create it on the OS root disk
  if the scratch disk were not mounted. A missing path should be a loud
  `FailedMount`.
- The `verify-scratch` init container refuses to start unless `.scratch-disk` is
  present. That marker is written *onto the scratch filesystem*, so it is visible
  only while that filesystem is mounted — which is what distinguishes "my dedicated
  disk is here" from "I am about to fill `/` through an empty mount point". It then
  wipes the data dir (so the 65GiB figure above is the whole story) and asserts at
  least 80GiB free.

Note that `fsGroup` does **not** apply to `hostPath` volumes, which is why the host
directory's `1001:1001` ownership is set by Ansible and must stay that way.

## Why the compactor being down is easy to miss

A halted compactor looks completely healthy: the pod stays `Running` with 0
restarts, because the halt only kills the compaction loop. Metadata-sync and
partial-upload-cleanup tickers keep running, so the logs show nothing but
`successfully synchronized block metadata` every minute. `thanos_compact_halted` is
the only reliable tell. Halting also stops **downsampling and retention**, not just
compaction, so the bucket grows and long-range dashboards get slower.

The compactor's own alerts (`ThanosCompactHalted`, `ThanosCompactIsDown`,
`ThanosCompactHasNotRun`) ship in the chart's `thanos-rules`. The filesystem
underneath is what `prometheusrule-thanos-scratch.yaml` adds.
