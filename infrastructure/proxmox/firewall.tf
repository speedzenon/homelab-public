# UWAGA: 'management' to WBUDOWANY, ZNACZACY ipset PVE - czlonkowie sa
# automatycznie wpuszczani na porty zarzadzania hostow (GUI 8006, SSH 22,
# VNC 5900-5999, SPICE 3128) przez reguly generowane przez pve-firewall.
# Siec klastra dokladana automatycznie. Dlatego NIE ma osobnej grupy dla
# mgmt - ten ipset JEST mechanizmem, nazwa jest znaczaca, nie dekoracyjna.

locals {
  fw_mgmt_sources = [
    local.net.vlans.oob_mgmt.cidr, # bastion/hosty
    local.net.vlans.zenon.cidr,    # Twoja stacja
  ]
  fw_storage_cidr = local.net.vlans.storage.cidr

  # kontener z sekcji lxc -> grupa uslug, ktore wystawia (nazwa grupy = kontener + "-srv")
  fw_lxc_sg = {
    jellyfin  = proxmox_virtual_environment_cluster_firewall_security_group.jellyfin_srv.name
    downloads = proxmox_virtual_environment_cluster_firewall_security_group.downloads_srv.name
    arr       = proxmox_virtual_environment_cluster_firewall_security_group.arr_srv.name
  }

  # VMID z konwencji: (VLAN/10)*100 + ostatni oktet (docs/runbooks/local-addressing.md)
  fw_lxc_vmid = {
    for name, ct in local.net.lxc :
    name => floor(local.net.vlans[ct.vlan].id / 10) * 100 + tonumber(split(".", ct.ip)[3])
  }
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

# Te same zrodla co 'management', ale osobny zbior: 'management' steruje dostepem
# do HOSTOW (i ma doklejana siec klastra), ten - do uslug w gosciach.
resource "proxmox_virtual_environment_firewall_ipset" "admin" {
  name    = "admin"
  comment = "Zrodla administracyjne dla uslug w gosciach"
  dynamic "cidr" {
    for_each = local.fw_mgmt_sources
    content { name = cidr.value }
  }
}

# Alias na kazdy kontener z sekcji lxc - reguly odwoluja sie do nazw, nie adresow.
resource "proxmox_virtual_environment_firewall_alias" "lxc" {
  for_each = local.net.lxc
  name     = each.key
  cidr     = each.value.ip
  comment  = "CT ${each.value.vmid} (${each.value.vlan})"
}


resource "proxmox_virtual_environment_cluster_firewall_security_group" "storage_srv" {
  name    = "storage-srv"
  comment = "uslugi storage nas na VLAN 50 (iSCSI + NFS)"
  # UWAGA co do portu 111: serwer NFS jest v4-only (vers3=n), ale PVE sprawdza
  # dostepnosc storage NFS poleceniem 'showmount -e', ktore nalezy do protokolu
  # mount z rodziny v3 i chodzi przez rpcbind na 111. Przy polityce DROP pakiet
  # ginie bez odpowiedzi -> showmount czeka do timeoutu (~10s na storage).
  # Objaw: kreator VM w GUI wisi ~20s i wywala sie na NS_BINDING_ABORTED, bo
  # ExtJS anuluje zadanie zanim wroci. Samo montowanie v4 dziala bez 111 -
  # zepsute bylo tylko SPRAWDZANIE dostepnosci.
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.fw_storage_cidr
    dport   = "3260"
    proto   = "tcp"
    comment = "iSCSI (democratic-csi)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.fw_storage_cidr
    dport   = "2049"
    proto   = "tcp"
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
    dport   = "111"
    proto   = "tcp"
    comment = "rpcbind - showmount przy sprawdzaniu storage NFS przez PVE"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.fw_storage_cidr
    dport   = "111"
    proto   = "udp"
    comment = "rpcbind UDP - jw, showmount probuje obu protokolow"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.fw_storage_cidr
    proto   = "icmp"
    comment = "ICMP - diagnostyka w segmencie storage"
  }
}

resource "proxmox_virtual_environment_cluster_firewall_security_group" "jellyfin_srv" {
  name    = "jellyfin-srv"
  comment = "Jellyfin: klienci i odswiezanie biblioteki"
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.net.vlans.home.cidr
    dport   = "8096"
    proto   = "tcp"
    comment = "domownicy (VLAN home)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = local.net.vlans.zenon.cidr
    dport   = "8096"
    proto   = "tcp"
    comment = "zaufane urzadzenia (VLAN zenon)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = proxmox_virtual_environment_firewall_alias.lxc["arr"].name
    dport   = "8096"
    proto   = "tcp"
    comment = "Sonarr i Radarr - odswiezanie biblioteki"
  }
}

resource "proxmox_virtual_environment_cluster_firewall_security_group" "downloads_srv" {
  name    = "downloads-srv"
  comment = "qBittorrent za gluetunem: API i panel"
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = proxmox_virtual_environment_firewall_alias.lxc["arr"].name
    dport   = "8080"
    proto   = "tcp"
    comment = "Sonarr i Radarr"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${proxmox_virtual_environment_firewall_ipset.admin.name}"
    dport   = "8080"
    proto   = "tcp"
    comment = "panel z sieci admin"
  }
}

resource "proxmox_virtual_environment_cluster_firewall_security_group" "arr_srv" {
  name    = "arr-srv"
  comment = "Panele Prowlarr, Sonarr, Radarr, Bazarr"
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${proxmox_virtual_environment_firewall_ipset.admin.name}"
    dport   = "9696,8989,7878,6767"
    proto   = "tcp"
    comment = "panele z sieci admin"
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

# Grupa uslug podpieta do kazdego kontenera z sekcji lxc
resource "proxmox_virtual_environment_firewall_rules" "lxc" {
  for_each = local.net.lxc

  node_name    = local.pve_node[each.value.host]
  container_id = each.value.vmid
  rule {
    security_group = local.fw_lxc_sg[each.key]
  }

  lifecycle {
    # Zly VMID w SOPS = reguly na cudzym kontenerze.
    precondition {
      condition     = each.value.vmid == local.fw_lxc_vmid[each.key]
      error_message = "${each.key}: VMID ${each.value.vmid} w SOPS, a z VLAN-u i oktetu wychodzi ${local.fw_lxc_vmid[each.key]}."
    }
  }
}

# Firewall gosci wlaczony, wejscie DROP - dopiero gdy reguly juz stoja (depends_on).
resource "proxmox_virtual_environment_firewall_options" "lxc" {
  for_each = local.net.lxc

  node_name     = local.pve_node[each.value.host]
  container_id  = each.value.vmid
  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  ipfilter      = true
  macfilter     = true
  dhcp          = false # adresy statyczne
  ndp           = false # IPv6 nieuzywane; po wlaczeniu IPv6 -> true
  radv          = false # gosc nie moze oglaszac sie jako router IPv6
  depends_on    = [proxmox_virtual_environment_firewall_rules.lxc]
}
