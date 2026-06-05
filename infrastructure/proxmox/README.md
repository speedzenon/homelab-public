# Proxmox VE — OpenTofu

Provisioning Proxmox VE jako kod. Na teraz: walidacja dostępu do API (read-only
data source listujący nody klastra). Docelowo: definicje VM/LXC (node'y k3s/Talos)
przez providera `bpg/proxmox`.

## Uruchamianie

Endpoint i poświadczenia (API token) wstrzykiwane z SOPS — nigdy w plikach `.tf`:

    sops exec-env secrets.sops.yaml 'tofu plan'
    sops exec-env secrets.sops.yaml 'tofu apply'

Providera konfigurują zmienne środowiskowe: `PROXMOX_VE_ENDPOINT`,
`PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_INSECURE`.

Stan trzymany lokalnie (gitignored); backup osobno. Docelowo remote backend.
