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
This is separate from the Ansible `k3s_version` pin (which is only the *fresh-install /
node-join* baseline) and from Renovate (which does not touch k3s).

**How it works.** Two `Plan` CRs (`k3s-server`, `k3s-agent`) declare a target `version`.
SUC cordons → swaps the k3s binary via a per-node Job → uncordons, **one node at a
time** (`concurrency: 1`). The agent Plan's `prepare` step blocks on the server Plan,
so **control-plane upgrades fully before any worker**.

**Both Plans are cordon-only (no drain) — on purpose.** Every worker hosts
single-instance CloudNativePG clusters on node-local `local-path` storage, whose
`-primary` PodDisruptionBudget allows **0** disruptions. A drain can therefore never
evict them (no replica to fail over to) and `kubectl drain` deadlocks forever; and
because the storage is node-local the DB can only come back on the *same* node, so
draining buys nothing. k3s's embedded containerd keeps pods running across the binary
swap (only a brief blip). If the Postgres clusters are ever moved to HA
(`instances: 3`) or replicated storage, draining can be re-enabled (add `drain:` back
to the agent Plan, plus `deleteEmptyDirData: true`).

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
