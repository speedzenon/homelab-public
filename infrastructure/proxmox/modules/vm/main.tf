terraform {
  required_providers {
    proxmox = { source = "bpg/proxmox", version = "~> 0.109.0" }
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  node_name       = var.node_name
  vm_id           = var.vm_id
  name            = var.name
  tags            = var.tags
  on_boot         = var.on_boot
  stop_on_destroy = true

  agent { enabled = true }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }
  memory {
    dedicated = var.memory
    floating  = var.memory
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.datastore_id
    file_id      = var.image_file_id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = var.disk_size
  }

  dynamic "disk" {
    for_each = var.extra_disks
    content {
      datastore_id = disk.value.datastore_id
      interface    = disk.value.interface   # np. scsi1, scsi2
      iothread     = true
      discard      = "on"
      size         = disk.value.size
    }
  }

  initialization {
    datastore_id = var.datastore_id
    ip_config {
      ipv4 {
        address = var.ip_cidr
        gateway = var.gateway
      }
    }
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = var.vlan_id
  }

  operating_system { type = "l26" }
}
