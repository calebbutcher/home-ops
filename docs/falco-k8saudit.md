# Falco: Kubernetes API audit logging (`k8saudit`)

The second half of the Falco deployment. [`docs/falco-deploy.md`](falco-deploy.md)
covers the syscall instance — what processes *do* on the nine nodes. This covers
what identities *ask the API server to do*: exec into a pod, create a privileged
container, bind a ClusterRole, read a Secret, attach an ephemeral container.

The two see genuinely different things. A `kubectl exec` into a pod shows up here
as an API request with a user identity attached, and on the syscall side as a shell
process with no idea who asked for it. Neither is a substitute for the other.

> **This is not the same thing as pod metadata enrichment.** The syscall instance
> already labels its events with `k8s.pod.name` / `k8s.ns.name` via the `container`
> plugin reading the CRI socket. The upstream chart calls this out explicitly
> because people deploy `k8saudit` expecting enrichment and get a control-plane
> audit trail instead. Enrichment was already working before this existed.

## Two halves, and the order matters

Unlike everything else in this repo, this is **not** purely GitOps. Nothing in the
cluster writes an API audit log by default — k3s ships with auditing off — so
there is a node-level change on the control planes that must land **first**.

```text
1. ansible-playbook k3s-audit.yml     ← enables audit logging on the 3 control planes
2. merge the PR                       ← Flux deploys Falco to consume it
```

Do it in the other order and the `falco-k8saudit` pods sit in `ContainerCreating`
with a `hostPath type check failed` event until the play runs. That is deliberate:
the hostPath is declared `type: Directory` rather than `DirectoryOrCreate`
specifically so the precondition failure names itself, instead of kubelet
manufacturing an empty directory and leaving Falco to crash-loop on a missing file.

## Why file-tailing and not the webhook

The upstream chart documents a different topology: a Falco **Deployment** with a
**NodePort on 9765**, and the API server POSTing audit events to it. This deploys
a **DaemonSet on the three control planes**, each tailing its own local audit log.

| | File tail (chosen) | Webhook (upstream default) |
| --- | --- | --- |
| Attack surface | none — no listening socket | an unauthenticated endpoint that accepts audit events |
| Event loss on Falco restart | none, the file persists | dropped by the API server |
| Control-plane RAM | ~130-180 Mi × 3 | zero |
| apiserver-critical files | 1 (the policy) | 2 (policy + webhook config) |

The first row was decisive. The chart's reference NodePort takes unauthenticated
POSTs, which means anything that can reach a node port can **forge audit events**
and fabricate Falco alerts. A security control whose evidence an attacker can write
is worth less than no control, because it is trusted.

The second row matters nearly as much: with a webhook, audit events produced while
the Falco pod is restarting are dropped by the API server and are simply gone. The
on-disk log is a durable buffer, and the plugin's `file://` scheme resumes from it
and handles rotation.

The cost is real and paid on the tightest nodes in the cluster — the control planes
are 4 GB VMs. That is why the audit policy is scoped rather than upstream's, and why
the memory limit is 256 Mi.

> `file://` is a supported production path but a **less-trodden** one; the plugin
> README calls the webhook "the expected way" while documenting `file://` as
> "useful for reading audit logs written to disk by the API server". Note the
> scheme is load-bearing: a **bare path** reads the file once and stops, which
> would produce an instance that ingests whatever was in the file at startup and
> then goes quiet while still reporting healthy.

## Why a second namespace and a second falcosidekick

Not tidiness — both are forced.

**The namespace is the only isolation boundary the operator has.** `Config`,
`Rulesfile` and `Plugin` CRs are reconciled by an `artifact-operator` sidecar
running *inside each Falco pod*, scoped by `POD_NAMESPACE` and `NODE_NAME`. There
is no "which instance owns this artifact" field — `spec.selector` selects **nodes**,
not instances. A `k8saudit` Plugin CR created in the `falco` namespace would be
loaded by all nine syscall pods.

**The sidekick is forced by priorities.** `DISCORD_MINIMUMPRIORITY` is per
falcosidekick, and Falco has a single `http_output` URL, so one sidekick cannot
hold two thresholds. This matters more than it sounds:

> **Not one of the 48 rules in `k8saudit-rules` is CRITICAL.** They are 21 WARNING,
> 20 INFO, 4 NOTICE, 2 ERROR, 1 DEBUG. Routing them through the syscall sidekick —
> pinned at `critical` because the default syscall rules are noisy — would have
> produced a k8saudit deployment that alerted on **nothing at all**, while looking
> completely healthy.

So this namespace runs at `warning` while syscalls stay at `critical`. Both post to
the same Discord channel; events from here carry `source:k8saudit` via
falcosidekick's `CUSTOMFIELDS` so the two are distinguishable.

## The audit policy

[`ansible/templates/k3s-audit-policy.yaml.j2`](../ansible/templates/k3s-audit-policy.yaml.j2).
Derived from what the ruleset actually reads, not copied from upstream.

Upstream's policy ends in a catch-all `level: Metadata`, which audits **every**
request — including the lease renewals kube-vip, CNPG, Longhorn, cert-manager and
Flux generate several times a second. On 4 GB control planes that is a large volume
of disk writes and of JSON for Falco to parse, for no detection benefit.

Across its 48 rules the ruleset only ever references the verbs
`create`/`update`/`patch`/`delete` (plus `get`, for secret reads specifically) and
13 resource types. **Nothing references `watch` or `list`** — which is where the
bulk of API traffic lives. So the policy drops those outright.

Two properties are load-bearing:

- **Secrets are logged at `Metadata` and never above, and that rule is first.**
  At `Request` or `RequestResponse` the audit log would contain the decoded body of
  every Secret written to the cluster — a plaintext copy of every credential, on
  control-plane disk, readable by anything that mounts the path. Metadata still
  carries name/namespace/user/verb, which is all the secret rules need.
- **The final rule keeps every *mutating* request at `Metadata`.** Four of the 48
  rules have no resource filter (`Disallowed K8s User`, `Full K8s Administrative
  Access`, `port-forward`, `All K8s Audit Events`). `port-forward` is recovered via
  the explicit pods-subresources rule and `All K8s Audit Events` is a DEBUG
  passthrough, but the two identity rules match on *any* request. Keeping writes is
  cheap — they are a small fraction of traffic — and preserves them.

**Known coverage gap:** a *read* by an unexpected identity is the one thing this
policy will not see. Widening the last rule's verb filter would restore it at the
cost of reinstating the firehose. Not worth it here.

### Grafana dashboards dominate the volume

Measured on the live cluster over the first ~9 minutes:

| | |
| --- | --- |
| Total audit volume | 17.4 MB / 3,606 events |
| **`configmaps` in `monitoring`** | **10.3 MB — 59.3%, from only 100 events** |
| Largest single event | 523 KB |
| Events over the plugin's 256 KB `maxEventSize` | 7 — **all of them monitoring ConfigMaps** |

Vendored Grafana dashboards are hundreds of KB each and kustomize-controller
rewrites them on every reconcile. They were both the majority of the volume *and*
100% of the events the plugin could not read — each producing `bufio.Scanner: token
too long` and a silently dropped event.

Dropping them to `Metadata` removes ~60% of the volume and takes the largest
remaining line from 523 KB to **74 KB**, comfortably inside the default, so nothing
is discarded. The precise cost: `Create/Modify Configmap With Private Credentials`
reads the ConfigMap body, so it no longer applies to the `monitoring` namespace.
These are vendored dashboards and generated rulefiles; Grafana's real credentials
are Secrets and unaffected. The rule still covers every other namespace.

> Changing the policy means **re-running the playbook**, which restarts each API
> server again — `--audit-policy-file` is read only at kube-apiserver startup.

## Files

| Path | Purpose |
| --- | --- |
| [`ansible/k3s-audit.yml`](../ansible/k3s-audit.yml) | Enables/disables audit logging, rolling, one control plane at a time |
| [`ansible/templates/k3s-audit-policy.yaml.j2`](../ansible/templates/k3s-audit-policy.yaml.j2) | The scoped policy |
| `.../falco-k8saudit/namespace.yaml` | Namespace, PSA `privileged` |
| `.../falco-k8saudit/discord-webhook.sops.yaml` | Same webhook value as the `falco` copy — Secrets do not cross namespaces |
| `.../falco-k8saudit/config/falco.yaml` | The instance: DaemonSet, control planes only, `privileged: false` |
| `.../falco-k8saudit/config/config.yaml` | `engine.kind: nodriver`, JSON to stdout, output to this namespace's sidekick |
| `.../falco-k8saudit/config/plugin-k8saudit.yaml` | Event source, `file://` open params |
| `.../falco-k8saudit/config/plugin-json.yaml` | **Mandatory** — supplies the `jevt.*` fields the rules use |
| `.../falco-k8saudit/config/rulesfile-k8saudit.yaml` | The 48 rules |
| `.../falco-k8saudit/config/component-falcosidekick.yaml` | Own sidekick at `warning` |
| [`kubernetes/flux/cluster/falco-k8saudit-config.yaml`](../kubernetes/flux/cluster/falco-k8saudit-config.yaml) | Separate Kustomization (CRD-ordering deadlock) |

### Two paths that are easy to get wrong

- The ruleset is at **`falcosecurity/plugins/ruleset/k8saudit`**, not
  `falcosecurity/rules/k8saudit-rules`. Plugin rulesets live under the *plugins*
  repo, unlike the syscall ruleset at `falcosecurity/rules/falco-rules`. Guessing by
  analogy gives a repository that does not exist.
- The `json` plugin is **not optional**. `k8saudit-rules` uses `jevt.value[...]` in
  enabled rules, and `jevt.*` are the *json* plugin's fields (aliases for `json.*`),
  not k8saudit's. Without it Falco fails to load the ruleset at startup, on all
  three control planes at once.

### Two crash-loops this hit on first deploy

Both were self-inflicted and both are worth knowing, because neither error names its
actual cause.

**`Error: bad file: /etc/falco/config.d/60-…-inline.yaml`** — caused by adding
`capabilities: drop: ["ALL"]` to the Falco container as an apparently free hardening
win. The artifact-operator sidecar writes the generated config and rules files as
`nonroot:nonroot` mode `0600`, while Falco runs as **uid 0**. Root reads another
user's `0600` file only via `CAP_DAC_OVERRIDE`, which `drop: ALL` removes. The
artifacts still report `PROGRAMMED` — the sidecar wrote them perfectly well — so this
presents as Falco crash-looping on a file that visibly exists and is visibly correct.

`privileged: false` is the override that matters and is safe; do not tighten further.

**falcosidekick panics: `duplicate label names in constant and variable labels`** —
caused by `CUSTOMFIELDS: "source:k8saudit"`. Custom fields become Prometheus *variable
label names*, and falcosidekick already emits `source` as a built-in label on
`falcosecurity_falcosidekick_falco_events_total`. The collision is fatal at startup.
Avoid all of: `hostname`, `rule`, `priority`, `priority_raw`, `source`, `k8s_ns_name`,
`k8s_pod_name`. This deployment uses `detector:k8saudit`.

Neither is caught by any pre-merge check — both are runtime behaviours of the
container, not schema or manifest problems. `kubectl apply --server-side --dry-run`
validates them happily.

## Deploy

```bash
# 1. Enable auditing on the control planes. Restarts the API server on each node
#    one at a time, gated on Ready AND EtcdIsVoter before moving to the next.
#    Expect the kube-vip VIP to refuse connections for ~20s per node.
cd ansible && ansible-playbook k3s-audit.yml

# 2. Confirm each control plane is writing events before merging anything
for n in 10.2.169.30 10.2.169.31 10.2.169.32; do
  ssh $n 'sudo ls -l /var/log/k3s-audit/audit.log'
done

# 3. Merge the PR; Flux does the rest
flux get kustomizations falco-k8saudit-config
```

## Verify

```bash
# 3 pods, control planes only
kubectl -n falco-k8saudit get pods -o wide

# Artifacts accepted
kubectl -n falco-k8saudit get plugin,rulesfile,config

# The plugin actually opened the FILE (not a webhook, not a one-shot read)
kubectl -n falco-k8saudit logs ds/falco | grep -iE "k8saudit|json|nodriver|Opening"

# Metrics — note the job label is forced by relabeling, not derived
kubectl get --raw "/api/v1/namespaces/falco-k8saudit/services/falco:web/proxy/metrics" | head

# End to end: this should fire "Attach/Exec to Pod" and reach Discord at WARNING
kubectl -n default run audit-probe --image=busybox --restart=Never -- sleep 300
kubectl -n default exec audit-probe -- true
kubectl -n default delete pod audit-probe

# ...and be queryable in Loki regardless of the Discord threshold
# {namespace="falco-k8saudit"} |= "Attach/Exec"
```

The single most informative check is the plugin load line. A Falco that started
cleanly, loaded rules, and is reading *nothing* looks identical to a healthy one
from every angle except that line and the event counters.

## Known gap: no ingestion-stalled alert yet

The syscall instance has `FalcoIngestionStalled`, keyed on
`falcosecurity_scap_n_evts_total`. This instance **does not emit that metric** — it
runs `engine.kind: nodriver`, so there is no scap capture layer, and which counter a
plugin-source instance exposes instead could not be confirmed without it running.

Writing a plausible expression against a metric that may not exist would be worse
than having none: it would never fire, and would look like coverage. So there is
deliberately no such alert yet. Add one once this shows the real series:

```bash
kubectl get --raw "/api/v1/namespaces/falco-k8saudit/services/falco:web/proxy/metrics" \
  | grep -oE '^falcosecurity_[a-z_]+' | sort -u
```

Until then, a k8saudit instance that goes blind is caught only if the pod or the
scrape target actually dies (`FalcoK8sAuditAgentDown`, `FalcoMetricsDown`).

## Noise and tuning

Same strategy as the syscall side: the full unfiltered stream is in Loki from day
one via `json_output`, so tuning can be driven by data rather than guesswork while
Discord stays at `warning`.

`config/rulesfile-tuning.yaml` (priority **50**, above the vendored 40) holds local
amendments. Do not edit the vendored ruleset in place — it is version-pinned and
replaced wholesale on upgrade, so changes there are silently lost. Falco's
`override:` blocks are the supported way to amend a rule you do not own.

### What the first deploy actually measured

Over a 2.6-minute window across all three control planes:

| Rule | Priority | Observed rate | To Discord? |
| --- | --- | --- | --- |
| `K8s Secret Get Successfully` | ERROR | **~3,300/day** | yes — floods it |
| `K8s Serviceaccount Created` | Informational | ~2,800/day | no (below `warning`) |
| `Attach/Exec Pod` | NOTICE | occasional | **no — and it should be** |

Two problems, both fixed in `rulesfile-tuning.yaml`:

**The secret rule was 100% CloudNativePG reading its own barman backup
credentials** — routine, on a timer, forever. At ERROR it sits above the `warning`
threshold and would have buried the Discord channel within hours. The exception is
deliberately narrow: one secret name (`cnpg-rustfs-creds`), and only for service
accounts ending `-postgres`. Any other secret, or that secret read by any other
identity, still alerts. Note this rule ships with **no `user_known_*` hook**, so it
must be amended with `override: condition: append` rather than by filling in a macro.

**`Attach/Exec Pod` ships at NOTICE, below the threshold** — meaning the single most
security-relevant thing this instance can see would never have alerted. Raised to
WARNING. This one is a judgement call rather than a noise fix; revert it if
interactive exec turns out to be common. The rule already honours
`user_known_exec_pod_activities` if specific automation needs exempting.

### The loudest rule was an upstream bug: TokenRequests reported as SA creations

This one is worth knowing about because it is invisible until you read the output
carefully, and it was by a wide margin the largest source of Discord traffic.

Both serviceaccount rules gate on the `serviceaccount` macro — which is only
`ka.target.resource=serviceaccounts` — combined with `ka.verb=create`. Nothing
looks at the **subresource**. But the TokenRequest API, which every pod in the
cluster uses to obtain and periodically refresh its projected service-account
token, is literally a `create` on `serviceaccounts/token`. So every token refresh
was reported as somebody creating a service account.

Measured over a 2.34h steady-state window on the API-server node:

| | rate | genuine |
| --- | --- | --- |
| `create serviceaccounts`, subresource=`token` | **4,721/day** | 0 |
| …of those landing in `kube-system` → `Service Account Created in Kube Namespace` (WARNING → Discord) | **276/day** | 0 |

The tell in the output is that `user=` is always a kubelet (`system:node:<node>`)
and the "created" service account is a long-standing one like `kube-vip` or
`metrics-server`:

```text
Warning Service account created in kube namespace
  (user=system:node:k3s-worker-04 serviceaccount=metrics-server ns=kube-system)
```

Fixed by appending `and not ka.target.subresource=token` to both rules. The
ruleset's own `user_known_sa_list` hook is deliberately **not** used: it matches
service account *names*, so it would mean maintaining a list of every account in
kube-system, would re-break the moment a new one appeared, and would also suppress
the genuine creation of those same accounts. Filtering the subresource keeps real
ServiceAccount creation alerting for every name.

### ⚠️ Secret-read noise is bursty — do not measure it with a short sample

This caught me out and will catch the next person. Secret reads track **Flux's 30m
reconcile cycle**, so a short window taken between reconciles looks near-silent and
one taken during a reconcile looks like a flood.

The first tuning pass was written from a 2.6-minute sample and concluded CNPG was
the entire story. A longer look showed the larger source by far was
**`kustomize-controller` reading all 52 SOPS-encrypted Secrets in the cluster** —
which is simply what it does: it cannot apply an encrypted Secret without reading it.

Measure across at least one full 30m interval, or better, use the cumulative
counter instead of tailing logs:

```bash
kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query=sum%20by%20(rule_name)%20(falcosecurity_falco_rules_matches_total%7Bjob%3D%22falco-k8saudit%22%7D)"
```

Exempting the flux-system controllers is broader than it first looks, and is
justified rather than assumed: the rule cannot distinguish legitimate Flux
decryption from a compromised Flux, because Flux reads every secret constantly — so
for that identity the rule carries no signal, only volume. An attacker holding the
kustomize-controller service account can already apply arbitrary manifests
cluster-wide; secret-read alerting was never the control that catches them. Reads by
an *application's* service account still alert, which is the realistic compromise
path this rule is genuinely useful for.

### The credential-in-ConfigMap rule is a substring match

`Create/Modify Configmap With Private Credentials` fires if the ConfigMap body
contains `"password"` or `"passphrase"` **anywhere** — it has no notion of whether
that is a credential or just the word. Two ConfigMaps here trip it, both verified by
hand as clean and both exempted by exact name:

- `loki-alerting-rules` — LogQL patterns for SSH brute-force alerting, which
  necessarily match on the literal strings `Failed password` / `incorrect password`
- `authentik-blueprints` — Authentik blueprint field names

The rule still fires for any other ConfigMap, including a new one that really does
carry a credential.

### Validating a rules change

Always validate against the *real* engine before merging — a bad `override:`
crash-loops all three control-plane pods:

```bash
P=$(kubectl -n falco-k8saudit get pod -l app.kubernetes.io/name=falco -o name | head -1)
kubectl -n falco-k8saudit exec $P -c falco -- falco \
  -V /etc/falco/rules.d/40-01-k8saudit-rules-oci.yaml -V /tmp/tuning.yaml
```

That only proves the rules **parse**. It says nothing about whether an exception
actually matches the events you meant, or whether you silenced more than you
intended — which is the failure that matters, because it is silent in both
directions. To check the logic, replay real audit records through the engine.

The k8saudit plugin reads a **bare path once and exits** (as opposed to `file://`,
which watches forever) — normally a footgun, but exactly what a replay needs:

```bash
# /tmp/replay.yaml — standalone config; note the bare path, NOT file://
plugins:
  - {library_path: /usr/share/falco/plugins/json.so, name: json}
  - {library_path: /usr/share/falco/plugins/k8saudit.so, name: k8saudit,
     open_params: /tmp/replay-audit.log}
load_plugins: [json, k8saudit]
engine: {kind: nodriver}
stdout_output: {enabled: true}
json_output: false
http_output: {enabled: false}
```

```bash
# Baseline, then with the change — diff the two
kubectl -n falco-k8saudit exec $P -c falco -- sh -c \
  'timeout 40 falco -c /tmp/replay.yaml -r /etc/falco/rules.d/40-01-k8saudit-rules-oci.yaml'
kubectl -n falco-k8saudit exec $P -c falco -- sh -c \
  'timeout 40 falco -c /tmp/replay.yaml -r /etc/falco/rules.d/40-01-k8saudit-rules-oci.yaml -r /tmp/tuning.yaml'
```

Build `replay-audit.log` from **real** events pulled out of `/var/log/k3s-audit/`,
and include deliberate **controls** — events that must still fire — alongside the
ones you expect to silence. Copies of a real event with the username or object name
edited work well. The TokenRequest and webhook-TLS exceptions above were verified
this way: 6 benign events silenced, while a genuine `serviceaccounts` create in
kube-system, a read by an unrelated service account, and a CNPG instance reading
its `-app` password secret all still fired.

Note `timeout` exists in the Falco image but **not** on macOS — run it inside the
pod, not around `kubectl`, or the error gets swallowed by whatever you pipe into.

## Upgrades

Neither OCI artifact is managed by Renovate — both live in CRD fields rather than
`image:` strings. **They must move together**: `k8saudit-rules` declares
`required_plugin_versions: [k8saudit 0.18.0]`, so bumping one without the other
fails rule loading.

```bash
# List real tags — GHCR paginates, and an unpaginated query silently truncates
# (this is how the container plugin was once mistaken for 0.5.0 when it was 0.7.1,
#  and k8saudit for 0.12.0 when it was 0.18.0)
crane ls ghcr.io/falcosecurity/plugins/plugin/k8saudit | sort -V | tail
crane ls ghcr.io/falcosecurity/plugins/ruleset/k8saudit | sort -V | tail
```

Before merging any change to the CRs, run the strict check that offline validation
misses — CRD structural schemas omit `additionalProperties: false`, so an undeclared
field passes JSON-Schema validation and is only rejected by Flux's server-side
apply:

```bash
kubectl kustomize --load-restrictor=LoadRestrictionsNone \
  kubernetes/infrastructure/controllers/falco-k8saudit/config \
  | kubectl apply --server-side --dry-run=server --field-manager=kustomize-controller -f -
```

## Rollback

Falco is observational — no admission webhook, blocks nothing — so removing it
cannot break a workload. The two halves roll back independently.

```bash
# Falco only (leaves auditing enabled and the log rotating harmlessly)
git revert <pr-merge-sha> && git push

# The control-plane change. Reverts to the previous config WITHOUT touching
# /etc/rancher/k3s/config.yaml, which holds the cluster token and S3 credentials.
cd ansible && ansible-playbook k3s-audit.yml -e k3s_audit_enabled=false
```

If an API server ever fails to start after a policy edit, the recovery is on the
node itself and does not need Ansible:

```bash
sudo rm -f /etc/rancher/k3s/config.yaml.d/10-audit.yaml && sudo systemctl restart k3s
```

That is the whole reason the flags are delivered as a **drop-in** rather than by
editing `config.yaml`: rollback is deleting one file, and the file holding the
cluster's secrets is never rewritten.
