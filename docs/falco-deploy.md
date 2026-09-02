# Falco: deploying runtime security on the cluster

Falco watches syscalls on every node through an eBPF probe and matches them
against a ruleset. It is the answer to a question nothing else in this cluster
could answer: *what is a process actually doing inside a container right now?*

Everything security-related here up to this point has been perimeter work —
CrowdSec IP reputation and AppSec WAF in front of Traefik, Authentik forwardAuth,
PodSecurity `baseline` on the app namespaces, datastore NetworkPolicies. All of
it is about stopping an attacker getting in. None of it sees anything once they
are in. With Immich, Overseerr and Home Assistant genuinely reachable from the
internet — and HA's own login being the only auth boundary in front of it —
"attacker already has code execution in a pod" was the scenario with no coverage
at all.

Falco detects the things that happen *after* that point: a shell spawned in a
container, a read of `/etc/shadow` or `/root/.ssh`, a new binary dropped and
executed, a mount of the container runtime socket.

## Why the operator and not the `falco` Helm chart

Both are supported upstream and the plain chart (`falco` 9.1.0) is considerably
more mature. The operator was chosen for one reason: **rules and plugins become
CRs instead of Helm values.** A tuning change is a small YAML file with a
priority, reviewable in a PR, rather than an edit buried in a values block; rules
are pulled as versioned OCI artifacts; and per-node selectors are available if
this cluster ever stops being homogeneous.

That trade is real and it is not free. Versus the chart you give up:

- ServiceMonitor, PrometheusRule and Grafana dashboards (all hand-written here)
- `leastPrivileged` mode — the operator hardcodes `privileged: true`
- declarative resource limits in the chart's ergonomic form
- auto-wiring of Falco → falcosidekick (done by hand in `config.yaml`)
- namespace and PSA handling

And the operator is **v0.4.1 with v1alpha1 CRDs**. It has already shipped one
breaking API change. See *Upgrades* at the bottom.

## Prerequisites

- A **Discord webhook** for a dedicated Falco channel, stored in
  `discord-webhook.sops.yaml`. Already configured.
- Nothing else. No node changes, no kernel headers, no Ansible run, no reboot.

## What's in `kubernetes/infrastructure/controllers/falco/`

| File | Purpose |
| --- | --- |
| `namespace.yaml` | Namespace `falco`, PodSecurity `privileged` (set explicitly — see below) |
| `helmrepository.yaml` | `falcosecurity` chart repo, in `flux-system` |
| `helmrelease.yaml` | `falco-operator` 0.3.1 — the operator and its five CRDs, nothing else |
| `discord-webhook.sops.yaml` | SOPS/age Secret, seeded empty |
| `kustomization.yaml` | Applied by the `infrastructure` Flux Kustomization |
| `config/plugin-container.yaml` | `Plugin` — container metadata plugin **(not optional)** |
| `config/rulesfile-falco.yaml` | `Rulesfile` — the 25-rule stable ruleset **(not optional)** |
| `config/rulesfile-tuning.yaml` | `Rulesfile` — local exceptions, priority 50 (above the vendored 40) |
| `config/config.yaml` | `Config` — JSON to stdout, HTTP to falcosidekick |
| `config/falco.yaml` | `Falco` — the DaemonSet: tolerations, version, resources |
| `config/component-falcosidekick.yaml` | `Component` — falcosidekick + Discord env |
| `config/kustomization.yaml` | Applied by the **separate** `falco-config` Kustomization |

Monitoring lives with the rest of the monitoring config, not here:
`kubernetes/apps/monitoring/falco/` (2 ServiceMonitors, 2 dashboards) and
`kubernetes/apps/monitoring/kube-prometheus-stack/prometheusrule-falco.yaml`.

### Why `config/` is a separate Flux Kustomization

The CRs' CRDs are installed by the HelmRelease that sits in the same
`infrastructure` set. Applying both together makes the entire `infrastructure`
kustomization fail its dry-run with `no matches for kind "Falco"` until the
operator is up — and the operator is *in* that set, so it deadlocks.

`kubernetes/flux/cluster/falco-config.yaml` breaks the cycle: its own
Kustomization, `dependsOn: infrastructure`, `retryInterval: 2m`. Identical shape
and identical reason to `tailscale-connector.yaml`.

The Discord Secret is deliberately **not** in `config/`. It stays one level up so
that `infrastructure` — which already carries the SOPS decryption stanza —
creates it before the Component that references it.

> Adding a Flux Kustomization means adding its path to `TARGETS` in
> `.github/workflows/validate.yml`. That list is a hand-maintained mirror; miss it
> and the path is silently never validated. It fails open, not loudly.

## The two CRs you cannot skip

This is the operator's sharpest edge and the thing most likely to waste an
afternoon.

**The operator ships no rules and no plugins.** Its baked-in base config has
`plugins: []` and `load_plugins: []`. Unlike the Helm chart, nothing is wired up
for you. Deploy a `Falco` CR on its own and you get a DaemonSet that starts
cleanly, passes its health checks, reports `Ready`, and detects **essentially
nothing** — every `container.*` and `k8s.*` field evaluates empty, and the stable
ruleset declares `required_plugin_versions: [container >= 0.4.0]`.

Hence `plugin-container.yaml` and `rulesfile-falco.yaml`. A healthy-looking Falco
that silently sees nothing is exactly what `FalcoIngestionStalled` exists to
catch, but it is much better to just not build it that way.

## Driver: modern eBPF, and k3s needs no socket configuration

`engine.kind: modern_ebpf` is hardcoded by the operator for DaemonSet mode, and
it is the right choice here anyway. Every node is Ubuntu 24.04 on kernel 6.8, far
past the ~5.8 floor for BPF ring buffer and BTF. CO-RE means no kernel headers,
no DKMS, and — the argument that actually matters for this cluster — **a k3s
minor bump rolled by the system-upgrade-controller can never leave us with a
driver that will not rebuild.**

Note that Falco 0.44.0 *removed* the legacy `ebpf` probe (along with gVisor and
gRPC output); it is not merely deprecated. Falco refuses to start if stale
`engine.ebpf` / `gvisor` / `grpc` keys are present in config.

**The k3s containerd socket needs no configuration.** This is worth stating
because it is the obvious thing to go looking for. `/run/k3s/containerd/containerd.sock`
is already compiled into the container plugin's default CRI socket list, and the
operator already hostPath-mounts `/run/k3s/containerd` into the Falco pod
(`k3s-containerd-socket` → `/host/run/k3s/containerd/`, verified in
`internal/pkg/resources/falco.go`). If you ever *do* override the socket list,
write plain node paths — the plugin prepends `HOST_ROOT` itself, so a leading
`/host` breaks it.

## PodSecurity

The namespace is labelled `privileged` **explicitly**, which deviates from every
other controller namespace in this repo (they carry no PSA labels at all).

An unlabelled namespace is already privileged by default, so this changes
nothing operationally. It is there so that the one workload whose entire job is
detecting container escapes — and which does that by being the most privileged
thing in the cluster — says so in its own manifest, rather than relying on a
default that someone might later "tighten".

It genuinely cannot be `baseline`: the operator hardcodes `privileged: true` and
the DaemonSet hostPath-mounts `/proc`, `/dev`, `/boot`, `/etc`, `/usr`,
`/lib/modules` and the runtime sockets. `audit` and `warn` are pinned to
`privileged` too — left at their defaults they evaluate against `restricted` and
would annotate and warn on every pod admission despite admitting it.

## Resources, and why the limit is tight

The operator defaults to requests 100m/512Mi, limits 1000m/1024Mi. Both memory
figures are lowered here (256Mi / 512Mi) and the reason is the control planes:
they are 4Gi nodes sitting at 60–71 % memory, while the workers are 12Gi at
36–65 %. A DaemonSet has to fit the smallest node.

Observed Falco RSS with modern_ebpf is typically 100–300Mi; memory scales with
core count because there is one ring buffer per CPU, and these are 4-core nodes.

The 512Mi limit is a blast-radius decision as much as a thrift one. Upstream
issue #3733 (random memory spikes) is still open. On a control plane with ~1Gi
headroom, the correct outcome of a Falco memory spike is **Falco being
OOMKilled** — which `FalcoAgentDown` catches — and *not* node memory pressure
evicting etcd or kube-apiserver. Revisit from `kubectl top pods -n falco` after a
week of real data.

## Alerting: two paths, on purpose

**Detections → Discord.** Falco POSTs events to falcosidekick, which filters by
priority and forwards to a Discord webhook. This is the human-facing path.

**Health → Prometheus → Alertmanager → Discord.** The `prometheusrule-falco.yaml`
alerts fire on *Falco being broken*, never on detections. Same principle as
`prometheusrule-security.yaml`: a detection is the system working; a detector
that quietly stopped detecting is the emergency.

There is deliberately no alert on rule matches being high, and none on them being
zero either — zero matches is the normal healthy state of a cluster nobody is
attacking. The health signal is event *ingestion*, which is nonzero on every live
node at all times because it counts syscalls observed, not rules matched.

**Everything → Loki, for free.** `json_output: true` puts every event on Falco's
stdout, and Alloy already tails `/var/log/pods` on every node. The complete
unfiltered event stream is queryable in Grafana from the first minute with no
extra integration, no new config and no PVC. This is what makes the deliberately
quiet Discord threshold safe.

### Rotating or muting Discord

> **Status: the Discord path is MUTED as of 2026-09-01.** Both `Component`
> manifests have their `DISCORD_WEBHOOKURL` / `DISCORD_MINIMUMPRIORITY` env
> commented out — the feed was too noisy to be read, even with the syscall side
> pinned at `critical`. Detection is unaffected: rules still evaluate, events
> still reach Loki and Prometheus, and the `prometheusrule-falco.yaml` health
> alerts (a different path — Alertmanager, not falcosidekick) are still live.
> Re-enable by uncommenting, after tuning the noisy rules out.

falcosidekick enables its Discord output only when the webhook is non-empty.
Blanking the value is therefore a clean kill switch for the Discord path alone:
Falco keeps detecting, keeps writing JSON to stdout (and so to Loki), and keeps
exporting metrics — events just stop leaving the cluster. Useful during a noisy
incident, and much better than scaling falcosidekick to zero, which would make
Falco's `http_output` start failing and trip `FalcosidekickOutputErrors`.

```bash
sops set kubernetes/infrastructure/controllers/falco/discord-webhook.sops.yaml \
  '["stringData"]["webhook-url"]' '"https://discord.com/api/webhooks/..."'
```

Commit, let Flux reconcile, then restart falcosidekick to pick up the new env —
it reads the webhook from the environment at startup, so a Secret change alone
does nothing:

```bash
kubectl -n falco rollout restart deploy/falcosidekick
```

### The noise strategy: start quiet, then tune

`DISCORD_MINIMUMPRIORITY` starts at **`critical`**. Of the 25 stable rules exactly
3 are CRITICAL, so day-one Discord is a very narrow, very high-signal feed —
among them *Drop and execute new binary in container*, which is close to the
definition of post-exploitation.

This is not the end state. The plan is:

1. Run for 1–2 weeks. Watch what actually fires, in Grafana:
   `topk(20, sum by (rule_name) (falcosecurity_falco_rules_matches_total))`
2. For the rules that turn out to be benign here, add a **second `Rulesfile` CR**
   with a **higher priority** than `falco-rules` (higher = loaded later = wins),
   using `inlineRules`.
3. Only then lower `DISCORD_MINIMUMPRIORITY` to `warning` or `notice`.

The usual suspects in a cluster this operator-dense are *Contact K8S API Server
From Container* (Flux, CNPG, Longhorn, MariaDB, Tailscale, cert-manager and
CrowdSec all do this constantly and legitimately) and *Terminal shell in
container* (every `kubectl exec`).

Tune via the `user_known_*` hook macros, which every noisy stable rule ships
defaulting to `(never_true)` precisely so they can be overridden:

```yaml
- macro: user_known_contact_k8s_api_server_activities
  condition: (k8s.ns.name in (flux-system, cnpg-system, longhorn-system))
  override:
    condition: replace
```

Use `override:` — the older `append:` syntax is deprecated since Falco 0.36 and
is removed in 1.0.0. An appended `condition` must start with `and`/`or`, because
it is textual concatenation.

Doing this the other way round — open the firehose, then tune — is how a security
channel becomes a channel nobody reads.

#### Step 1, measured — and the result argues for moving on step 3

Over 24h this instance produced **33,733 events, of which zero were CRITICAL**:

| Rule | Priority | Rate | Reaches Discord at `critical`? |
| --- | --- | --- | --- |
| `Packet socket created in container` | Notice | **28,656/day** | no |
| `Redirect STDOUT/STDIN to Network Connection in Container` | Notice | ~2,987/day | no |
| `Contact K8S API Server From Container` | Notice | ~2,648/day | no |
| `Run shell untrusted` | Debug | ~480/day | no |
| `Read sensitive file untrusted` | Warning | ~144/day | no |

So today this instance **cannot alert on anything**, which is worth stating
plainly: it looks healthy, its metrics are green, and it is structurally silent.
That is the same trap the k8saudit instance was caught in before deployment (zero
CRITICAL rules in that ruleset), and it is the argument for step 3 rather than
leaving the threshold where it is indefinitely.

`Packet socket created in container` alone is ~85% of all events and is entirely
kube-vip broadcasting gratuitous ARP for the control-plane VIP — its actual job.
It appears on exactly one node at a time (whichever control plane holds the VIP
lease), which makes it look alarming in a per-node view. Exempted in
`config/rulesfile-tuning.yaml` via the empty `user_known_packet_socket_binaries`
list upstream ships for exactly this purpose. Any *other* binary opening a packet
socket, including on the same node, still fires.

Before lowering the threshold to `warning`, note the one Warning-level rule that
does fire: `Read sensitive file untrusted`, ~144/day, and in every observed case
it is host `systemd` reading `/etc/pam.d/*` while starting a unit
(`container_id=host`, `proc.exepath=/usr/lib/systemd/systemd-executor`) — benign,
and it needs its own exception first or the threshold change just moves the noise.

### What is deliberately not deployed

- **k8s-metacollector.** Adds owner metadata (deployment/replicaset/service). The
  container plugin already supplies `k8s.pod.name`, `k8s.ns.name`, `k8s.pod.uid`
  and `k8s.pod.labels` off the CRI socket, which is enough to identify what
  tripped a rule.
- **falcosidekick-ui.** Needs its own Redis with RediSearch (`redis-stack`, not
  the plain caches already running here) — another PVC against the Longhorn
  budget — and its auth is a single shared `admin:admin` string, which would make
  it the one thing in the cluster not behind Authentik. Loki gives search and
  retention over the same events, on infrastructure that is already backed up.
- **The `k8saudit` plugin.** No longer deferred — it is deployed as a *separate*
  Falco instance in the `falco-k8saudit` namespace, tailing the k3s API server
  audit log on the control planes. It is not part of this instance because the
  operator scopes rules and plugins by namespace, and because its ruleset contains
  no CRITICAL rules and so needs its own falcosidekick threshold. See
  [`docs/falco-k8saudit.md`](falco-k8saudit.md).
- **`falco-incubating-rules` / `falco-sandbox-rules`.** A further ~68 rules, and
  where most of Falco's noisy reputation actually comes from. Start narrow.

## Verify

```bash
# 1. Flux
flux get kustomizations | grep -E 'infrastructure|falco-config'
flux get hr -n falco

# 2. CRDs registered (expect 5)
kubectl get crd | grep falcosecurity

# 3. CRs accepted, and the DaemonSet on ALL 9 nodes (proves the toleration)
kubectl -n falco get falco,component,config,rulesfile,plugin
kubectl -n falco get ds falco

# 4. modern eBPF actually loaded — not a kmod fallback
kubectl -n falco logs ds/falco | grep -iE 'modern|ebpf|probe'

# 5. Rules and plugin actually loaded (the failure mode that looks healthy)
kubectl -n falco logs ds/falco | grep -iE 'loading rules|rules loaded|plugin'
```

**6. Metadata enrichment — the check that matters most.** Trigger a detection and
confirm the event carries pod/container fields:

```bash
kubectl run falco-test --rm -it --restart=Never --image=busybox -- cat /etc/shadow
kubectl -n falco logs ds/falco --tail=50 | grep -i shadow
```

Empty `k8s.pod.name` / `container.name` here means the container plugin did not
load. That is the single most likely misconfiguration in this deploy, and it is
invisible from pod health alone.

**7. Metrics:**

```bash
kubectl -n falco port-forward ds/falco 8765:8765 &
curl -s localhost:8765/metrics | grep -E 'scap_n_(evts|drops)_total|rules_matches'
```

Then confirm both Prometheus targets are `up` and check the `job` label really is
`falco` / `falcosidekick` — the operator derives the Service name from the CR
name, and Prometheus Operator derives `job` from the Service name. This is the
same `jobName` → `job` plumbing that bit the blackbox Probes.

**8. End-to-end Discord.** Only fires once the webhook is set. Note the busybox
test above is *Terminal shell in container*, which is NOTICE and therefore below
the `critical` threshold — either temporarily lower `DISCORD_MINIMUMPRIORITY` or
use a CRITICAL-priority rule to test the path.

**9. Memory on the constrained nodes**, over the first few days:

```bash
kubectl top pods -n falco
kubectl top nodes | grep control
```

## Upgrades

**The operator is pre-1.0 with `v1alpha1` CRDs.** Renovate has a `packageRule`
that labels these `type/operator-upgrade` and attaches a warning to the PR body.
Read the changelog; do not rubber-stamp.

CI will not protect you here. The falcosecurity CRD kinds are absent from the
datreeio catalog, so kubeconform reports them as `no schema, NOT validated` and
the build stays green regardless. A schema break surfaces as a stalled Flux
Kustomization *after* merge.

**The OCI artifact versions are not managed by Renovate.** The container plugin
and the ruleset live in CRD fields (`spec.ociArtifact.image.tag`), not `image:`
strings, so no manager sees them. Check them by hand when the bundled Falco
version moves — the reference is the `falco` chart's `containerEngine.pluginRef`:

```bash
helm show values falcosecurity/falco --version <ver> | grep -A2 pluginRef
```

Current pins: container plugin `0.7.1`, `falco-rules` `5.1.0`, Falco `0.44.1`.

### Known upstream bug: finalizer leak (#377, open)

The artifact operator adds a per-node finalizer
(`<kind>.artifact.falcosecurity.dev/finalizer-<nodeName>`) to each artifact CR and
**never removes it when a node is deleted**. With 9 static nodes this is a slow
burn, but **every Proxmox VM rebuild leaks one permanently**.

The consequence only bites on deletion: only the sidecar on node X can clear
`finalizer-<nodeX>`, so once a node is gone, `kubectl delete rulesfile` hangs in
`Terminating` forever. If that happens, patch the finalizers off by hand:

```bash
kubectl -n falco patch rulesfile falco-rules --type=merge -p '{"metadata":{"finalizers":[]}}'
```

## Rollback

Falco is purely observational — no admission webhook, no mutating anything, it
blocks nothing. Removing it cannot break a running workload.

Revert the PR. If Flux's prune leaves CRs stuck in `Terminating`, that is the
finalizer bug above; the intended teardown order is artifacts
(`configs`, `rulesfiles`, `plugins`) → instances (`components`, `falcos`) → the
Helm release → the namespace.
