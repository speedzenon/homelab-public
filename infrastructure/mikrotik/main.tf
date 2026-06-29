data "sops_file" "network" {
  source_file = "${path.module}/../network.sops.yaml"
}

locals {
  net   = nonsensitive(yamldecode(data.sops_file.network.raw))
  vlans = local.net.vlans
}

# Interfejsy VLAN
# Addytywne; nieaktywne do czasu wlaczenia bridge VLAN filtering.
resource "routeros_interface_vlan" "this" {
  for_each = local.vlans

  name      = "vlan-${replace(each.key, "_", "-")}"
  vlan_id   = each.value.id
  interface = "bridge"
}

resource "routeros_ip_address" "gw" {
  for_each = { for k, v in local.vlans : k => v if try(v.routed, true) }

  address   = "${each.value.gateway}/24"
  interface = routeros_interface_vlan.this[each.key].name
  comment   = "vlan-${replace(each.key, "_", "-")} gateway (OpenTofu)"
}
