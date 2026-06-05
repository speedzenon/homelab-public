# Endpoint i poswiadczenia czytane ze zmiennych srodowiskowych:
#   PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN, PROXMOX_VE_INSECURE
# Wstrzykiwane przez `sops exec-env` z secrets.sops.yaml.
# api_token (format user@realm!id=uuid) zamiast hasla; insecure=true (cert self-signed).
provider "proxmox" {}
