# Proxmox VE — OpenTofu

Provisioning Proxmox VE jako kod (provider `bpg/proxmox`):

- `network.tf` — dane sieci z `../network.sops.yaml` (`local.net`) i mapowanie
  nazw hostów na nody PVE (`local.pve_node`), wspólne dla całego modułu,
- `talos.tf` — obraz Talos z Image Factory i VM-ki węzłów klastra `lab`
  (moduł `modules/vm`; adresy, MAC-i i VMID z `../network.sops.yaml`,
  wersja Talosa z `talos/versions.yaml`),
- `firewall.tf` — firewall PVE (ipset `management`, grupa `storage-srv` na `nas`),
- `main.tf` — read-only smoke-test API (`cluster_nodes`).

## Uruchamianie

Endpoint i poświadczenia (API token) wstrzykiwane z SOPS — nigdy w plikach `.tf`:

    just tofu-plan        # = sops exec-env secrets.sops.yaml 'tofu plan'
    just tofu-apply

Providera konfigurują zmienne środowiskowe: `PROXMOX_VE_ENDPOINT`,
`PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_INSECURE`.

Stan trzymany lokalnie (gitignored); backup osobno. Docelowo remote backend.
