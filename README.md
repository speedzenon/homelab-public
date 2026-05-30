# Homelab

Infrastructure-as-code dla mojego home labu — Proxmox VE jako hypervisor, Kubernetes (Talos Linux) jako platforma, kompletny enterprise-grade security stack. Całość zarządzana w modelu GitOps przez ArgoCD i Renovate Bot.

## Architektura

### Sprzęt

| Host | Specyfikacja | Rola |
|---|---|---|
| AOOStar G-FLIP | Ryzen AI 9 HX 370 · 128GB RAM · 2x 2TB NVMe | Główny compute, control plane dla security stack |
| AOOStar WTR MAX | Ryzen 7 PRO 8845HS · 64GB RAM · rozszerzalny storage | Node storage, k8s workers, środowiska dev/test |
| ODROID H4+ | Intel N97 · 16GB RAM · 1TB NVMe | Proxmox Backup Server, monitoring, Ceph tiebreaker |

### Sieć

MikroTik jako perimeter z 6 VLAN-ami: management, security tools, k8s, prod, dev, DMZ. WireGuard jako jedyny zewnętrzny punkt dostępu.

### Stack technologiczny

- **Hypervisor:** Proxmox VE 8 (2-node cluster) + Proxmox Backup Server
- **Storage:** Ceph (distributed) + ZFS (local) + Backblaze B2 (offsite)
- **Kubernetes:** Talos Linux (immutable, API-driven), Cilium CNI z runtime security Tetragon
- **GitOps:** ArgoCD + Renovate Bot, OpenTofu dla infrastruktury, Ansible dla konfiguracji OS-level
- **IAM:** Authentik (OIDC + MFA przez WebAuthn)
- **Secrets:** OpenBao + szyfrowanie w Git przez SOPS + External Secrets Operator
- **PKI:** Step-CA z ACME, krótkie żywotności certyfikatów (24h–7d)
- **SIEM:** Wazuh (Manager + Indexer + Dashboard + agenci)
- **Network IDS:** OPNsense VM z Suricata
- **Observability:** Prometheus + Grafana + Loki

## Struktura repozytorium

    homelab/
    ├── docs/                  Dokumentacja, runbooki, ADR, diagramy
    ├── bootstrap/             Manualne kroki Day-1 (instalacja Proxmox, bootstrap Talos)
    ├── infrastructure/        Deklaratywna infrastruktura
    │   ├── mikrotik/          Skrypty RouterOS + Ansible
    │   ├── proxmox/           Moduły OpenTofu do provisioningu VM
    │   └── ansible/           Konfiguracja OS-level, deploy agentów
    ├── talos/                 Machine configs Talos (szyfrowane SOPS)
    │   ├── patches/           Strategic merge patches
    │   └── secrets/           Zaszyfrowane sekrety bootstrap
    ├── kubernetes/            Zarządzane przez ArgoCD
    │   ├── bootstrap/         Initial install ArgoCD + Cilium
    │   ├── infrastructure/    cert-manager, openbao, external-secrets
    │   ├── platform/          authentik, wazuh, prometheus
    │   ├── policies/          Kyverno, network policies, PSS
    │   └── apps/              Workloady użytkownika
    └── .github/
        ├── workflows/         Pipeline'y CI/CD
        └── ISSUE_TEMPLATE/    Szablony issue

## Status faz

- [x] **Faza 0** — Fundament Git + CI
- [ ] **Faza 1** — Sieć (VLAN-y MikroTik, WireGuard)
- [ ] **Faza 2** — Hypervisor (instalacja Proxmox, OpenTofu)
- [ ] **Faza 3** — Bootstrap Kubernetes (klaster Talos)
- [ ] **Faza 4** — Platforma GitOps (ArgoCD, Renovate)
- [ ] **Faza 5** — Fundamenty platformy (PKI, secrets)
- [ ] **Faza 6** — Tożsamość (Authentik, integracje OIDC)
- [ ] **Faza 7** — Bezpieczeństwo (Tetragon, Kyverno, Wazuh, OPNsense)
- [ ] **Faza 8** — Observability (Prometheus, Grafana, Loki)
- [ ] **Faza 9** — Backup i DR (Velero, sync do B2)
- [ ] **Faza 10** — Pierwsze produkcyjne workloady

## Odtworzenie od zera (bootstrap from zero)

Pełna procedura disaster recovery znajduje się w docs/runbooks/bootstrap-from-zero.md

## Praca lokalna

### Wymagane narzędzia

Do pracy z repo potrzebne są: age, sops, gh, gpg, pre-commit, yamllint, shellcheck, gitleaks

Szczegóły instalacji w docs/runbooks/local-setup.md

### Praca z plikami zaszyfrowanymi SOPS

Pliki zawierające sekrety mają sufiks `.sops.yaml` i są zaszyfrowane. Reguły szyfrowania (które pliki, jakim kluczem, które pola) definiuje plik `.sops.yaml` w katalogu głównym repo.

#### Edycja bez ręcznego odszyfrowywania (zalecane)

Najwygodniejszy sposób pracy z zaszyfrowanym plikiem — SOPS sam zajmuje się odszyfrowaniem i ponownym zaszyfrowaniem:

    sops kubernetes/platform/openbao/secret.sops.yaml

Pod spodem SOPS wykonuje automatycznie:

1. Odszyfrowuje plik do tymczasowej lokalizacji
2. Otwiera go w edytorze wskazanym przez zmienną `$EDITOR`
3. Po zapisaniu i zamknięciu edytora — szyfruje zawartość z powrotem
4. Usuwa tymczasowy plik

Dzięki temu niezaszyfrowana treść nigdy nie trafia na dysk w sposób trwały, a Ty edytujesz plik tak, jakby był zwykłym YAML-em. Wymaga ustawionej zmiennej `$EDITOR`:

    export EDITOR=nvim    # lub vim, nano

Uwaga dla użytkowników VS Code — trzeba dodać flagę `--wait`, inaczej `code` wraca natychmiast i SOPS zaszyfruje plik zanim go zedytujesz:

    export EDITOR="code --wait"

#### Szyfrowanie nowego pliku

    sops --encrypt --in-place path/to/file.sops.yaml

#### Odszyfrowanie na stdout (tylko do debugowania)

Wypisuje odszyfrowaną zawartość na ekran, nie zapisuje na dysk:

    sops --decrypt path/to/file.sops.yaml

#### Aktualizacja kluczy odbiorców

Po zmianie listy kluczy w `.sops.yaml` (np. dodaniu klucza dla CI/CD), trzeba ponownie zaszyfrować data encryption key istniejących plików dla nowego zestawu odbiorców:

    sops updatekeys path/to/file.sops.yaml

## Licencja

Projekt osobisty, bez przypisanej licencji — treść nie jest przeznaczona do redystrybucji.
