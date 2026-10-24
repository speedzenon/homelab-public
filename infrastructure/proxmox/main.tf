# Smoke-test autentykacji: read-only data source listujacy nody klastra.
# Zasoby zyja obok: network.tf (dane sieci z SOPS), talos.tf (obraz + VM-ki Talos),
# firewall.tf (firewall PVE).
# Oczekiwany wynik: cluster_nodes = ["nas", "proxmox"] (kolejnosc dowolna).
data "proxmox_virtual_environment_nodes" "this" {}

output "cluster_nodes" {
  description = "Nody widziane przez PVE API - walidacja auth + osiagalnosci."
  value       = data.proxmox_virtual_environment_nodes.this.names
}
