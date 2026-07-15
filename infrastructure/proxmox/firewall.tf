locals {
  fw_mgmt_sources = [
    local.net.vlans.oob_mgmt.cidr,   # bastion/hosty
    local.net.vlans.zenon.cidr,      # Twoja stacja
  ]
  fw_storage_cidr = local.net.vlans.storage.cidr
}

resource "proxmox_virtual_environment_cluster_firewall" "firewall" {
  enabled = true
}

resource "proxmox_virtual_environment_firewall_ipset" "management" {
  name    = "management"
  comment = "Siec klastra + Vlan zenon"
  dynamic "cidr" {
    for_each = local.fw_mgmt_sources
    content { name = cidr.value }
  }
}

resource "proxmox_virtual_environment_cluster_firewall_security_group" "pve_mgmt" {
  name    = "pve-mgmt"
  comment = "dostep do hostow PVE"
  rule {
    type = "in"
    action = "ACCEPT"
    source = "+management"
    dport = "8006"
    proto = "tcp"
    comment = "GUI"
  }
  rule {
    type = "in"
    action = "ACCEPT"
    source = "+management"
    dport = "22"
    proto = "tcp"
    comment = "SSH"
  }
}

resource "proxmox_virtual_environment_cluster_firewall_security_group" "storage_srv" {
  name    = "storage-srv"
  comment = "uslugi storage nas na VLAN 50 (iSCSI + NFS)"
  rule {
    type = "in"
    action = "ACCEPT"
    source = local.fw_storage_cidr
    dport = "3260"
    proto = "tcp"
    comment = "iSCSI (democratic-csi)"
  }
  rule {
    type = "in"
    action = "ACCEPT"
    source = local.fw_storage_cidr
    dport = "2049"
    proto = "tcp"
    comment = "NFS v4 (PVE shared + shares)"
  }
}
