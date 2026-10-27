# Updates: how they work

App updates **merge themselves when they're low-risk, and revert themselves when
they break**. Everything else, including every platform and Kubernetes update, waits
for you to merge it.

| Tier | Automerges | Rule (`renovate.json`) |
| --- | --- | --- |
| Stateless apps: HelmRelease chart/images under `kubernetes/apps` | minor, patch, digest, once the release is ≥ 3 days old | tier 1 |
| DB-backed apps: immich, paperless, gitea, n8n, tandoor, uptime-kuma, tracearr | **patch only** | DB-backed apps |
| authentik, technitium, bambustudio, monitoring platform (kube-prometheus-stack, loki, thanos, alloy, blackbox) | never | never automerge these apps |
| Home Assistant monthly releases (`YYYY.M`) | never (its patches do) | Home Assistant |
| Datastore images (redis, mariadb, postgres, ...), floating-tag digests, `app-template`, 0.x minors, majors | never | individual rules |
| Everything outside `kubernetes/apps`: infrastructure, **k3s / SUC Plans**, Flux, kube-vip, CI pins, ansible; raw manifests anywhere | never | doesn't match tier 1 |

An automerge has three safety nets:

1. **Before the merge:** the [automerge gate](#the-automerge-gate) re-checks the PR and
   reads the release notes. Anything that looks like it needs planning gets
   `needs-planning` and waits for you.
2. **During the rollout:** Helm waits for the pods and rolls back if they never become
   Ready.
3. **After the rollout:** the rollout-guard soak check watches the release for 45m.
   Either failure triggers the [automatic revert](#automatic-revert-rollout-revert).

Kill switches: `gh variable set AUTOMERGE_ENABLED --body false` stops every
automerge, and `gh variable set ROLLOUT_REVERT_MODE --body dry-run` (or `off`) stops
reverts from merging. The soak check is stopped by `suspend: true` in
`kubernetes/infrastructure/controllers/rollout-guard/cronjob.yaml`.

## The flow

1. **Everything is pinned to an exact version** — Helm chart versions in each
   `HelmRelease` (`spec.chart.spec.version`) and container image tags in the
   bjw-s `values.*.image.tag` fields. No floating ranges, no `latest`.
2. **[Renovate](https://docs.renovatebot.com/)** (Mend-hosted GitHub App) scans the repo on a
   weekly schedule and opens **one PR per available update**. Config: [`renovate.json`](../renovate.json).
3. **Low-risk app updates merge themselves** once the required checks pass,
   including the automerge gate (tiers above). **Everything else waits for you to
   merge it**, and merging is the approval. Flux then reconciles `main` and applies
   the change within ~30m.
4. **Awareness** = the **"Renovate Dependency Dashboard"** GitHub issue (a live list
   of every pending update), `#git-prs` for PRs and merges (including automerges
   and reverts), and `#flux-deploys` for what actually rolled out or failed.

### One-time setup (manual)

Install the Renovate app on the repo at <https://github.com/apps/renovate>, grant it
`calebbutcher/home-ops`, and merge the onboarding ("Configure Renovate") PR it opens.

### Automatic revert (rollout-revert)

When an **automerged** app update fails to roll out, the cluster reports it and
GitHub reverts it. Updates you merge yourself are never auto-reverted.

```text
helm-controller: "Helm upgrade failed ..."     (pods never Ready; Helm already rolled back)
rollout-guard:   "Soak check failed ..."       (Ready, then crashed / OOMed / probe failing)
        │  Flux Alert `rollout-revert` (app namespaces, those two messages only)
        ▼  Provider `github-dispatch` → repository_dispatch "HelmRelease/<name>.<ns>"
.github/workflows/rollout-revert.yml
        │  newest change to that app's directory in 24h — automerged Renovate PR?
        ▼  yes → branch revert/pr-N: git revert + quarantine rule → PR (auto-merges in live mode)
Flux applies the revert → the HelmRelease's failure count resets → app back on the old version
```

- **Eligible:** the newest first-parent commit touching the HelmRelease's directory
  in the last 24h is the merge of a Renovate PR labelled `automerge` and merged by
  `renovate[bot]`. If you changed the app after the automerge, nothing happens. A
  grouped PR is reverted as a whole.
- **Quarantine:** the revert PR also adds a rule per dependency/version to
  [`.github/renovate/quarantine.json`](../.github/renovate/quarantine.json). The
  automerge gate then blocks that exact version, so it comes back as a manual PR.
  Newer versions can still automerge. To retry the version, delete its rule.
- **DB-backed apps after a soak failure:** the revert PR opens but does **not**
  auto-merge. The new version ran and may have migrated the database, so a human
  should decide whether downgrading is safe. A Helm-wait failure always auto-merges:
  Helm has already rolled the cluster back, so the revert only brings git in line.
- **No loops, no pile-ups:** one revert per PR, however many events arrive. Helm
  retries send up to 4. If the reverted version also fails, the newest change is now
  the revert, which isn't an automerge, so nothing more happens. `#flux-deploys`
  shows the failure, and that's the point to step in.
- **Every run writes its decision to the job summary**, including "no action"
  outcomes (Actions → rollout-revert).

**Setup** (once):

1. Create the cluster's dispatch token: a fine-grained PAT named
   `home-ops-cluster-dispatch`, repository access *only* `calebbutcher/home-ops`,
   **Contents: read and write** (repository_dispatch requires it), 1-year expiry. Put
   it in `kubernetes/infrastructure/configs/github-dispatch-token.yaml` (gitignored
   template), then run
   `sops --encrypt github-dispatch-token.yaml > github-dispatch-token.sops.yaml`.
2. Create the workflow's token: a fine-grained PAT named `home-ops-rollout-revert`,
   same repo, **Contents + Pull requests: read and write**. Then run
   `gh secret set ROLLOUT_REVERT_TOKEN`. It has to be a PAT: PRs pushed with
   `GITHUB_TOKEN` don't trigger the required checks, so auto-merge would hang.
3. `gh variable set ROLLOUT_REVERT_MODE --body dry-run`. Switch it to `live` after the
   drills. `off` disables reverts. `gh variable set ROLLOUT_DRILL --body true` while
   drilling.
4. Calendar both PATs' expiry. An expired token fails silently.

**Drill / re-run by hand:**
`gh workflow run rollout-revert -f namespace=tools -f name=it-tools -f message="Helm upgrade failed for release tools/it-tools ..."`

### Seerr note

`seerr/seerr` publishes only a moving `latest` tag (no semver releases), so it is
pinned by **immutable digest** (`tag: latest@sha256:...`). Renovate's `pinDigests`
opens a PR whenever that digest changes.

## The automerge gate

`.github/workflows/automerge-gate.yml` runs a check called **`automerge gate`** on
every PR, and the `main` ruleset requires it. It only has an opinion about Renovate
PRs that Renovate has marked for automerge. Every other PR (yours, rollout reverts,
manual Renovate PRs) passes in seconds.

Renovate's `packageRules` decide what is *eligible* to automerge. The gate is the
second opinion, and the only thing that reads the release notes. It **fails**, which
blocks GitHub auto-merge, when:

- any changed file is not a `helmrelease*.yaml` under `kubernetes/apps/`. Raw
  manifests get no Helm rollback and can't be auto-reverted.
- the file belongs to a never-automerge app (authentik, technitium, bambustudio, the
  monitoring platform).
- a DB-backed app (immich, paperless, gitea, n8n, tandoor, uptime-kuma, tracearr) gets
  anything other than a patch.
- the update is a major, or a minor of a `0.x` version.
- the dependency and version are quarantined (`.github/renovate/quarantine.json` on
  `main`, or the `quarantined` label). That means rollout-revert already had to roll
  this exact version back once.
- the release notes contain breaking-change wording ("breaking", "migration
  required", "action required", "removed config", "database migration", ...).
- the repo variable `AUTOMERGE_ENABLED` is `false` (the kill switch).

On a failure it adds `needs-planning` and leaves one sticky comment listing the
reasons and the matching release-note lines. **To proceed:** read the notes, then
either merge by hand or add the **`gate-approved`** label. The label re-runs the gate,
it passes, and auto-merge finishes.

Test it against any PR without touching it:

```sh
GITHUB_TOKEN=$(gh auth token) python3 .github/scripts/automerge-gate.py --pr 536 --dry-run --as-automerge
```

`--as-automerge` evaluates the PR as if Renovate had marked it, which is useful for
checking the gate against old PRs.

### One-time GitHub setup

```sh
# Labels the gate, Renovate and rollout-revert use
for l in automerge:0e8a16 needs-planning:d93f0b quarantined:b60205 \
         gate-approved:5319e7 revert:b60205 rollout-drill:c5def5; do
  gh label create "${l%%:*}" --color "${l##*:}" --force
done

# Let GitHub auto-merge PRs (Renovate's platformAutomerge), and tidy merged branches
gh api -X PATCH repos/calebbutcher/home-ops -F allow_auto_merge=true -F delete_branch_on_merge=true
gh variable set AUTOMERGE_ENABLED --body true

# Ruleset: require the checks on main. Apply AFTER `automerge gate` has run on at
# least one PR, so GitHub knows the check name.
gh api -X POST repos/calebbutcher/home-ops/rulesets --input .github/rulesets/main.json
```

**Required checks are what make auto-merge safe.** On a branch with no required
checks, GitHub auto-merge merges as soon as it is enabled, before CI has run. The
ruleset ([`.github/rulesets/main.json`](../.github/rulesets/main.json)) requires
the three `validate` checks plus `automerge gate`, and pins each to the GitHub
Actions app (id 15368) so nothing else can post a passing status under the same
name.

Other settings in the ruleset:

- **`strict: false`.** With `rebaseWhen: conflicted`, Renovate PRs are often behind
  `main`, and `strict` would stop them merging.
- **A PR is required for every change to `main`**, matching how this repo already
  works.
- **Admin bypass is `pull_request` mode, not `always`.** You can tick "bypass" when
  merging a PR, but nothing can push straight to `main`. That includes the cluster's
  dispatch token.

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

**Currently held on 1.35.** `renovate.json` caps `k3s-io/k3s` at `v1.35.x` with
`allowedVersions`, so only patch PRs open, and caps the `alpine/k8s` kubectl image at 1.36.x
(kubectl's +/-1 skew). To take the next minor, raise both caps in the same PR.

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

## Notifications

Discord is the notification sink, one channel per source:

| Channel | Source | Configured in |
| --- | --- | --- |
| `#flux-deploys` | Flux events — Kustomization applies, HelmRelease upgrades, **failed upgrades and rollbacks** | `kubernetes/infrastructure/configs/flux-discord-{provider,alert}.yaml` |
| `#cluster-alerts` | Alertmanager (incl. `FluxHelmReleaseNotReady`) | `kubernetes/apps/monitoring/kube-prometheus-stack/alertmanagerconfig.yaml` |
| `#git-prs` | GitHub PRs and merges (incl. Renovate) | GitHub repo Settings → Webhooks |

**Flux Alerts need one `eventSources` entry per HelmRelease namespace.**
notification-controller has no namespace wildcard — an entry without `namespace:`
means the Alert's own namespace (`flux-system`), which holds no HelmReleases. When you
add an app in a new namespace, add a line to `flux-discord-alert.yaml`; CI
(`.github/scripts/check-alert-coverage.py`) fails the PR until you do.
