# --- Network single source of truth (SOPS) ---
# Wspolne dla calego modulu (talos.tf, firewall.tf, ...), dlatego w osobnym pliku,
# a nie w pliku jednej z warstw - usuniecie/przebudowa talos.tf nie psuje firewalla.
data "sops_file" "network" {
  source_file = "${path.module}/../network.sops.yaml"
}

locals {
  # nonsensitive(): adresy RFC1918 jawne w planie to swiadoma decyzja - pozwala
  # na for_each po danych z SOPS. CI uruchamia tylko validate (danych nie czyta).
  net = nonsensitive(yamldecode(data.sops_file.network.raw))

  # Logiczne nazwy hostow (SOPS) -> nazwy nodow PVE (hostname).
  pve_node = {
    gflip  = "proxmox"
    wtrmax = "nas"
    odroid = "odroid"
  }
}
