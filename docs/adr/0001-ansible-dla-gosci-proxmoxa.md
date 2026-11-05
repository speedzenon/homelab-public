# ADR 0001: Ansible do konfiguracji gości Proxmoxa

- **Status:** przyjęta, 05.11.2026
- **Dotyczy:** wnętrze VM-ek i kontenerów LXC na Proxmox VE (pierwsza: VM runnera Forgejo Actions)

## Kontekst

- Kontenery LXC konfiguruje dziś skrypt bash (`scripts/bootstrap-media.sh`): idempotencję
  trzeba pisać ręcznie (`if … then`), pliki konfiguracyjne siedzą w heredocach, nie ma
  podglądu „co się zmieni”, a każdy nowy gość to kolejny skrypt. Repo robi się trudne
  do czytania.
- OpenTofu tworzy VM-ki (moduł `modules/vm`, węzły Talosa) i zarządza firewallem PVE, ale
  nie konfiguruje systemu wewnątrz gościa.
- Kontenera LXC z `keyctl=1` (potrzebne podmanowi) token OpenTofu nie utworzy — tę opcję
  może ustawić tylko root@pam.

## Decyzja

- **Ansible konfiguruje wnętrze gości** (`infrastructure/ansible/`): role (`debian_base`,
  `podman`, `forgejo_runner`, …) i playbook na usługę.
- **Kto tworzy gościa:**
  - **VM — OpenTofu** (moduł `vm` + cloud-init: konto `ansible` z kluczem z SOPS, adres,
    DNS); Ansible łączy się po SSH;
  - **LXC — Ansible, gdy dojdą kontenery mediów:** `pct create` na hoście jako root (przez
    `keyctl`), połączenie `community.proxmox.proxmox_pct_remote` (SSH na host + `pct exec`,
    bez sshd w kontenerze). Do tego czasu `bootstrap-media.sh` zostaje.
- **OpenTofu zostaje przy firewallu PVE** dla wszystkich gości.
- **Środowisko przypięte w repo:** uv (`pyproject.toml` + `uv.lock` z sumami kontrolnymi),
  kolekcje w dokładnych wersjach (`requirements.yml`); aktualizacje jako PR-y Renovate.
- **Dane:** adresy z `network.sops.yaml`, odszyfrowane raz na przebieg i podane jako zmienna
  `net` (`just ansible`); sekrety z plików SOPS przez `community.sops.load_vars`.
- **Jakość:** ansible-lint w profilu `production` w pre-commit (i przez niego w CI).

## Konsekwencje

- Plusy: idempotentne moduły, `--check --diff` przed zmianą, handlery restartujące usługi
  tylko po zmianie konfiguracji, role wielokrotnego użytku, czytelny podział: OpenTofu —
  co istnieje i jak jest odgrodzone, Ansible — co jest w środku.
- Minusy: nowa warstwa w repo (uv, kolekcje, inventory). Gość ma trzy miejsca: wpis w SOPS
  (adres, VMID), OpenTofu (VM lub reguły firewalla), Ansible (konfiguracja).
- W VM-kach działa sshd (dla Ansible) — tylko klucz, tylko z sieci admin (firewall PVE).

## Rozważane alternatywy

- **Dalej bash** — patrz kontekst; problem rośnie z każdym gościem.
- **cloud-init do całej konfiguracji** — jednorazowy przy pierwszym starcie; nie poprawia
  konfiguracji później i nie pokazuje różnic. Zostaje tylko do konta i sieci.
- **Ansible z apt albo pipx** — bez locka zależności; inna wersja u mnie i w CI.
