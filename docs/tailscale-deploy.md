# Tailscale: exit node + LAN subnet router on k3s

This runbook covers the **net-new** [Tailscale](https://tailscale.com/) deployment under
`kubernetes/infrastructure/controllers/tailscale-operator/`. It runs the **Tailscale Kubernetes
Operator**, which manages a single `Connector` device (`k3s-gateway`) that:

- **Exit node** — tailnet devices (phone on public wifi, laptop away from home) route their
  **public internet** egress through home.
- **Subnet router** — advertises the LAN `10.2.169.0/24`, so remote tailnet devices reach
  internal services (nodes `.30-.45`, MetalLB VIPs `.80-.90`, API VIP `.10`, Traefik `.81`,
  Proxmox, TrueNAS, `*.int.nerdbox.dev`) **without** public ingress.

Both roles live on one `Connector` CR. The operator provisions a tailscale proxy pod with
`NET_ADMIN` + `net.ipv4.ip_forward` set for it — **no host/Ansible changes, no node config**.

## Architecture

```
   Remote tailnet device (phone/laptop)
        │  ①  exit node  → all public internet egress
        │  ②  subnet route 10.2.169.0/24 → internal services
        ▼
   k3s-gateway (tailscale proxy pod, tailscale ns)  ──SNAT to node IP──▶ LAN 10.2.169.0/24
        ▲
   tailscale-operator (Deployment) ── auths to tailnet via operator-oauth (OAuth client)
                                       reconciles the Connector CR → provisions the proxy
```

## Prerequisites (Tailscale admin console — out of band)

1. **OAuth client** (Settings → OAuth clients) with **write** scope on **Devices/Core** and
   **Keys/Auth Keys**, owner `tag:k8s-operator`. Put its id/secret into `secret.sops.yaml`
   (below).
2. **ACL policy** (Access controls):
   ```jsonc
   "tagOwners": {
     "tag:k8s-operator": [],
     "tag:k8s": ["tag:k8s-operator"]
   },
   "autoApprovers": {                       // optional: self-approve both roles
     "exitNode": ["tag:k8s"],
     "routes": {                            // one entry per advertised route
       "10.2.169.0/24": ["tag:k8s"],
       "10.0.0.0/23":   ["tag:k8s"],
       "10.1.30.0/24":  ["tag:k8s"],
       "10.1.50.0/24":  ["tag:k8s"],
       "10.2.30.0/24":  ["tag:k8s"],
       "10.2.50.0/24":  ["tag:k8s"]
     }
   }
   ```
   Without `autoApprovers`, approve the exit node + each route once in **Machines → k3s-gateway →
   Edit route settings**. `autoApprovers.routes` is per-CIDR — any route not listed still needs a
   manual approve (or add it here), so keep this list in sync with `config/connector.yaml`.

## What's in `kubernetes/infrastructure/controllers/tailscale-operator/`

| File | Role |
|------|------|
| `namespace.yaml` | `tailscale` namespace. |
| `helmrepository.yaml` | `tailscale-operator` HelmRepository (`https://pkgs.tailscale.com/helmcharts`). |
| `secret.sops.yaml` | `operator-oauth` Secret (`tailscale` ns), keys `client_id` / `client_secret`. Pre-created so the chart mounts it instead of creating its own — leave `oauth: {}` in the HelmRelease. |
| `helmrelease.yaml` | `tailscale-operator` chart `1.98.9`; `oauth: {}` (uses the pre-created secret); `installCRDs: true` (default) ships the `Connector`/`ProxyClass`/`DNSConfig` CRDs; API-server proxy off. |
| `config/connector.yaml` | Cluster-scoped `Connector` `k3s-gateway` — `exitNode: true` + `subnetRouter.advertiseRoutes` (k3s LAN `10.2.169.0/24` plus `10.0.0.0/23`, `10.1.30.0/24`, `10.1.50.0/24`, `10.2.30.0/24`, `10.2.50.0/24`). Applied by a **separate** Flux Kustomization, not the infrastructure set (see below). |
| `config/kustomization.yaml` | Kustomize entry for the `config/` path. |

The operator is registered in `kubernetes/infrastructure/kustomization.yaml`
(`- controllers/tailscale-operator`). The `Connector` is applied by a dedicated Flux Kustomization
`kubernetes/flux/cluster/tailscale-connector.yaml` (`dependsOn: infrastructure`, `retryInterval: 2m`).

> **Why the Connector is split out (load-bearing):** its CRD is installed by the operator's
> HelmRelease. If the `Connector` CR sits in the **same** kustomization as the HelmRelease, Flux's
> pre-apply dry-run fails with `no matches for kind "Connector"` and **aborts the entire apply** —
> the operator never installs, so the CRD never appears: a deadlock that also fails `infrastructure`
> and blocks the `apps` Kustomization (which `dependsOn` it). Isolating the CR behind
> `dependsOn: infrastructure` lets the operator install first; the Connector Kustomization then
> converges on its own (`retryInterval`) and can never re-block `apps`.

> **OAuth credentials**: the chart mounts a Secret **named exactly `operator-oauth`** with files
> `client_id`/`client_secret`. This is the documented pre-create path (chart values.yaml: *"If
> unset a Secret named operator-oauth must be precreated"*). We deliberately do **not** use the
> newer `oauthSecretVolume` path — it is broken on 1.9x (tailscale/tailscale#18244). To set/rotate
> creds: edit the two placeholder values and `sops --encrypt --in-place secret.sops.yaml`.

> **SOPS gotcha**: no top-level kustomize transformers (`namespace:`/`commonLabels`) — they corrupt
> the `.sops.yaml` MAC and Flux fails to decrypt. Every manifest hard-codes its namespace.

## Deploy

1. Put the real OAuth client id/secret in `secret.sops.yaml` and re-encrypt:
   ```sh
   sops --encrypt --in-place \
     kubernetes/infrastructure/controllers/tailscale-operator/secret.sops.yaml
   ```
2. Merge the PR to `main`, then reconcile:
   ```sh
   flux reconcile kustomization infrastructure --with-source
   ```

## Verify

```sh
# Operator + one proxy pod (ts-k3s-gateway-…) both Running
kubectl -n tailscale get pods

# Connector reconciled: conditions Ready, tailnet IPs assigned
kubectl get connector k3s-gateway -o yaml | yq '.status'

# Operator logs — no OAuth/auth errors
kubectl -n tailscale logs deploy/operator | tail -30
```

Then in the admin console → **Machines**: `k3s-gateway` appears, tagged `tag:k8s`, offering
**Exit node** + the `10.2.169.0/24` route (auto-approved if `autoApprovers` set, else approve once).

**End-to-end** on a phone/laptop running Tailscale:

- **Exit node**: enable *Use exit node → k3s-gateway*, then `curl ifconfig.me` shows your home WAN
  IP. Disable it afterward.
- **Subnet route** (independent of exit node): from off-LAN, hit a LAN IP, e.g.
  `curl -k https://10.2.169.81` (Traefik) or open the Proxmox/TrueNAS UI by IP.

## Rollback

Delete `kubernetes/flux/cluster/tailscale-connector.yaml` (prunes the `Connector`/proxy pod) and
remove `- controllers/tailscale-operator` from `kubernetes/infrastructure/kustomization.yaml`
(prunes the operator + release), then delete the device in the admin console. To keep the operator
but drop the gateway, delete `config/connector.yaml` only (its Kustomization prunes it).

## Notes / optional follow-ups

- **Ordering** (see the split-out note above): the `Connector` CR lives in its own
  `tailscale-connector` Flux Kustomization (`dependsOn: infrastructure`) precisely because putting
  it in the infrastructure set deadlocks the dry-run against a CRD the operator hasn't installed yet.
  After the operator is up, `flux reconcile kustomization tailscale-connector` applies the gateway.
- **Remote DNS for `*.int.nerdbox.dev`**: IP access works immediately once the route is approved.
  To resolve internal **hostnames** remotely, add a **split-DNS nameserver** for `int.nerdbox.dev`
  → your LAN DNS in the tailnet **DNS** settings.
- **Placement / bandwidth**: all tailnet egress funnels through the one worker running the proxy
  pod — fine for home use. For route-failover HA, use `spec.replicas: 2` + `hostnamePrefix`
  (instead of `hostname`); a `ProxyClass` can pin nodeSelector/tolerations. Not needed for v1.
- **Cilium**: cluster runs Cilium with kube-proxy replacement + BPF masquerade. The proxy pod
  SNATs tailnet traffic to its node IP, which is compatible — the end-to-end checks above are the
  real confirmation. Advertising the LAN `/24` (not pod/service CIDRs) keeps this clean.
