# Schemat adresacji w vlan

.1 brama
.2–.19 urządzenia sieciowe i hosty pve
.20–.99 statyczne usługi/VIP-y
.100–.199 dynamic (DHCP / LB-IPAM)
.200–.249 wolne
.250–.254 specjalne

## VMID gości

Gość ze statycznym adresem z zakresu .20–.99 dostaje VMID wynikający
z VLAN-u i adresu: **VMID = (VLAN / 10) × 100 + ostatni oktet**.
Przykład: VLAN 60, oktet .20 → VMID 620. Numer sam mówi, gdzie gość stoi,
a unikalność wynika z unikalności adresu w VLAN-ie.

- Gość z adresem spoza .20–.99 albo bez stałego adresu: numer x00–x19
  w setce swojego VLAN-u (np. bastion = 100).
- VLAN-y 100 i 110 dają numery czterocyfrowe (10xx, 11xx) — to poprawne VMID.
- Obiekty testowe tworzone ręcznie (GUI): setka 9xx, bez wiązania z adresem.
  Nie koliduje z regułą, bo VLAN `zenon` (90) nie hostuje gości.
- Istniejących gości nie przenumerowujemy: w bpg zmiana `vm_id` odtwarza VM.
- Dla kontenerów z sekcji `lxc` w `network.sops.yaml` regułę sprawdza
  precondition w `infrastructure/proxmox/firewall.tf` — zły VMID zatrzymuje plan.
