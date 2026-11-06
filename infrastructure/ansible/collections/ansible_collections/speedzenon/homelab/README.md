# Kolekcja `speedzenon.homelab`

Role Ansible wspólne dla tego repo i prywatnego repo z usługami domowymi
(`homelab-home` w Forgejo). Tu żyje kod uniwersalny; co i gdzie konfigurować —
inventory, zmienne, sekrety — trzyma repo, które z kolekcji korzysta.

| Rola | Co robi |
|---|---|
| `speedzenon.homelab.debian_base` | Python, strefa czasowa, `apt dist-upgrade`, unattended-upgrades, agent QEMU (opcjonalnie), usuwanie zbędnych pakietów |
| `speedzenon.homelab.podman` | rootless podman dla podanych użytkowników (zakresy uid, lingering, gniazdo API), cotygodniowe `podman system prune` |

Zmienne ról: `roles/<rola>/defaults/main.yml` (każda z prefiksem nazwy roli).

## Użycie w tym repo

Bez instalacji — `ansible.cfg` w `infrastructure/ansible/` ma `collections` w
`collections_path`, więc playbooki widzą kolekcję prosto z drzewa repo.

## Użycie w innym repo

`requirements.yml` — git, katalog kolekcji po `#`, wersja = pełny SHA commita z `main`:

```yaml
collections:
  - name: https://github.com/speedzenon/homelab-public.git#/infrastructure/ansible/collections/ansible_collections/speedzenon/homelab/
    type: git
    version: <40-znakowy SHA>
```

`ansible-galaxy collection install -r requirements.yml` klonuje repo, buduje kolekcję
z tego katalogu i instaluje ją jak każdą inną. SHA zamiast gałęzi: dopóki nikt go nie
podbije, goście dostają dokładnie ten sam kod. Podbija go Renovate w repo, które z
kolekcji korzysta (datasource `git-refs`, gałąź `main`).

## Zasady

- Bez adresów, nazw usług domowych i sekretów — repo jest publiczne.
- Zmiana zmiennej lub zachowania roli dotyka też drugiego repo: przed merge'em
  `just ansible <playbook> --check --diff` tutaj, po podbiciu SHA — tam.
