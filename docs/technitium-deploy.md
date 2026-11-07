# Technitium DNS: HA cluster deployment and runbook

Internal DNS for the lab, replacing Pi-hole. A **3-node Technitium cluster** spanning two
standalone VMs on VLAN 30 and one pod in k3s, fronted by a keepalived VIP.

| Node | Address | Role | Managed by |
|------|---------|------|------------|
| `dns-01.dns.nerdbox.dev` | `10.2.30.251` | Cluster **Primary**, keepalived MASTER | `ansible/roles/technitium` |
| `dns-02.dns.nerdbox.dev` | `10.2.30.252` | Secondary, keepalived BACKUP | `ansible/roles/technitium` |
| `dns-k3s.dns.nerdbox.dev` | `10.2.169.84` | Secondary (**permanent** — never promote) | Flux, `kubernetes/apps/technitium/` |
| — | `10.2.30.250` | keepalived VIP (floats across the two VMs) | keepalived |

Clients are handed **`[10.2.30.250, 10.2.169.84]`**. All three answer queries independently;
the VIP is the backstop for a full-cluster outage, since a MetalLB L2 address dies with the
cluster.

Resolution is **recursive from the root hints** with **DNSSEC validation** on, except for the
zones below, which are forwarded to Active Directory.

## Who owns which zone

Active Directory stays authoritative for its own domains; Technitium forwards to it. The long-term
direction is the reverse of today's Pi-hole setup: clients ask Technitium, and Technitium asks
the DCs only for what it does not own.

| Zone | On Technitium | Owner / target |
|------|---------------|----------------|
| `dns.nerdbox.dev` | Primary (cluster zone) | Technitium. Node names, TLSA records. |
| `infra.nerdbox.dev` | **Primary** | Technitium. Proxmox, PBS and TrueNAS hosts. |
| `int.nerdbox.dev` | Forwarder | AD (`10.2.30.11`, `10.2.30.12`). Domain SRV records, and the k3s ingress names external-dns writes. |
| `nerdbox.dev` | Forwarder, plus local MX, SPF TXT and `autodiscover` | AD (`10.2.30.11`, `.12`). AD holds the split-horizon: public app names resolve to Traefik inside the house. |
| `valhalla.local` | Forwarder | Legacy AD (`10.1.30.12`, `10.1.30.13`). Forward only; nothing there is changed. |
| `30.1.10.in-addr.arpa` | Forwarder | Legacy AD (`10.1.30.12`, `.13`) |
| `1.10.in-addr.arpa`, `2.10.in-addr.arpa`, `10.in-addr.arpa` | Forwarder | AD (`10.2.30.11`, `.12`) |

Every zone is a member of the cluster catalog, so it exists on all three nodes. A zone created
without `catalog=cluster-catalog.dns.nerdbox.dev` lives on the primary only, and the other two
nodes quietly answer NXDOMAIN for it.

Forwarders have **DNSSEC validation off**. For `valhalla.local` it is mandatory: the signed root
proves `.local` does not exist, so validated answers would all come back bogus. The AD zones
are unsigned anyway.

The AD side has one matching piece: a domain-wide **conditional forwarder** for
`infra.nerdbox.dev` → `10.2.30.250`, `10.2.169.84`. That keeps `infra` resolving for anything that
still asks the DCs directly, including Pi-hole until the cutover.

### Why the cluster domain is `dns.nerdbox.dev`

The cluster was first initialised as `int.nerdbox.dev`, which is also an AD domain. Cluster init
creates a signed primary zone named after the cluster domain, so Technitium became
authoritative for the AD domain: it could not forward it, and it had none of the
`_msdcs`/`_ldap`/`_kerberos` records domain logons need. The cluster domain cannot be changed,
so the cluster was rebuilt. Pick a cluster domain that no other DNS server is authoritative for.

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
Ansible role provision a *fresh* node; everything below was set after cluster formation and
lives on the primary, from where it replicates.

| Setting | Value | Why it matters |
|---------|-------|----------------|
| Cluster domain | `dns.nerdbox.dev` | **Permanent — Technitium cannot change it.** Changing it means rebuilding the cluster (runbook below). |
| Zones | The table in "Who owns which zone" | Recreate exactly that set, all with `catalog=cluster-catalog.dns.nerdbox.dev`. |
| Zone transfer ACL (`dns.nerdbox.dev`, `cluster-catalog.dns.nerdbox.dev`) | `10.2.30.251`, `10.2.30.252`, `10.2.169.84`, **`10.2.169.40`–`.45`** | The worker IPs are load-bearing — see "k3s member egress" below. **Add a line here when you add a worker node**, or the k3s member's zone transfers start failing whenever it lands on the new one. |
| Recursion | `AllowOnlyForPrivateNetworks` | These hold LAN addresses; must not become open resolvers. |

Member zones inherit the **catalog's** zone-transfer policy. Setting `zoneTransfer` on a member
zone is stored and shown but ignored, and `overrideCatalogZoneTransfer=true` breaks cluster
replication (secondaries log `zone transfer response (RCODE=Refused)`). Change transfer settings
on the catalog zone only.

The cluster zone is DNSSEC-signed and carries `_53443._tcp.<node>` **TLSA records with
`certificateUsage: DANE-EE`**: that is how cluster peers pin each other's self-signed
certificates. Nothing else writes into this zone.

## external-dns writes to AD, not Technitium

external-dns (`kubernetes/infrastructure/controllers/external-dns/`) publishes the k3s ingress
names into the AD zone `int.nerdbox.dev` over RFC2136 with **GSS-TSIG**, as the AD account
`svc-externaldns`. It round-robins between `hlb-dc-04` and `hlb-dc-05`.

AD side, which is not in git:

- `svc-externaldns`: a plain domain user, password set never to expire and rotated by hand, no
  interactive logon. No extra delegation: the default zone ACL lets authenticated users create
  new names, and the creator owns what it creates.
- `int.nerdbox.dev` dynamic updates: **Secure only**.
- `int.nerdbox.dev` zone transfers: only to the k3s node IPs (`10.2.169.30`–`.32`, `.40`–`.45`).
  external-dns reads the zone by AXFR, which is unsigned under GSS-TSIG, and its traffic leaves
  from whichever node the pod is on.

`policy: upsert-only` with the TXT registry means external-dns only ever adds names that are
missing. The hand-made records already in the zone have no ownership TXT and are never
modified.

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

Nodes are renamed into the cluster domain on join (`dns-01` → `dns-01.dns.nerdbox.dev`). Their
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
  --data-urlencode "domain=synctest.dns.nerdbox.dev" --data-urlencode "zone=dns.nerdbox.dev" \
  --data-urlencode "type=A" --data-urlencode "ipAddress=10.99.99.99" --data-urlencode "ttl=60"

for ip in 10.2.30.251 10.2.30.252 10.2.169.84; do dig +short @$ip synctest.dns.nerdbox.dev; done
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
everywhere and the VIP moves automatically — only config *writes* are paused.

1. Confirm dns-01 is genuinely gone, not just unreachable. Two primaries would diverge.
2. On dns-02, promote it (`/api/admin/cluster/secondary/promote`); if dns-01 is unreachable this
   needs the force option.
3. Update the **EndpointSlice** in `primary-ingress.yaml` to `10.2.30.252`, or
   `technitium.int.nerdbox.dev` keeps pointing at the dead node.
4. Swap `keepalived_state`/`keepalived_priority` in `host_vars/` so the rebuilt dns-01 does not
   preempt the VIP the moment it returns.
5. Re-join the rebuilt node as a secondary (it cannot rejoin as primary).

### Rebuild the cluster from scratch

Needed only if the **cluster domain** must change. Wiping every node is cleaner than deleting
and re-initialising the cluster in place: a fresh init issues each node a self-signed
certificate for its new name, while an in-place rename keeps the old certificate and peers reject
it (`RemoteCertificateNameMismatch`).

1. Set the new names in git first: `technitium_server_domain` in `host_vars/`, and
   `DNS_SERVER_DOMAIN` in `kubernetes/apps/technitium/helmrelease.yaml`.
2. k3s member: `flux suspend hr technitium -n technitium`, scale the deployment to 0, delete the
   `technitium-config` PVC, then `flux resume`. Flux recreates the PVC empty; the VolSync
   snapshot is the rollback.
3. Each VM: `docker stop technitium`, `mv /opt/technitium/config /opt/technitium/config.bak-<date>`,
   then from `ansible/`: `ansible-playbook technitium.yml --limit <ip>`.
4. Init on dns-01: `/api/admin/cluster/init?clusterDomain=<domain>&primaryNodeIpAddresses=10.2.30.251`.
5. Join dns-02 and the k3s member with `/api/admin/cluster/initJoin`. **`primaryNodeUrl` must
   use the primary's domain name, not its IP** — the certificate identity is the domain — with
   `primaryNodeIpAddress` supplying the address, `secondaryNodeIpAddresses` the joining node's own
   IP, and `ignoreCertificateErrors=true` for the self-signed cert.
6. Re-apply the zone transfer ACL and recreate the zones (see "State that is NOT in git").
7. Delete the `config.bak` directories once everything verifies.
