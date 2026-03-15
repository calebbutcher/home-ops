# ---------------------------------------------------------------------------
# CyberArk CCP
# ---------------------------------------------------------------------------
ccp_host   = "ccp.home.arpa"       # VERIFY: CCP appliance hostname/IP
ccp_safe   = "HLB-Hypervisor-Root" # Must match the safe created in PAM
ccp_object = "proxmox-api-token"   # Must match the account object name in PAM

# ---------------------------------------------------------------------------
# Proxmox
# ---------------------------------------------------------------------------
proxmox_host         = "pve.home.arpa"  # VERIFY: your Proxmox node FQDN or IP
proxmox_tls_insecure = true             # Set false once you have a valid cert
proxmox_node         = "pve"            # VERIFY: output of `pvesh get /nodes | grep node`
storage_pool         = "local-lvm"      # VERIFY: pool shown in Proxmox → Datacenter → Storage
template_vm_id       = 9000             # VERIFY: VM ID of your cloud-init template
network_bridge       = "vmbr0"          # VERIFY: bridge used for your lab VLAN
network_vlan         = 20               # VERIFY: VLAN tag for the k8s subnet; null = untagged

# ---------------------------------------------------------------------------
# Networking — verify these don't overlap existing lab subnets
# ---------------------------------------------------------------------------
gateway       = "10.10.20.1"            # VERIFY: pfSense IP on this VLAN
subnet_prefix = 24
dns_servers   = ["10.10.20.1"]          # VERIFY: points at pfSense (or your DNS resolver)
search_domain = "home.arpa"

# ---------------------------------------------------------------------------
# VM defaults
# ---------------------------------------------------------------------------
vm_username    = "ops"
ssh_public_key = "ssh-ed25519 AAAA... your-key-here"  # REPLACE: output of `cat ~/.ssh/id_ed25519.pub`

# ---------------------------------------------------------------------------
# Kubernetes — control plane (3 nodes for HA etcd)
# ---------------------------------------------------------------------------
control_plane_nodes = {
  "k8s-cp-01" = { ip = "10.10.20.11", vcpus = 2, memory_mb = 4096, disk_gb = 40 }
  "k8s-cp-02" = { ip = "10.10.20.12", vcpus = 2, memory_mb = 4096, disk_gb = 40 }
  "k8s-cp-03" = { ip = "10.10.20.13", vcpus = 2, memory_mb = 4096, disk_gb = 40 }
}

# ---------------------------------------------------------------------------
# Kubernetes — workers
# ---------------------------------------------------------------------------
worker_nodes = {
  "k8s-wk-01" = { ip = "10.10.20.21", vcpus = 4, memory_mb = 8192, disk_gb = 80 }
  "k8s-wk-02" = { ip = "10.10.20.22", vcpus = 4, memory_mb = 8192, disk_gb = 80 }
  "k8s-wk-03" = { ip = "10.10.20.23", vcpus = 4, memory_mb = 8192, disk_gb = 80 }
}
