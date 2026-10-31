# Statyczne rekordy DNS. MikroTik jest resolverem dla VLAN-ow z DHCP (dhcp.tf),
# wiec rekord dziala dla wszystkich klientow bez zmian po ich stronie.

locals {
  gateway_internal_ip = local.net.k8s_clusters.lab.lb_reserved["gateway-internal"]
  int_domain          = local.net.domains.int

  # Manifest Gatewaya z repo k8s: Argo nie czyta SOPS, wiec adres i domena sa tam
  # jawnie. Czytamy go tylko po to, by sprawdzic zgodnosc z SOPS (preconditions nizej).
  gateway_internal = yamldecode(file("${path.module}/../../kubernetes/infrastructure/gateway/gateway-internal.yaml"))
}

# int.<domena> i wszystkie poddomeny -> Gateway 'internal' w klastrze lab.
# Jeden rekord na cala przestrzen uslug: nowa usluga to sam HTTPRoute w klastrze,
# bez zmian tutaj. Nie dodawac recznych wpisow, ktore sie z nim nakladaja (np. regexp
# na cala domene) - przy nakladajacych sie wpisach kolejnosc na liscie nie decyduje,
# ktory odpowie.
resource "routeros_ip_dns_record" "k8s_lab_gateway_internal" {
  name            = local.int_domain
  match_subdomain = true
  type            = "A"
  address         = local.gateway_internal_ip
  comment         = "k8s lab: Gateway internal (OpenTofu)"

  lifecycle {
    precondition {
      condition     = contains(local.gateway_internal.spec.addresses[*].value, local.gateway_internal_ip)
      error_message = "lb_reserved.gateway-internal w network.sops.yaml nie zgadza sie ze spec.addresses w kubernetes/infrastructure/gateway/gateway-internal.yaml."
    }
    precondition {
      condition     = contains([for l in local.gateway_internal.spec.listeners : try(l.hostname, "")], "*.${local.int_domain}")
      error_message = "domains.int w network.sops.yaml nie zgadza sie z hostname listenerow w kubernetes/infrastructure/gateway/gateway-internal.yaml."
    }
  }
}
