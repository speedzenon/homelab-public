# MikroTik — OpenTofu

Warstwa L3 MikroTika jako kod: routing inter-VLAN, firewall, DHCP, DNS.

## Uruchamianie

Poswiadczenia wstrzykiwane z SOPS (nigdy w plikach .tf):

```bash
sops exec-env secrets.sops.yaml 'tofu plan'
sops exec-env secrets.sops.yaml 'tofu apply'
```

Stan trzymany lokalnie (gitignored); backup osobno. Docelowo remote backend.
