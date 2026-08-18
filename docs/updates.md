# Updates: how they work

This cluster is **approve-then-apply**. Nothing upgrades on its own.

## The flow

1. **Everything is pinned to an exact version** — Helm chart versions in each
   `HelmRelease` (`spec.chart.spec.version`) and container image tags in the
   bjw-s `values.*.image.tag` fields. No floating ranges, no `latest`.
2. **[Renovate](https://docs.renovatebot.com/)** (Mend-hosted GitHub App) scans the repo on a
   weekly schedule and opens **one PR per available update**. Config: [`renovate.json`](../renovate.json).
3. **You approve by merging the PR.** Flux then reconciles `main` and applies the
   change to the cluster within ~30m.
4. **Awareness** = the **"Renovate Dependency Dashboard"** GitHub issue (a live list
   of every pending update) plus GitHub's normal PR notifications. Nothing is set
   to auto-merge.

### One-time setup (manual)

Install the Renovate app on the repo at <https://github.com/apps/renovate>, grant it
`calebbutcher/home-ops`, and merge the onboarding ("Configure Renovate") PR it opens.

### Seerr note

`seerr/seerr` publishes only a moving `latest` tag (no semver releases), so it is
pinned by **immutable digest** (`tag: latest@sha256:...`). Renovate's `pinDigests`
opens a PR whenever that digest changes.

## k3s version upgrades (System Upgrade Controller)

The **k3s version itself** (Kubernetes version) is upgraded in-cluster by the
[System Upgrade Controller](https://docs.k3s.io/upgrades/automated) (SUC), deployed at
[`kubernetes/infrastructure/controllers/system-upgrade-controller/`](../kubernetes/infrastructure/controllers/system-upgrade-controller/).
This is separate from the Ansible `k3s_version` pin, which is only the *fresh-install /
node-join* baseline and is inert until the play is re-run.

**Renovate does surface k3s** — `renovate.json` has a `customManagers` entry covering
both the SUC Plans and the ansible inventory, and a `k3s-io/k3s` rule with
`separateMultipleMinor` so each minor stream arrives as its own PR. That is deliberate:
k3s supports only +1 minor of skew, so 1.32 → 1.35 must be walked one minor at a time,
and four separate PRs is exactly that walk. **Merging one of those PRs upgrades the live
cluster** — see the warning Renovate puts in the PR body.

**How it works.** Two `Plan` CRs (`k3s-server`, `k3s-agent`) declare a target `version`.
SUC cordons → swaps the k3s binary via a per-node Job → uncordons, **one node at a
time** (`concurrency: 1`). The agent Plan's `prepare` step blocks on the server Plan,
so **control-plane upgrades fully before any worker**.

**Both Plans are cordon-only (no drain) — on purpose.** A worker drain deadlocks
against Longhorn. Longhorn's `node-drain-policy` is `block-if-contains-last-replica`,
enforced via a PodDisruptionBudget (`minAvailable: 1`) over each node's single
`instance-manager` pod. Every worker holds the last healthy replica of at least one
`longhorn-single` volume, so every one of those PDBs sits at **0** allowed disruptions
— it survives a cordon, and a dry-run eviction returns `429 TooManyRequests: Cannot
evict pod as it would violate the pod's disruption budget`. That pod is owned by an
`InstanceManager` CR rather than a DaemonSet, so `ignoreDaemonSets` does not skip it,
and `force: true` only permits *including* unmanaged pods — it does not bypass PDBs.
`kubectl drain` therefore blocks forever on the first worker, and `concurrency: 1`
stalls the rest behind it.

A drain was briefly enabled (`e8993e6`, when CNPG went HA) and removed again before it
ever ran — that commit predates the Longhorn migration. It costs little: the drain
already excluded CNPG pods, and `longhorn-single` volumes are node-pinned by design, so
draining cannot relocate their workloads anyway. k3s's embedded containerd keeps the
shims (and their containers) alive across the binary swap — a brief kubelet gap, not a
stop/start.

If drain is ever genuinely needed: exclude instance-manager from the drain
`podSelector` (`longhorn.io/component NotIn [instance-manager]`), or set
node-drain-policy to `block-for-eviction-if-contains-last-replica` and accept a full
replica rebuild per node. **Never** `always-allow` — CNPG pods are excluded from the
drain and keep running, so evicting instance-manager underneath them pulls storage out
from under a live database.

**Nothing upgrades until you opt a node in.** Both Plans are gated on a node label, so
merging only installs the controller:

```sh
# 1. (Recommended) take a fresh etcd snapshot first — instant rollback if a
#    control-plane node goes bad. See docs/backup-recovery.md.
# 2. Arm ONE control-plane node, watch it go NotReady→Ready on the new version:
kubectl label node <control-plane-node> k3s-upgrade=true
kubectl -n system-upgrade get jobs,plans -w
kubectl get nodes -o wide          # confirm the new version, node Ready
# 3. Arm the other two control-plane nodes (SUC still does them one at a time):
kubectl label node <cp-2> <cp-3> k3s-upgrade=true
# 4. Then arm the workers (they wait for the control plane automatically):
kubectl label node <worker-1> ... k3s-upgrade=true
```

**One minor at a time.** k3s/Kubernetes only support a +1 minor version skew. The Plans
start at `v1.31.14+k3s1` (first hop from the cluster's `v1.30.2+k3s2`). Once **every** node
is on 1.31, bump `.spec.version` in *both* `plans/*.yaml` to the latest `v1.32.x`, commit,
let Flux reconcile — already-labelled nodes roll automatically — verify, then repeat up to
the current release. **Never skip a minor.** Keep the Ansible `k3s_version`
(`ansible/inventory/my-cluster/group_vars/all/main.yml`) roughly in sync so freshly-joined
nodes don't land far behind.

**Rollback / stop.** Remove the label from un-upgraded nodes to halt further rollout
(`kubectl label node <name> k3s-upgrade-`). Nodes already upgraded stay upgraded — recover
those from the etcd snapshot if needed. The controller only bundles CoreDNS / metrics-server
/ local-path here (Traefik and ServiceLB are `--disable`d), so the upgrade surface is small.

## OS package updates and node reboots (Ansible)

Distro packages are a separate track from everything above — Renovate does not see
them, and SUC only swaps the k3s binary. They are handled by
[`ansible/update.yml`](../ansible/update.yml), which does an apt/dnf upgrade on every
host and optionally reboots the ones that ask for it.

```sh
cd ansible
ansible-playbook update.yml                        # update only, never reboots
ansible-playbook update.yml -e reboot=true         # update + safe rolling reboot
ansible-playbook update.yml -e reboot=true --limit node   # workers only
```

**Reboots are drained and gated.** `-e reboot=true` takes each host out of service
properly rather than rebooting it underneath its workloads:

| Group | Sequence |
| --- | --- |
| `node` (workers) | cordon → **drain** → reboot → wait `Ready` → uncordon → wait for Longhorn to settle |
| `master` | cordon → reboot → wait `Ready` **and** `EtcdIsVoter=True` → uncordon (no drain) |
| `standalone_vms` | reboot → wait for the Technitium web service → confirm it answers DNS |

Hosts are still done one at a time (`serial: 1`), but the post-reboot gates are the
real change: the play previously advanced as soon as SSH answered, which is neither
"node Ready" nor "storage rebuilt". On the `master` play that was a latent
quorum-loss risk — nothing stopped the second etcd member rebooting while the first
was still rejoining. `any_errors_fatal: true` now halts the roll on the first
failure instead of marching through the rest of the nodes.

A `run_once` pre-flight refuses to start if any node is NotReady or any attached
Longhorn volume is degraded (`-e skip_preflight=true` to override).

**The drain needs a pod selector, and always will.** A plain `kubectl drain` blocks
forever here, for the same Longhorn reason documented above — plus CNPG. Two sets of
PDBs sit permanently at 0 allowed disruptions: every worker's `instance-manager` pod,
and every `<cluster>-primary`. Both are excluded:

```text
--pod-selector='longhorn.io/component!=instance-manager,!cnpg.io/cluster'
```

In a Kubernetes label selector `key!=value` also matches objects lacking the key, so
this still covers every ordinary pod. Verify the exclusion is doing its job with a
server-side dry run — it needs no cordon and changes nothing:

```sh
kubectl drain <node> --dry-run=server --ignore-daemonsets --delete-emptydir-data \
  --force --pod-selector='longhorn.io/component!=instance-manager,!cnpg.io/cluster'
# ends "node/<node> drained (server dry run)"
# drop --pod-selector and it fails on instance-manager with a PDB timeout instead
```

Excluding CNPG is deliberate beyond unblocking the drain: forcing a switchover on a
busy database re-triggers [#828](cnpg-ha.md#known-issue-wal-archiving-stuck-after-a-busy-switchover-828),
and CNPG already fails over correctly on hard node loss. Its pods ride the reboot.

**What draining does and does not buy.** It relocates anything that can move before
the reboot — the 2-replica tier (authentik, Alertmanager, Tailscale Connector,
CoreDNS) and the 2-replica `longhorn` volumes — turning a ~5–7 minute outage into
roughly none. It does **not** help workloads whose data cannot move: `local-path`
PVCs (Prometheus TSDB, Loki, Alertmanager, uptime-kuma, paperless), `longhorn-single`
volumes whose only replica is on that node, and `strategy: Recreate` singletons.
Those are down for the reboot window either way, though they now get a clean
`SIGTERM` instead of a hard kill. Shortening *their* downtime is a storage/replica
problem, not a drain problem.

**Escape hatches.** `-e drain=false` reverts to cordon-only. If a run aborts, the
node is deliberately left **cordoned** — `kubectl uncordon <node>` once it is healthy.
Timeouts are all overridable: `drain_timeout` (300s), `reboot_timeout` (600s),
`node_ready_timeout` (600s), `etcd_ready_timeout` (600s), `storage_settle_timeout`
(900s).

Kubernetes calls run from the Ansible controller (`delegate_to: localhost`), so this
needs the same working kubeconfig `kubectl` uses.

## Follow-on: Discord notifications (not yet enabled)

GitHub already notifies on PRs and the Dependency Dashboard. To *also* push Flux
events (reconcile success/failure, applied upgrades) to a Discord channel, the
notification-controller is already installed — this is purely additive:

1. Create a Discord channel webhook (Channel → Integrations → Webhooks).
2. Store the webhook URL as a SOPS-encrypted Secret (`.sops.yaml` already covers
   `kubernetes/`), e.g. `kubernetes/flux/cluster/flux-system/discord-webhook.sops.yaml`.
3. Add a Flux `Provider` (type `discord`, `secretRef` → the webhook secret) and an
   `Alert` selecting the resources to report on (e.g. all `HelmRelease` and
   `Kustomization` events at `info` level). Reference:
   <https://fluxcd.io/flux/monitoring/alerts/>
4. Add both manifests to the `flux-system` kustomization and commit.
