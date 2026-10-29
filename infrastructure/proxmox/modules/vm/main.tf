terraform {
  required_providers {
    proxmox = { source = "bpg/proxmox", version = "~> 0.119.0" }
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
      interface    = disk.value.interface # np. scsi1, scsi2
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

  # MAC eth0 przypiety (gdy podany): Talos wybiera interfejs po hardwareAddr,
  # wiec losowy MAC po odtworzeniu VM zerwalby konfiguracje sieci wezla.
  # upper(): PVE generuje MAC wielkimi literami - ten sam zapis = brak diffu.
  network_device {
    bridge      = "vmbr0"
    vlan_id     = var.vlan_id
    mac_address = var.mac_address == null ? null : upper(var.mac_address)
  }

  dynamic "network_device" {
    for_each = var.storage_vlan_id == null ? [] : [1]
    content {
      bridge      = "vmbr0"
      vlan_id     = var.storage_vlan_id
      mac_address = var.storage_mac
    }
  }

  operating_system { type = "l26" }

  lifecycle {
    # Obraz boot liczy sie tylko przy TWORZENIU VM; file_id jest ForceNew w bpg,
    # wiec nowa wersja Talosa w talos/versions.yaml odtworzylaby wszystkie
    # wezly (utrata etcd). Upgrade idzie in-place: 'just talos-upgrade'.
    # Swiadoma przebudowa wezla: tofu apply -replace='module.talos_lab["<wezel>"]...'
    ignore_changes = [disk[0].file_id]
  }
}
