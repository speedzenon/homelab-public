# MikroTik — OpenTofu

Warstwa L3 MikroTika jako kod: interfejsy VLAN, adresy bram, pule i serwery DHCP
oraz rezerwacje (wszystko z `../network.sops.yaml`), a z DNS rekord `int.<domena>`
dla Gatewaya klastra (`dns.tf`). Firewall, WireGuard i pozostałe wpisy DNS są
na razie konfigurowane ręcznie — docelowo tutaj.

`dns.tf` czyta też manifest Gatewaya z `kubernetes/infrastructure/gateway/` i zatrzymuje
plan, gdy adres lub domena w SOPS różnią się od tych w klastrze.

## Uruchamianie

Poswiadczenia wstrzykiwane z SOPS (nigdy w plikach .tf):

```bash
just tofu-plan mikrotik    # = sops exec-env secrets.sops.yaml 'tofu plan'
just tofu-apply mikrotik
```

Stan trzymany lokalnie (gitignored); backup osobno. Docelowo remote backend.
