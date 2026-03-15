# Terraform Pre-flight Setup

## Workstation Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | >= 1.6.0 | `brew install terraform` or [tfenv](https://github.com/tfutils/tfenv) |
| SSH keypair | any | `ssh-keygen -t ed25519` |
| Age key | any | `age-keygen -o ~/.config/sops/age/keys.txt` (used by Flux/SOPS, not required for Terraform) |

## Network Access Required

Before running Terraform, ensure your workstation can reach:

- **CyberArk CCP**: `https://cyb-ccp-01.int.nerdbox.dev` (HTTPS/443)
- **Proxmox API**: `https://pve-r630-01.infra.nerdbox.dev:8006` (HTTPS/8006)
- **k8s subnet**: `10.2.169.0/24` (SSH/22 for post-apply validation)

---

## One-time Proxmox Setup

### 1. Create the API service user

```bash
# On the Proxmox host (via SSH or shell)
pveum user add terraform@pve --comment "Terraform provisioner"
```

### 2. Create the `TerraformProvisioner` role

In the Proxmox UI: **Datacenter → Permissions → Roles → Create**

Name: `TerraformProvisioner`

Add all of the following privileges:

```
VM.Allocate
VM.Clone
VM.Config.CDROM
VM.Config.CPU
VM.Config.Cloudinit
VM.Config.Disk
VM.Config.HWType
VM.Config.Memory
VM.Config.Network
VM.Config.Options
VM.Monitor
VM.PowerMgmt
Datastore.AllocateSpace
Datastore.Audit
Sys.Audit
```

### 3. Create the API token

**Datacenter → Permissions → API Tokens → Add**

- User: `terraform@pve`
- Token ID: `home-ops`
- **Uncheck "Privilege Separation"** (token inherits user's permissions)

Copy the token secret — it is only shown once.

### 4. Assign the role

**Datacenter → Permissions → Add**

- Path: `/`
- Token: `terraform@pve!home-ops`
- Role: `TerraformProvisioner`
- **Propagate: ✓**

---

## One-time CyberArk CCP Setup

### 1. Create the Application

In CyberArk PAM: **Applications → Add Application**

- App ID: `home-ops-terraform`
- Add authentication method (e.g. machine certificate or allowed machine list for your workstation IP)

### 2. Create the Account Object

In the safe `ProxmoxAPI`, create an account:

| Field | Value |
|-------|-------|
| Username | `terraform@pve!home-ops` |
| Password (Content) | `<token secret from step above>` |
| Object name | `proxmox-api-token` |

---

## Remaining `# VERIFY` Items in terraform.tfvars

These values were set based on best-guess defaults. Confirm each before applying:

| Variable | Current Value | How to verify |
|----------|--------------|---------------|
| `proxmox_node` | `pve-r630-01` | Proxmox UI → Datacenter → node list, or `pvesh get /nodes` |
| `storage_pool` | `local-lvm` | Proxmox UI → Datacenter → Storage |
| `template_vm_id` | `9000` | Proxmox UI → VM list; the cloud-init template VM ID |
| `network_bridge` | `vmbr0` | Proxmox UI → node → Network |
| `network_vlan` | `169` | VLAN tag for the `10.2.169.0/24` subnet |
| `gateway` | `10.2.169.1` | pfSense/router IP on VLAN 169 |
| `dns_servers` | `["10.1.30.250", "10.1.30.251"]` | Internal DNS resolvers |

---

## Run Sequence

```bash
cd infrastructure/terraform

# 1. Download providers and create lock file
terraform init

# 2. Commit the lock file (pins provider versions)
git add .terraform.lock.hcl
git commit -m "chore(terraform): pin provider versions"

# 3. Validate config syntax
terraform validate

# 4. Preview changes — requires CCP reachable and App ID set
terraform plan

# 5. Apply — use parallelism=2 to avoid concurrent datastore lock contention
#    (Proxmox serialises full-clone disk ops; all 6 VMs at once causes timeouts)
terraform apply -parallelism=2
```

## After Apply

Terraform outputs the IPs of all created nodes:

```bash
terraform output -json all_node_ips
terraform output first_control_plane_ip
```

Feed `first_control_plane_ip` into the k3s bootstrap playbook / talconfig as
the initial control plane endpoint.
