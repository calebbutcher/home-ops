# Technitium DNS: HA cluster deployment and runbook

Internal DNS for the lab, replacing Pi-hole. A **3-node Technitium cluster** spanning two
standalone VMs on VLAN 30 and one pod in k3s, fronted by a keepalived VIP.

| Node | Address | Role | Managed by |
|------|---------|------|------------|
| `dns-01.int.nerdbox.dev` | `10.2.30.251` | Cluster **Primary**, keepalived MASTER | `ansible/roles/technitium` |
| `dns-02.int.nerdbox.dev` | `10.2.30.252` | Secondary, keepalived BACKUP | `ansible/roles/technitium` |
| `dns-k3s.int.nerdbox.dev` | `10.2.169.84` | Secondary (**permanent** — never promote) | Flux, `kubernetes/apps/technitium/` |
| — | `10.2.30.250` | keepalived VIP (floats across the two VMs) | keepalived |

Clients are handed **`[10.2.30.250, 10.2.169.84]`**. All three answer queries independently;
the VIP is the backstop for a full-cluster outage, since a MetalLB L2 address dies with the
cluster.

Resolution is **recursive from the root hints** (no forwarders) with **DNSSEC validation** on.

## Which UI do I use?

Clustering is **active-active for serving, active-passive for administration**.

| I want to… | Go to |
|------------|-------|
| Change anything (block lists, zones, settings, apps) | <https://technitium.int.nerdbox.dev> → **dns-01, the primary** |
| See what a client actually queried | The UI of **whichever node answered** — query logs are per-node and are **not** replicated |
| Reach the k3s member specifically | <https://technitium-k3s.int.nerdbox.dev> (read-only config) |

Config writes only take on the primary. Secondaries accept the change in the UI and then have
it overwritten by the next cluster sync.

**Do not bookmark the VIP (`10.2.30.250:5380`) for admin.** It normally lands on dns-01, but
after a failover it silently becomes dns-02 — and edits would go to a read-only node.

`technitium.int.nerdbox.dev` reaches an off-cluster VM through a Service with no selector plus a
hand-maintained EndpointSlice (`primary-ingress.yaml`). Traefik talks HTTPS to `:53443` so admin
credentials do not cross VLANs in plaintext, with `insecureSkipVerify` because the backend
presents Technitium's self-signed cert.

## State that is NOT in git

Technitium is configured through its own API/UI, not declaratively. The manifests and the
Ansible role provision a *fresh* node; everything below was set at cluster-formation time and
lives only on the primary (from where it replicates).

| Setting | Value | Why it matters |
|---------|-------|----------------|
| Cluster domain | `int.nerdbox.dev` | **Permanent — Technitium cannot change it.** Changing it means tearing the cluster down and re-joining every node. |
| Zone transfer ACL (`int.nerdbox.dev`, `cluster-catalog.int.nerdbox.dev`) | `10.2.30.251`, `10.2.30.252`, `10.2.169.84`, **`10.2.169.40`–`.45`** | The worker IPs are load-bearing — see "k3s member egress" below. **Add a line here when you add a worker node**, or the k3s member's zone transfers start failing whenever it lands on the new one. |
| Recursion | `AllowOnlyForPrivateNetworks` | These hold LAN addresses; must not become open resolvers. |

## Gotchas

These each cost real debugging time. All are load-bearing.

### Environment variables apply at FIRST INIT ONLY

`DNS_SERVER_*` env vars are read only while initializing a fresh config directory. Once
`/etc/dns/*.config` exists, Technitium reads those files and ignores the environment entirely.

The env blocks in `helmrelease.yaml` and `roles/technitium/tasks/technitium.yml` are therefore
**provisioning defaults, not desired state**. Editing one later reconciles cleanly, restarts the
pod, and changes nothing. To change a live setting use the API (`/api/settings/set`) or wipe the
config directory and let it re-initialize.

### `ENABLE_HTTPS` alone does not open `:53443`

With no certificate to present the listener silently never binds — clean startup logs, no error,
only `:53` and `:5380` open. It also needs `DNS_SERVER_WEB_SERVICE_USE_SELF_SIGNED_CERT=true`.

That self-signed certificate **is** the DANE-EE identity peers pin, which is why `:53443` can
never be fronted by Traefik for cluster traffic, and why the cert must live on the PVC so a
rescheduled pod keeps its identity.

### Cluster init renames every node

Nodes are renamed into the cluster domain on join (`dns-01` → `dns-01.int.nerdbox.dev`). Their
self-signed certs are **not** reissued, so if the new name does not match the cert the peers
reject each other with `RemoteCertificateNameMismatch` and heartbeats fail. Keep
`DNS_SERVER_DOMAIN` in the manifests consistent with `<name>.<cluster domain>`.

### The k3s member's egress IP is not its service IP

Peers *reach* it on `10.2.169.84` (MetalLB), but its own outbound traffic is SNAT'd to
**whichever worker node the pod is running on** — and that changes on every reschedule. Zone
transfers are refused unless the whole worker range is in the ACL. Symptom: the member holds the
catalog zone but never receives the zones it lists.

### Run Ansible from `ansible/`, never the repo root

`ansible.cfg` enables the `community.sops` vars plugin and is loaded from the current working
directory. From the repo root, every secret silently resolves to raw ciphertext and the play
still goes green. `tasks/assert_sops_decrypted.yml` now refuses to run in that state.

### keepalived health weight must exceed the priority gap

MASTER 150 / BACKUP 100 with `weight -40` leaves a failed master at 110 — still above the backup
— holding the VIP while serving nothing. The role uses **-60**.

## Runbooks

### Verify cluster health

```sh
TOKEN=$(curl -s --get --data-urlencode "user=admin" --data-urlencode "pass=$PASS" \
  http://10.2.30.251:5380/api/user/login | jq -r .token)
curl -s "http://10.2.30.251:5380/api/admin/cluster/state?token=$TOKEN" | jq '.response.clusterNodes[] | {name, type, state}'
```

All three should report `Connected` (the primary reports `Self`). If a node is not, read its own
log — the failure is recorded on the node that cannot reach the peer, not on the primary:

```sh
kubectl -n technitium exec deploy/technitium -- tail -50 /var/log/technitium/dns/$(date -u +%F).log
ssh ubuntu@10.2.30.252 'sudo docker exec technitium tail -50 /var/log/technitium/dns/'$(date -u +%F)'.log'
```

### Verify replication actually works

`Connected` only means heartbeats pass. To prove zone data flows, add a canary on the primary and
query all three directly:

```sh
curl -s --get "http://10.2.30.251:5380/api/zones/records/add" --data-urlencode "token=$TOKEN" \
  --data-urlencode "domain=synctest.int.nerdbox.dev" --data-urlencode "zone=int.nerdbox.dev" \
  --data-urlencode "type=A" --data-urlencode "ipAddress=10.99.99.99" --data-urlencode "ttl=60"

for ip in 10.2.30.251 10.2.30.252 10.2.169.84; do dig +short @$ip synctest.int.nerdbox.dev; done
```

Expect all three to answer within ~15s. Delete the record afterwards
(`/api/zones/records/delete`, same parameters).

### VIP failover drill

Safe to run any time; the peer keeps serving throughout.

```sh
ssh ubuntu@10.2.30.251 'sudo docker stop technitium'   # VIP should leave in ~15s (fall 3 x interval 5)
ssh ubuntu@10.2.30.252 'ip -br addr show eth0'          # 10.2.30.250 should appear here
dig +short @10.2.30.250 google.com                      # still resolves
ssh ubuntu@10.2.30.251 'sudo docker start technitium'  # VIP returns in ~10s (rise 2 x interval 5)
```

### Promote dns-02 when dns-01 is lost

Technitium promotion is **manual by design**. While the primary is down, queries keep resolving
everywhere and the VIP moves automatically — only config *writes* and external-dns record
creation are paused.

1. Confirm dns-01 is genuinely gone, not just unreachable. Two primaries would diverge.
2. On dns-02, promote it (`/api/admin/cluster/secondary/promote`); if dns-01 is unreachable this
   needs the force option.
3. Re-point **external-dns** at `10.2.30.252` — it writes via RFC2136 to the primary's address,
   not the VIP, because the VIP can land on a read-only node. Update `--rfc2136-host` in
   `kubernetes/apps/external-dns/helmrelease.yaml`.
4. Update the **EndpointSlice** in `primary-ingress.yaml` to `10.2.30.252`, or
   `technitium.int.nerdbox.dev` keeps pointing at the dead node.
5. Swap `keepalived_state`/`keepalived_priority` in `host_vars/` so the rebuilt dns-01 does not
   preempt the VIP the moment it returns.
6. Re-join the rebuilt node as a secondary (it cannot rejoin as primary).

### Rebuild the cluster from scratch

Needed only if the **cluster domain** must change. Cheap while the cluster is empty, expensive
once block lists and zones exist.

1. Remove each secondary from the primary (`/api/admin/cluster/primary/removeSecondary`). If the
   primary cannot validate a secondary's certificate, have that node leave itself instead:
   `/api/admin/cluster/secondary/leave?forceLeave=true`.
2. Delete the cluster on the primary (`/api/admin/cluster/primary/delete`).
3. Re-init: `/api/admin/cluster/init?clusterDomain=<domain>&primaryNodeIpAddresses=10.2.30.251`.
4. Re-join each secondary with `/api/admin/cluster/initJoin`. **`primaryNodeUrl` must use the
   primary's domain name, not its IP** — the certificate identity is the domain — with
   `primaryNodeIpAddress` supplying the address and `ignoreCertificateErrors=true` for the
   self-signed cert.
5. Re-apply the zone transfer ACL (see "State that is NOT in git") and delete the orphaned zone
   left behind by the old cluster domain.
