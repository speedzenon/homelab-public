output "vm_id" { value = proxmox_virtual_environment_vm.this.vm_id }
output "name"  { value = proxmox_virtual_environment_vm.this.name }
output "ipv4"  { value = var.ip_cidr }
