# Runbook: runner Forgejo Actions

Forgejo nie wykonuje jobów samo — robi to osobny program, Forgejo Runner. U nas działa
w małej VM `runner` na g-flipie (VLAN `servers`), która **zwykle jest wyłączona**:
uruchamiasz ją przed budowaniem, a sama się wyłącza po 30 minutach bez jobów. Dlaczego VM
i dlaczego na żądanie: `docs/adr/0002-runner-w-vm-na-zadanie.md`.

| Co | Gdzie |
|---|---|
| VM | OpenTofu: `infrastructure/proxmox/runner.tf` (2 vCPU, 4 GB, 32 GB); adres i VMID w SOPS (`vms.runner`) |
| Konfiguracja | Ansible: `infrastructure/ansible/runner.yml` (role `speedzenon.homelab.debian_base`, `speedzenon.homelab.podman`, `forgejo_runner`) |
| Sekret rejestracji | `infrastructure/ansible/secrets/forgejo-runner.sops.yaml` (`just runner-secret`) |
| Firewall | grupa `runner-srv` (`firewall.tf`): wejście tylko SSH i ICMP z sieci admin |
| Start / stop | `just runner-up` / `just runner-down`; samowyłączanie po 30 min bez jobów |
| Shell | `just vm-ssh runner` |
| W Forgejo | Site Administration → Actions → Runners (zwykle *Offline* — VM stoi) |

## Codzienne użycie

```bash
git push                 # workflow trafia do kolejki Forgejo (czeka do 24 h na runnera)
just runner-up           # VM startuje ok. pół minuty, runner sam pobiera czekające joby
```

Kolejność jest dowolna — job czeka w kolejce, aż runner się pojawi (po 24 h Forgejo go
anuluje: `ABANDONED_JOB_TIMEOUT`). Po ostatnim jobie VM sama się wyłączy po 30 min.
Wcześniej: `just runner-down`.

Prace na VM (bez samowyłączania w trakcie): `just vm-ssh runner`,
`sudo systemctl stop runner-idle-shutdown.timer` — timer wraca przy następnym starcie.

## Jak to działa

- **VM:** Debian 13 z obrazu cloud. OpenTofu tworzy ją z cloud-init (konto `ansible`
  z kluczem z `admin_ssh_keys`, adres, DNS) i ma `started` w `ignore_changes`, więc
  `tofu apply` nie włącza wyłączonej VM.
- **Podman rootless:** joby to kontenery użytkownika `runner` (lingering — jego systemd
  startuje razem z VM; gniazdo API `/run/user/<uid>/podman/podman.sock`). Ucieczka z
  kontenera kończy się na tym użytkowniku, nie na roocie VM.
- **Runner:** forgejo-runner 13.x (binarka z wydań Forgejo, weryfikowana podpisem GPG) jako
  usługa systemd `forgejo-runner` (użytkownik `runner`). Sam łączy się z Forgejo i pobiera
  joby — nie wystawia żadnej usługi.
- **Rejestracja offline:** 40-znakowy sekret z SOPS. Ansible rejestruje go w Forgejo
  (`forgejo forgejo-cli actions register` przez kubectl, sekret przez stdin) i wpisuje do
  konfiguracji runnera (`server.connections`). Forgejo wylicza UUID z sekretu, więc
  ponowne uruchomienie albo odbudowa VM daje tego samego runnera — bez klikania w UI.
  Runner jest globalny (cała instancja).
- **Etykiety:** `docker` i `ubuntu-latest` → obraz `node:24-trixie` (Node potrzebują akcje
  JavaScript, np. `actions/checkout`). Workflow może podać własny obraz (`container:`).
  Akcje bez pełnego URL-a Forgejo pobiera z `data.forgejo.org` (lustro popularnych akcji).
- **Limity:** 1 job naraz, 1 h na job, osobna sieć dla każdego joba.
- **Samowyłączanie:** timer co 5 min sprawdza, czy działa jakiś kontener joba (proces
  `conmon` użytkownika `runner`); po 30 min bez niego `systemctl poweroff`.
- **Sprzątanie:** co tydzień `podman system prune` (gdy VM akurat działa) — usuwa obrazy
  nieużywane od tygodnia i przy okazji je odświeża, bo runner sam nie pobiera nowszych
  wersji tagów.

## Bezpieczeństwo — co może job

Runner wykonuje kod z repozytoriów, a **joby dostają gniazdo podmana**
(`docker_host: automount`, w jobie jako `/var/run/docker.sock`) — po to, żeby mogły budować
obrazy. Job może więc uruchomić dowolny kontener użytkownika `runner` i przeczytać jego
pliki, w tym token runnera. Granice:

- rootless podman — bez eskalacji uprawnień job nie dostaje roota VM;
- VM (KVM) — błąd jądra w VM nie daje dostępu do hosta g-flip;
- firewall PVE — wejście tylko SSH/ICMP z sieci admin; inni goście w VLAN-ie `servers`
  przyjmują ruch tylko od jawnie wpuszczonych źródeł.

Bez gniazda w jobach (gdyby kiedyś miał tu trafić obcy kod): `forgejo_runner_docker_host: "-"`.

## Pierwsze wdrożenie

1. Wpis w SOPS (`sops infrastructure/network.sops.yaml`):
   - w sekcji `vms`: `runner: {vmid: <400 + oktet>, host: gflip, vlan: servers, ip: <wolny adres .20–.99>}`;
   - na najwyższym poziomie: `admin_ssh_keys:` — lista kluczy publicznych z bastionu
     (`cat ~/.ssh/id_ed25519.pub`).
2. Sekret runnera (`just runner-secret`) — commit razem z SOPS.
3. `just tofu-plan` → `just tofu-apply`: obraz Debiana, VM (startuje od razu, cloud-init
   zakłada konto i sieć), firewall.
4. `just ansible runner` — konfiguracja, rejestracja w Forgejo, start usługi. Na końcu
   pobiera obraz jobów i uruchamia w nim `node --version` (test całego łańcucha).
5. Forgejo → Site Administration → Actions → Runners: runner `runner` ze statusem *Idle*.
   Po 30 min bez jobów VM się wyłączy (status *Offline*).

Test — repo z plikiem `.forgejo/workflows/test.yml`:

```yaml
on: [push]
jobs:
  test:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: node --version && ls -la
```

## Budowanie obrazów w jobach

Podman nie ma BuildKitu, więc `docker/build-push-action` (buildx) nie zadziała. Budować przez
API podmana z gniazda:

```yaml
    steps:
      - uses: actions/checkout@v4
      - run: apt-get update -q && apt-get install -y -q podman
      - run: podman --remote --url unix:///var/run/docker.sock build -t git.int.dawidkraska.pl/zenon/app:test .
```

Budowanie wykonuje podman runnera (warstwy zostają w jego cache między jobami i startami VM).
Publikacja do rejestru pakietów Forgejo: `podman --remote … push --creds <user>:<token>`
z tokenem z uprawnieniem `write:package` w sekretach repozytorium. Rejestr leży na PVC
`forgejo-data` (10 Gi) — przy regularnym budowaniu do powiększenia.

## Aktualizacje

- Runner: Renovate podbija `forgejo_runner_version` (grupa `ansible`); po merge'u
  `just runner-up`, `just ansible runner --check --diff`, potem `just ansible runner`.
- System: `apt dist-upgrade` przy każdym `just ansible runner`; poprawki bezpieczeństwa przez
  unattended-upgrades, gdy VM działa (zaległe nadrabia zaraz po starcie). Nowe jądro wchodzi
  przy następnym starcie VM.

## Diagnostyka

```bash
just vm-ssh runner
sudo systemctl status forgejo-runner
sudo journalctl -u forgejo-runner -f          # połączenie z Forgejo, pobierane joby
sudo journalctl -t runner-idle-shutdown       # kiedy i dlaczego VM się wyłączyła
sudo -u runner XDG_RUNTIME_DIR=/run/user/$(id -u runner) podman ps -a   # kontenery jobów
```

- Runner *Offline*, choć VM działa — usługa leży albo brak połączenia z
  `git.int.dawidkraska.pl:443` (DNS z MikroTika, VIP Gatewaya).
- Job czeka w kolejce mimo działającego runnera — `runs-on` nie pasuje do etykiet
  (`docker`, `ubuntu-latest`).
- `just ansible runner` nie łączy się — VM wyłączona (`just runner-up`) albo po odbudowie
  zmienił się klucz hosta (`ssh-keygen -R <adres>`).

## Odbudowa, rotacja, usunięcie

- **Odbudowa:** `tofu apply -replace=module.runner.proxmox_virtual_environment_vm.this`
  (w `infrastructure/proxmox`, z sekretami jak w `just tofu-apply`), `ssh-keygen -R <adres>`,
  `just ansible runner`. Ten sam sekret = ten sam runner w Forgejo.
- **Rotacja sekretu:** usunąć plik sekretu, `just runner-secret`, `just ansible runner`.
  Nowy sekret to nowy UUID — starego runnera usunąć w UI.
- **Usunięcie:** runner w UI; z repo `runner.tf`, wpis `vms.runner` i grupa `runner-srv`
  (jeden PR), `just tofu-apply`.

## Wymagane przepływy sieciowe (pod przyszły firewall MikroTika)

Z VM `runner`: DNS do MikroTika; HTTPS do VIP-a Gatewaya (Forgejo, także checkout w jobach);
HTTPS do internetu — `code.forgejo.org` (binarka), `keys.openpgp.org` (klucz),
`data.forgejo.org` (akcje), `docker.io` / inne rejestry (obrazy), `deb.debian.org`
i `security.debian.org` (pakiety). Do VM: SSH z bastionu.
