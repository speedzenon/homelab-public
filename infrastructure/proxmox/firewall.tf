# UWAGA: 'management' to WBUDOWANY, ZNACZACY ipset PVE - czlonkowie sa
# automatycznie wpuszczani na porty zarzadzania hostow (GUI 8006, SSH 22,
# VNC 5900-5999, SPICE 3128) przez reguly generowane przez pve-firewall.
# Siec klastra dokladana automatycznie. Dlatego NIE ma osobnej grupy dla
# mgmt - ten ipset JEST mechanizmem, nazwa jest znaczaca, nie dekoracyjna.

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
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.fw_storage_cidr
    dport   = "22"
    proto   = "tcp"
    comment = "SSH - kanal sterowania democratic-csi"
  }
    rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.fw_storage_cidr
    proto   = "icmp"
    comment = "ICMP - diagnostyka w segmencie storage"
  }
}

# Grupa podpieta dla nas - dla uslugi storage
resource "proxmox_virtual_environment_firewall_rules" "nas_storage" {
  node_name = "nas"
  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.storage_srv.name
    comment        = "uslugi storage nas (VLAN 50)"
  }
}
