output "control_plane_ips" {
  description = "IP addresses of control-plane nodes, keyed by VM name."
  value = {
    for name, vm in proxmox_virtual_environment_vm.control_plane :
    name => vm.initialization[0].ip_config[0].ipv4[0].address
  }
}

output "worker_ips" {
  description = "IP addresses of worker nodes, keyed by VM name."
  value = {
    for name, vm in proxmox_virtual_environment_vm.worker :
    name => vm.initialization[0].ip_config[0].ipv4[0].address
  }
}

output "control_plane_vm_ids" {
  description = "Proxmox VM IDs for control-plane nodes."
  value = {
    for name, vm in proxmox_virtual_environment_vm.control_plane :
    name => vm.vm_id
  }
}

output "worker_vm_ids" {
  description = "Proxmox VM IDs for worker nodes."
  value = {
    for name, vm in proxmox_virtual_environment_vm.worker :
    name => vm.vm_id
  }
}

# Convenience: flat list of all node IPs for use in Ansible inventory or kubeadm
output "all_node_ips" {
  description = "All cluster node IPs (control-plane first, then workers)."
  value = concat(
    [for _, vm in proxmox_virtual_environment_vm.control_plane : vm.initialization[0].ip_config[0].ipv4[0].address],
    [for _, vm in proxmox_virtual_environment_vm.worker : vm.initialization[0].ip_config[0].ipv4[0].address],
  )
}

output "first_control_plane_ip" {
  description = "IP of the first control-plane node — used as the bootstrap endpoint for kubeadm/k3s."
  value       = values(proxmox_virtual_environment_vm.control_plane)[0].initialization[0].ip_config[0].ipv4[0].address
}
