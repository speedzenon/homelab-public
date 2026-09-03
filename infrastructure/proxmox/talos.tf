# --- Network single source of truth (SOPS) ---
data "sops_file" "network" {
  source_file = "${path.module}/../network.sops.yaml"
}

locals {
  net = nonsensitive(yamldecode(data.sops_file.network.raw))

  # Logiczne nazwy hostow (SOPS) -> nazwy nodow PVE (hostname).
  pve_node = {
    gflip  = "proxmox"
    wtrmax = "nas"
    odroid = "odroid"
  }

  k8s_vlan   = local.net.vlans.k8s
  k8s_prefix = split("/", local.k8s_vlan.cidr)[1] # "24"
  lab_nodes  = local.net.k8s_clusters.lab.nodes   # mapa: nazwa -> { vmid, ip, host, role }
}

# --- Obraz Talos (Image Factory), pobierany na kazdy host z wezlami (dedup) ---
resource "proxmox_virtual_environment_download_file" "talos" {
  for_each = toset([for n in local.lab_nodes : local.pve_node[n.host]])

  content_type            = "iso"
  datastore_id            = "local"
  node_name               = each.key
  url                     = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/nocloud-amd64.raw.zst"
  decompression_algorithm = "zst"
  file_name               = "talos-v${var.talos_version}-nocloud-amd64.img"
  overwrite               = false
}

# --- Wezly lab-klastra Talos (for_each po odkomentowanych w SOPS) ---
module "talos_lab" {
  source   = "./modules/vm"
  for_each = local.lab_nodes

  node_name       = local.pve_node[each.value.host]
  vm_id           = each.value.vmid
  name            = each.key
  tags            = ["tofu", "talos", "lab", "k8s"]
  cores           = 4
  memory          = 8192
  disk_size       = 40
  datastore_id    = "local-zfs"
  image_file_id   = proxmox_virtual_environment_download_file.talos[local.pve_node[each.value.host]].id
  ip_cidr         = "${each.value.ip}/${local.k8s_prefix}"
  gateway         = local.k8s_vlan.gateway
  vlan_id         = local.k8s_vlan.id
  storage_vlan_id = local.net.vlans.storage.id
  storage_mac     = each.value.storage_mac
}
