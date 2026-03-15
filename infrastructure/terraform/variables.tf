# ---------------------------------------------------------------------------
# CyberArk CCP
# ---------------------------------------------------------------------------
variable "ccp_host" {
  description = "Hostname (or IP) of the CyberArk CCP appliance."
  type        = string
}

variable "ccp_safe" {
  description = "PAM Safe containing the Proxmox API token object."
  type        = string
}

variable "ccp_object" {
  description = "PAM account object name for the Proxmox API token."
  type        = string
}

# ---------------------------------------------------------------------------
# Proxmox
# ---------------------------------------------------------------------------
variable "proxmox_host" {
  description = "Proxmox VE host FQDN or IP (without port or scheme)."
  type        = string
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS verification for the Proxmox API (set true for self-signed certs)."
  type        = bool
  default     = false
}

variable "proxmox_node" {
  description = "Proxmox node name on which VMs will be created."
  type        = string
}

variable "storage_pool" {
  description = "Proxmox storage pool for VM disks (e.g. local-lvm, ceph-pool)."
  type        = string
}

variable "template_vm_id" {
  description = "VM ID of the cloud-init template to clone."
  type        = number
}

variable "network_bridge" {
  description = "Proxmox Linux bridge for VM NICs (e.g. vmbr0)."
  type        = string
}

variable "network_vlan" {
  description = "VLAN tag to apply to VM NICs. Set to null for untagged."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "gateway" {
  description = "Default IPv4 gateway for all VMs."
  type        = string
}

variable "subnet_prefix" {
  description = "CIDR prefix length for the VM subnet (e.g. 24 for /24)."
  type        = number
  default     = 24
}

variable "dns_servers" {
  description = "List of DNS servers to inject via cloud-init (point at pfSense)."
  type        = list(string)
}

variable "search_domain" {
  description = "DNS search domain for VMs."
  type        = string
}

# ---------------------------------------------------------------------------
# VM defaults
# ---------------------------------------------------------------------------
variable "vm_username" {
  description = "Default OS user created via cloud-init."
  type        = string
  default     = "ops"
}

variable "ssh_public_key" {
  description = "SSH public key injected into all VMs via cloud-init."
  type        = string
  sensitive   = true
}

variable "vm_os_type" {
  description = "Guest OS type hint for Proxmox (l26 = Linux 5.x+)."
  type        = string
  default     = "l26"
}

# ---------------------------------------------------------------------------
# Kubernetes nodes
# ---------------------------------------------------------------------------
variable "control_plane_nodes" {
  description = "Map of control-plane VM names to their individual configuration."
  type = map(object({
    ip        = string
    vcpus     = number
    memory_mb = number
    disk_gb   = number
  }))
}

variable "worker_nodes" {
  description = "Map of worker VM names to their individual configuration."
  type = map(object({
    ip        = string
    vcpus     = number
    memory_mb = number
    disk_gb   = number
  }))
}
