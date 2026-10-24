# Endpoint i poswiadczenia czytane ze zmiennych srodowiskowych:
#   PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN, PROXMOX_VE_INSECURE
# Wstrzykiwane przez `sops exec-env` z secrets.sops.yaml.
# api_token (format user@realm!id=uuid) zamiast hasla; insecure=true (cert self-signed).
provider "proxmox" {
  # Import dysku (qm disk import) idzie po SSH na noda - wymagane do tworzenia VM z obrazu.
  # Token nie ma hasla do dziedziczenia, wiec klucz z ssh-agenta + user root.
  # try(): brak pliku klucza (CI, inna maszyna) nie wywraca validate/plan -
  # zostaje sam ssh-agent. Gdy plik jest, dzialanie bez zmian.
  ssh {
    agent       = true
    username    = "root"
    private_key = try(file(pathexpand("~/.ssh/id_ed25519")), null)
  }
}
