# DHCP tylko dla VLAN-ow z dhcp_enabled = true (z network.sops.yaml).
locals {
  dhcp_vlans = { for k, v in local.vlans : k => v if try(v.dhcp_enabled, false) }

  # Rezerwacje czytane z zaszyfrowanego network.sops.yaml (nie hardcode w .tf).
  dhcp_reservations = try(local.net.dhcp_reservations, {})
}

resource "routeros_ip_pool" "this" {
  for_each = local.dhcp_vlans
  name     = "pool-${replace(each.key, "_", "-")}"
  ranges   = ["${each.value.dhcp_range_start}-${each.value.dhcp_range_end}"]
}

resource "routeros_ip_dhcp_server" "this" {
  for_each     = local.dhcp_vlans
  name         = "dhcp-${replace(each.key, "_", "-")}"
  interface    = routeros_interface_vlan.this[each.key].name
  address_pool = routeros_ip_pool.this[each.key].name
  lease_time   = "1h"

  lifecycle {
    # RouterOS sam ustawia dynamic_lease_identifiers (default client-mac,client-id).
    # Nie zarzadzamy nim - akceptujemy default, zeby uniknac ciaglego diffu.
    ignore_changes = [dynamic_lease_identifiers]
  }
}

resource "routeros_ip_dhcp_server_network" "this" {
  for_each   = local.dhcp_vlans
  address    = each.value.cidr
  gateway    = each.value.gateway
  dns_server = [each.value.gateway]   # MikroTik jako resolver (zgodnie z network.sops.yaml)
}

resource "routeros_ip_dhcp_server_lease" "this" {
  for_each    = local.dhcp_reservations
  address     = each.value.ip
  mac_address = each.value.mac
  server      = routeros_ip_dhcp_server.this[each.value.vlan].name
  comment     = "${each.key} (rezerwacja)"
}
