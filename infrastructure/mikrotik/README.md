# MikroTik — OpenTofu

Warstwa L3 MikroTika jako kod: interfejsy VLAN, adresy bram, pule i serwery DHCP
oraz rezerwacje (wszystko z `../network.sops.yaml`). Firewall, DNS i WireGuard są
na razie konfigurowane ręcznie — docelowo tutaj.

## Uruchamianie

Poswiadczenia wstrzykiwane z SOPS (nigdy w plikach .tf):

```bash
just tofu-plan mikrotik    # = sops exec-env secrets.sops.yaml 'tofu plan'
just tofu-apply mikrotik
```

Stan trzymany lokalnie (gitignored); backup osobno. Docelowo remote backend.
