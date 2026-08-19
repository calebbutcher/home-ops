# home-ops

My home Kubernetes cluster, managed as code. Everything here — from the Proxmox
VMs up through the apps — is provisioned and reconciled from this Git repo.
[Flux](https://fluxcd.io/) watches `main` and continuously applies whatever is
committed, so the repo *is* the source of truth for the running cluster.

## Overview

```text
Proxmox VE
   │  Terraform  (clone cloud-init template → VMs)
   ▼
Ubuntu VMs
   │  Ansible    (install HA k3s + flannel)
   ▼
k3s cluster
   │  flux bootstrap
   ▼
Flux CD ──► infrastructure ──► apps
            (controllers)      (workloads)
```

| Layer | Tooling | Lives in |
| --- | --- | --- |
| Virtual machines | [Terraform](https://www.terraform.io/) on Proxmox VE | [`infrastructure/terraform/`](infrastructure/terraform/) |
| OS + k3s install | [Ansible](https://www.ansible.com/) (fork of [techno-tim/k3s-ansible](https://github.com/techno-tim/k3s-ansible)) | [`ansible/`](ansible/) |
| Cluster add-ons | Helm via Flux | [`kubernetes/infrastructure/`](kubernetes/infrastructure/) |
| Applications | Helm / manifests via Flux | [`kubernetes/apps/`](kubernetes/apps/) |
| Secrets | [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) | `*.sops.yaml`, [`.sops.yaml`](.sops.yaml) |

## Stack

- **Compute** — HA k3s (embedded etcd) on Proxmox VMs, base domain `nerdbox.dev`.
- **Networking** — k3s's default **flannel** CNI (VXLAN, pod CIDR `10.42.0.0/16`)
  with kube-proxy. NetworkPolicies are enforced by k3s's built-in kube-router
  controller. [MetalLB](https://metallb.io/) (layer 2) provides `LoadBalancer`
  IPs from `10.2.169.80-90` — k3s servicelb is disabled — and
  [kube-vip](https://kube-vip.io/) holds the API server VIP at `10.2.169.10`.
  All three are installed by Ansible, not Flux.
- **Ingress / TLS** — [Traefik](https://traefik.io/) as the ingress controller,
  [cert-manager](https://cert-manager.io/) issuing Let's Encrypt certs via the
  Cloudflare DNS-01 solver. Services are exposed on `*.int.nerdbox.dev`
  (internal) and `*.nerdbox.dev` (external).
- **Databases** — [CloudNativePG](https://cloudnative-pg.io/) for Postgres and
  [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator) for
  MariaDB, one instance per app.
- **Storage / backups** — [VolSync](https://volsync.readthedocs.io/) (restic) for
  app PVCs, CNPG's barman-cloud plugin for Postgres PITR, mariadb-operator native
  dumps, and k3s `--etcd-s3` snapshots. All land in RustFS (S3-compatible) on a
  TrueNAS box, deliberately independent of the cluster.
- **Observability** — [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
  (Prometheus, Alertmanager, Grafana) plus [Uptime Kuma](https://github.com/louislam/uptime-kuma).
- **GitOps / updates** — Flux reconciles every 30m; [Renovate](https://docs.renovatebot.com/)
  opens one PR per dependency update (approve-then-apply, nothing auto-merges).

## Repository layout

```text
.
├── ansible/                  # k3s install / upgrade / reset playbooks
├── docs/                     # runbooks (backup-recovery, updates)
├── infrastructure/
│   ├── scripts/              # e.g. create-ubuntu cloud-init template
│   └── terraform/            # Proxmox VM provisioning
└── kubernetes/
    ├── bootstrap/flux/       # one-time Flux bootstrap notes
    ├── flux/cluster/         # Flux entrypoint (apps + infrastructure Kustomizations)
    ├── infrastructure/
    │   ├── controllers/      # traefik, cert-manager, cnpg, mariadb-operator, volsync, longhorn, …
    │   └── configs/          # ClusterIssuers, Cloudflare token, …
    └── apps/                 # media, monitoring, tools, uptime-kuma
```

Flux applies `kubernetes/infrastructure/` first, then `kubernetes/apps/` (the
`apps` Kustomization `dependsOn` `infrastructure`).

## Cluster add-ons

Everything below is deployed by Flux from
[`kubernetes/infrastructure/controllers/`](kubernetes/infrastructure/controllers/).
The CNI, load balancer, and API VIP are *not* here — they are installed by
Ansible; see **Networking** above.

| Component | Purpose |
| --- | --- |
| Traefik | Ingress controller |
| cert-manager | ACME (Let's Encrypt) certificates via Cloudflare DNS-01 |
| CrowdSec | IP-reputation bouncer + AppSec WAF in front of Traefik |
| Longhorn | Distributed block storage — the **default StorageClass** |
| VolSync | PVC backup/restore (restic → RustFS) |
| snapshot-controller | CSI volume snapshots (Piraeus chart) |
| CloudNativePG | Postgres operator (per-app clusters, PITR via barman-cloud) |
| cnpg-barman-plugin | Barman Cloud plugin backing CNPG backups/PITR |
| mariadb-operator | MariaDB operator (per-app instances, native backups) |
| system-upgrade-controller | Rolling k3s version upgrades (see [`docs/updates.md`](docs/updates.md)) |
| tailscale-operator | Tailscale exit node + LAN subnet router |

## Applications

| App | Namespace | URL | Notes |
| --- | --- | --- | --- |
| Sonarr | `media` | sonarr.nerdbox.dev | TV management |
| Radarr | `media` | radarr.nerdbox.dev | Movie management |
| Prowlarr | `media` | prowlarr.int.nerdbox.dev | Indexer manager |
| Seerr | `media` | requests.nerdbox.dev | Requests (Overseerr fork, pinned by digest) |
| Tracearr | `media` | tracearr.nerdbox.dev | Backed by CNPG Postgres |
| Uptime Kuma | `uptime-kuma` | uptime.nerdbox.dev | Status/monitoring, MariaDB-backed |
| IT-Tools | `tools` | it-tools.int.nerdbox.dev | Utilities |
| BentoPDF | `tools` | pdf.int.nerdbox.dev | Client-side PDF toolkit |
| kube-prometheus-stack | `monitoring` | — | Prometheus / Grafana / Alertmanager |

## Bootstrapping from scratch

1. **Provision VMs** — `infrastructure/terraform/` clones a cloud-init Ubuntu
   template on Proxmox. See [`infrastructure/terraform/SETUP.md`](infrastructure/terraform/SETUP.md).
2. **Install k3s** — run the Ansible playbook in [`ansible/`](ansible/)
   (`ansible-playbook site.yml`) to stand up HA k3s with flannel, MetalLB and
   kube-vip, and fetch a kubeconfig.
3. **Bootstrap Flux** — point Flux at this repo and create the SOPS age secret so
   it can decrypt secrets. See [`kubernetes/bootstrap/flux/README.md`](kubernetes/bootstrap/flux/README.md).
4. Flux reconciles `kubernetes/infrastructure/` then `kubernetes/apps/` — done.

Full disaster-recovery procedure (restoring etcd, PVCs, and databases) is in
[`docs/backup-recovery.md`](docs/backup-recovery.md).

## Secrets

Secrets are committed **encrypted** as `*.sops.yaml` using
[SOPS](https://github.com/getsops/sops) with an [age](https://github.com/FiloSottile/age)
key (rules in [`.sops.yaml`](.sops.yaml)). Flux decrypts them in-cluster via the
`sops-age` secret. The age **private key never lives in Git** — it's kept in a
password manager with an offline copy. Ansible secrets use the same mechanism
([`ansible/inventory/my-cluster/group_vars/all/secrets.sops.yaml`](ansible/inventory/my-cluster/group_vars/all/secrets.sops.yaml)),
not ansible-vault.

> ⚠️ Don't run kustomize transformers (top-level `namespace`/`labels`) over
> `.sops.yaml` files — it corrupts the SOPS MAC and Flux fails to decrypt.

## Updates

Versions are pinned — exact Helm chart versions and image tags, no floating
ranges. Renovate opens a PR per available update; merging the PR is the
approval, and Flux applies it on the next reconcile. Details:
[`docs/updates.md`](docs/updates.md).

Exactly **one** image floats:
[`dgtlmoon/sockpuppetbrowser`](kubernetes/apps/pricewatch/helmrelease.yaml) in
pricewatch, on `:latest` because upstream's versioned tags have been stale since
Aug 2025 while `:latest` tracks the maintainer's current build. It is documented
in-file. (Seerr is also tagged `latest`, but pinned by digest — the digest is
what resolves, so it is immutable.) Anything else on a moving tag is a bug.

Renovate also covers the pieces that live outside Flux — the k3s version in the
[system-upgrade-controller Plans](kubernetes/infrastructure/controllers/system-upgrade-controller/plans/),
and kube-vip / MetalLB / the k3s install baseline in the
[ansible inventory](ansible/inventory/my-cluster/group_vars/all/main.yml), which
are marked with `# renovate:` comments. **A merged k3s PR upgrades the live
cluster** (system-upgrade-controller acts on every node labelled
`k3s-upgrade=true`); the ansible pins are inert until the play is re-run.

## CI

Every pull request runs [`.github/workflows/validate.yml`](.github/workflows/validate.yml):

- **`kustomize build` + `kubeconform`** over each Flux Kustomization path, so a
  manifest that Flux would reject fails on the PR instead of in the cluster.
- **orphan check** — a manifest sitting next to a `kustomization.yaml` that does
  not list it is silently never applied; that now fails the build.
- **yamllint** (narrow: duplicate keys, tabs, unparseable YAML — see
  [`.yamllint.yaml`](.yamllint.yaml)).
- **gitleaks** over the working tree *and* the full git history. This repo is
  public, so a committed credential is an incident.

Two things CI deliberately cannot do: `flux diff` (the cluster is LAN-only, with
no path in from a hosted runner) and validating SOPS-encrypted Secrets (that
would mean putting the age private key in GitHub). Encrypted Secrets are reported
as skipped rather than silently counted as passing.

A weekly [`image-scan.yml`](.github/workflows/image-scan.yml) reports CVEs, but
only for images pinned directly in a manifest — the chart-managed majority is not
covered. See that file's header before reading a green run as cluster-wide.

## Backup & recovery

What's backed up, where it goes, and how to restore a PVC, etcd, Postgres, or the
whole cluster: [`docs/backup-recovery.md`](docs/backup-recovery.md).

## Conventions

- All changes go through a **feature branch → PR → `main`**; never commit directly
  to `main`. Flux only watches `main`.
- Keep dependency versions pinned so Renovate stays the single update path.

## License

[MIT](LICENSE) © Caleb Butcher
