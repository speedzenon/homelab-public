# Ansible — konfiguracja gości Proxmoxa

Konfiguracja wnętrza VM-ek (później także kontenerów LXC). Dlaczego Ansible i jak dzieli
pracę z OpenTofu: `docs/adr/0001-ansible-dla-gosci-proxmoxa.md`.

```text
infrastructure/ansible/
├── ansible.cfg              inventory, role, kolekcje: pobrane w .ansible/ (poza gitem) + collections/
├── pyproject.toml, uv.lock  ansible-core w dokładnej wersji (uv)
├── requirements.yml         kolekcje w dokładnych wersjach
├── inventories/lab/         gości z SOPS; adresy NIE tutaj, tylko w network.sops.yaml
├── collections/ansible_collections/speedzenon/homelab/
│   │                        kolekcja ról wspólnych z prywatnym repo homelab-home (ADR 0003)
│   └── roles/
│       ├── debian_base/     Python, strefa czasowa, aktualizacje, agent QEMU
│       └── podman/          rootless podman dla użytkowników + tygodniowe sprzątanie
├── roles/                   role tylko tego repo
│   └── forgejo_runner/      runner Forgejo Actions + samowyłączanie VM (docs/runbooks/forgejo-runner.md)
├── secrets/                 pliki *.sops.yaml dla ról (np. sekret runnera)
└── runner.yml               playbook: VM runnera
```

## Wymagania na bastionie

- **uv** (raz): `curl -LsSf https://astral.sh/uv/0.13.6/install.sh | sh`. Środowisko z `uv.lock`
  tworzy się samo przy pierwszym `just ansible` (`.venv/`, poza gitem); uv w razie potrzeby
  pobiera też właściwego Pythona.
- sops + klucz age (jak do reszty repo), klucz SSH z `admin_ssh_keys` w SOPS (cloud-init
  wpisuje go kontu `ansible` w VM-kach), kubectl na klaster (rejestracja runnera w Forgejo).

## Uruchamianie

```bash
just ansible runner --check --diff     # co by się zmieniło (nic nie zmienia)
just ansible runner                    # zastosowanie
just vm-ssh runner                     # shell w VM (konto ansible, sudo bez hasła)
```

`just ansible <playbook> [argumenty ansible-playbook]` — instaluje kolekcje (gdy brakuje),
odszyfrowuje `infrastructure/network.sops.yaml` raz i podaje go jako zmienną `net`.
Bez tego `group_vars` nie znajdą adresów, dlatego playbooki uruchamia się przez `just`.

Połączenie z VM-kami: zwykłe SSH jako `ansible` + `become` (sudo bez hasła z cloud-init).
Klucz hosta nowej VM jest przyjmowany przy pierwszym połączeniu (`accept-new`), potem
sprawdzany — po odbudowie VM `ssh-keygen -R <adres>`.

## Nowa VM

1. `sops infrastructure/network.sops.yaml` → wpis `vms.<nazwa>`: `vmid`, `host` (klucz
   z `hosts`), `vlan` (klucz z `vlans`), `ip`. VMID = (VLAN/10)·100 + ostatni oktet.
2. OpenTofu: plik `<nazwa>.tf` w `infrastructure/proxmox/` na wzór `runner.tf` (moduł `vm`
   z `user_account`, grupa reguł w `firewall.tf`), `just tofu-apply`.
3. Inventory: host w grupie pod `vms` w `inventories/lab/hosts.yml`, zmienne ról
   w `host_vars/<nazwa>.yml`; playbook `<nazwa>.yml` w katalogu głównym projektu
   (role wspólne pełną nazwą: `speedzenon.homelab.debian_base`).
4. `just ansible <nazwa>`.

## Kolekcja `speedzenon.homelab`

Role przydatne poza tym repo (dziś `debian_base`, `podman`) leżą w kolekcji w
`collections/` — tutaj playbooki biorą je prosto z drzewa repo (`collections_path`),
a prywatne `homelab-home` instaluje kolekcję z gita po pełnym SHA commita z `main`
(szczegóły: README kolekcji). Role tylko dla tego repo zostają w `roles/`.

Zmiana w roli kolekcji działa w obu repo: przed merge'em `--check --diff` tutaj, a po
podbiciu SHA (PR Renovate w `homelab-home`) — tam. Bez adresów, nazw usług domowych
i sekretów: kolekcja jest publiczna.

## Aktualizacje

ansible-core, kolekcje, Python i wersje w rolach (np. runner) podbija Renovate w grupie
`ansible`. Merge niczego nie wdraża — zmiana trafia do gościa przy następnym
`just ansible` (najpierw z `--check --diff`).

## Pułapki

- ansible-core ≥ 2.19 wymaga w `when:` wartości logicznych — `-e zmienna=false` z linii
  poleceń to napis, więc w rolach `| bool`.
- `ansible_managed` działa tylko w szablonach (`template`), nie w `copy: content:`.
- Moduł `apt` w `--check` potrzebuje `python3-apt` — `debian_base` doinstalowuje go razem
  z Pythonem (obraz cloud Debiana ma oba, inne obrazy niekoniecznie).
- `become_user` na konto bez hasła i z powłoką `nologin` (np. `runner`) działa dzięki
  `pipelining` w `ansible.cfg` — moduły idą przez stdin, bez plików tymczasowych.
- Przy `delegate_to` zmienne hosta docelowego rozwijają się w kontekście bieżącego
  (`inventory_hostname` = źródło) — adresy hostów docelowych podawać jawnym kluczem.
- `command` z `stdin:` dokleja na końcu znak nowej linii (domyślne `stdin_add_newline: true`).
  Program czytający stdin w całości, bez przycinania, dostaje wtedy znak za dużo — przy
  sekretach `stdin_add_newline: false`.
- `forgejo-cli actions register` w Forgejo 15: `--secret-stdin` wymaga wartości (typ string),
  samo `--secret-stdin` kończy się „flag needs an argument”. Rola podaje `--secret "$(cat)"`
  przez `sh -c` w kontenerze — sekret ze stdin, poza argumentami kubectl i API.
- `no_log: true` ukrywa także komunikat błędu. Krok z sekretem: `failed_when: false`, a błąd
  pokazuje osobny `assert` z kodem wyjścia i `stderr` (o ile program nie wypisuje tam sekretu).
