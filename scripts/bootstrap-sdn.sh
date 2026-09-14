#!/usr/bin/env bash
# Bootstrap SDN: nazwane sieci (VNet) w kreatorze VM zamiast pamietania tagow VLAN.
#
# DLACZEGO SKRYPT, A NIE OPENTOFU: provider bpg (0.112.0, stan 09.2026) nie ma
# zasobow SDN. Do czasu az sie pojawia, to jest odtwarzalna specyfikacja w repo -
# nie klikanie, ktorego nikt nie odtworzy. Gdy bpg doda wsparcie, ta tabela
# przepisuje sie 1:1 na zasoby.
#
# ZAKRES: dotyczy WYLACZNIE recznie stawianych VM testowych. Wezly Talos sa
# zarzadzane przez OpenTofu (bridge=vmbr0,tag=30 w module VM) i NIE sa migrowane
# na VNet - konwersja oznaczalaby rekreacje interfejsow.
#
# Konfiguracja SDN jest KLASTROWA (/etc/pve/sdn/) - uruchomic RAZ, z dowolnego wezla.
# Uruchamiac jako root na wezle PVE.

set -euo pipefail

ZONE="homelab"
BRIDGE="vmbr0"

# nazwa VNet:tag:opis
# UWAGA: nazwa VNet ma limit 8 znakow i staje sie nazwa interfejsu na hoscie -
# stad 'obsv' zamiast 'observability'.
VNETS=(
  "mgmt:10:Management - PVE, BMC, switche"
  "infra:20:DNS, PKI Step-CA, OpenBao"
  "k8s:30:Wezly Talos (tylko dla recznych VM - Talos idzie z OpenTofu)"
  "servers:40:VM-ki nie-k8s (DHCP .100-.200)"
  "dmz:60:Uslugi wystawione na zewnatrz"
  "obsv:70:Monitoring - Prometheus, Grafana, Loki"
  "iot:80:Urzadzenia IoT (DHCP .100-.200)"
  "zenon:90:Zaufane urzadzenia (DHCP .100-.200)"
  "home:100:Domownicy, izolowane od homelabu"
  "lab:110:Sandbox na eksperymenty (DHCP .100-.200)"
)
# CELOWO POMINIETY: storage (VLAN 50). Segment jest nieroutowany i bez DHCP -
# VM-ka tam postawiona nie ma bramy ani internetu. Hosty maja wlasny vmbr0.50
# dla NFS/iSCSI i to wystarcza. Dodac tylko jesli pojawi sie VM realnie
# potrzebujaca sciezki storage (np. testy KubeVirt).

echo "== Strefa SDN typu VLAN na ${BRIDGE} =="
if pvesh get /cluster/sdn/zones --output-format json | grep -q "\"zone\":\"${ZONE}\""; then
  echo "   strefa ${ZONE} juz istnieje - pomijam"
else
  pvesh create /cluster/sdn/zones --zone "${ZONE}" --type vlan --bridge "${BRIDGE}"
  echo "   utworzono strefe ${ZONE}"
fi

echo
echo "== VNet-y =="
for entry in "${VNETS[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  tag="${rest%%:*}"
  alias="${rest#*:}"

  if pvesh get /cluster/sdn/vnets --output-format json | grep -q "\"vnet\":\"${name}\""; then
    echo "   ${name} (tag ${tag}) - juz istnieje, pomijam"
    continue
  fi
  pvesh create /cluster/sdn/vnets \
    --vnet "${name}" \
    --zone "${ZONE}" \
    --tag "${tag}" \
    --alias "${alias}"
  echo "   ${name} -> tag ${tag}"
done

echo
echo "== Apply (wypchniecie konfiguracji na hosty) =="
# Bez tego kroku wpisy istnieja tylko jako konfiguracja "pending" i nie pojawia
# sie w kreatorze VM.
pvesh set /cluster/sdn

echo
echo "Gotowe. Weryfikacja:"
echo "  pvesh get /cluster/sdn/vnets"
echo "W kreatorze VM pole Bridge pokaze teraz nazwy zamiast vmbr0 + reczny tag."
