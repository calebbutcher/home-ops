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
  started  = true

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

  # Disable agent polling — bpg/proxmox ~> 0.66 does not reliably honour the
  # timeout, causing Terraform to hang forever waiting for a guest agent
  # response. Static IPs are assigned via cloud-init so agent is not needed.
  agent {
    enabled = false
    trim    = true
    timeout = "90s"
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
  started    = true

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

  # Disable agent polling — same fix as control_plane nodes.
  agent {
    enabled = false
    trim    = true
    timeout = "90s"
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

  lifecycle {
    ignore_changes = [
      initialization,
      clone,
    ]
  }
}

# ---------------------------------------------------------------------------
# Explicit VM start — work around bpg/proxmox not reliably issuing qm start
# during full clone when started=true is set on the resource.
# ---------------------------------------------------------------------------
resource "null_resource" "start_control_plane" {
  for_each = var.control_plane_nodes

  triggers = {
    vm_id = proxmox_virtual_environment_vm.control_plane[each.key].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sf -k -X POST \
        -H "Authorization: PVEAPIToken=${local.proxmox_token_id}=${local.proxmox_token_secret}" \
        "https://${var.proxmox_host}:8006/api2/json/nodes/${var.proxmox_node}/qemu/${self.triggers.vm_id}/status/start" || true
    EOT
  }

  depends_on = [proxmox_virtual_environment_vm.control_plane]
}

resource "null_resource" "start_worker" {
  for_each = var.worker_nodes

  triggers = {
    vm_id = proxmox_virtual_environment_vm.worker[each.key].id
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -sf -k -X POST \
        -H "Authorization: PVEAPIToken=${local.proxmox_token_id}=${local.proxmox_token_secret}" \
        "https://${var.proxmox_host}:8006/api2/json/nodes/${var.proxmox_node}/qemu/${self.triggers.vm_id}/status/start" || true
    EOT
  }

  depends_on = [
    proxmox_virtual_environment_vm.worker,
    null_resource.start_control_plane,
  ]
}
