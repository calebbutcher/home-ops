# ---------------------------------------------------------------------------
# Control-plane nodes
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "control_plane" {
  for_each = var.control_plane_nodes

  name      = each.key
  node_name = var.proxmox_node
  tags      = ["k8s", "control-plane", "terraform"]

  # Clone from cloud-init template
  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  # Prevent accidental deletion
  protection = false

  on_boot = true

  cpu {
    cores   = each.value.vcpus
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.storage_pool
    size         = each.value.disk_gb
    interface    = "scsi0"
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge   = var.network_bridge
    model    = "virtio"
    vlan_id  = var.network_vlan
    firewall = false
  }

  operating_system {
    type = var.vm_os_type
  }

  # Agent must be installed in the template
  agent {
    enabled = true
    trim    = true
  }

  # cloud-init
  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.subnet_prefix}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.search_domain
    }

    user_account {
      username = var.vm_username
      keys     = [var.ssh_public_key]
    }
  }

  timeouts {
    create = "15m"
    read   = "5m"
    update = "10m"
    delete = "5m"
  }

  lifecycle {
    ignore_changes = [
      # Prevent drift from in-place cloud-init changes after first apply
      initialization,
      clone,
    ]
  }
}

# ---------------------------------------------------------------------------
# Worker nodes
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "worker" {
  for_each = var.worker_nodes

  name      = each.key
  node_name = var.proxmox_node
  tags      = ["k8s", "worker", "terraform"]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  protection = false
  on_boot    = true

  cpu {
    cores   = each.value.vcpus
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.storage_pool
    size         = each.value.disk_gb
    interface    = "scsi0"
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge   = var.network_bridge
    model    = "virtio"
    vlan_id  = var.network_vlan
    firewall = false
  }

  operating_system {
    type = var.vm_os_type
  }

  agent {
    enabled = true
    trim    = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.subnet_prefix}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.search_domain
    }

    user_account {
      username = var.vm_username
      keys     = [var.ssh_public_key]
    }
  }

  # Wait for all control-plane VMs before starting workers to reduce
  # concurrent datastore lock contention during full clones.
  depends_on = [proxmox_virtual_environment_vm.control_plane]

  timeouts {
    create = "15m"
    read   = "5m"
    update = "10m"
    delete = "5m"
  }

  lifecycle {
    ignore_changes = [
      initialization,
      clone,
    ]
  }
}
