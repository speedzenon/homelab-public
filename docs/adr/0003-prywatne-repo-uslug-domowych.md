# ADR 0003: Prywatne repo usług domowych w Forgejo i role wspólne jako kolekcja

- **Status:** przyjęta, 06.11.2026
- **Dotyczy:** podział między `homelab-public` (GitHub) a `homelab-home` (prywatne, Forgejo),
  kolekcja `infrastructure/ansible/collections/ansible_collections/speedzenon/homelab/`

## Kontekst

- To repo jest publiczne. Usługi domowe (media, zdjęcia, sprawy domowe) nie powinny w nim
  żyć — ich konfiguracja mówi więcej o domu niż o platformie.
- Forgejo działa w klastrze (faza 4), jego dane kopiuje VolSync do B2 ze sprawdzonym
  odtworzeniem (faza 5), jest runner Actions i Renovate (faza 6) — może przyjąć prywatne repo.
- Klaster i Forgejo buduje się z tego repo. Gdyby coś potrzebnego do odbudowy żyło tylko
  w Forgejo, po awarii klastra nie byłoby z czego go postawić.
- Goście usług domowych potrzebują tych samych ról co goście platformy (baza Debiana,
  rootless podman).

## Decyzja

- **Podział:**
  - `homelab-public` — platforma: sieć, Proxmox (VM-ki platformy, firewall klastra), Talos,
    Kubernetes, Forgejo, backup klastra, runner, role wspólne;
  - `homelab-home` (prywatne, konto `zenon` w Forgejo) — usługi domowe i ich goście, dane,
    dokumentacja migracji z ODROID-a.
- **Zależność w jedną stronę:** `homelab-home` korzysta z `homelab-public` (role, wzorce),
  nigdy odwrotnie.
- **Role wspólne = kolekcja `speedzenon.homelab`** w `infrastructure/ansible/collections/`.
  Tutaj playbooki biorą ją z drzewa repo (`collections_path`); `homelab-home` instaluje ją
  z gita po pełnym SHA commita z `main`, a SHA podbija Renovate (datasource `git-refs`).
  Role tylko dla platformy zostają w `infrastructure/ansible/roles/`.
- **Workflow `homelab-home` jak tutaj:** gałąź → PR, podpisane commity, `just feat / pr / done`.
  W Forgejo:
  - `main` bez bezpośredniego pusha, zmiany tylko przez PR;
  - scalanie wyłącznie przez przewinięcie (fast-forward) — podpisane commity trafiają na
    `main` bez zmian, a `just done` rozpoznaje scalone gałęzie przez `git branch --merged`;
  - `just pr` sprawdza podpisy commitów przed pushem i zakłada PR przez API Forgejo (`curl`,
    token z jednym zakresem `write:repository`).
- **Bez „Require signed commits” w ochronie gałęzi:** znany błąd Forgejo
  ([forgejo#6438](https://codeberg.org/forgejo/forgejo/issues/6438)) — przy tej opcji
  przycisk merge odmawia nawet przewinięcia, jeśli instancja nie ma własnego klucza
  podpisującego. Podpisy pilnuje `just pr`.
- **CI:** bez workflowów uruchamianych przy pushu — runner jest na żądanie (ADR 0002), więc
  job czekałby w kolejce i po 24 h przepadał. Bramką jest pre-commit lokalnie.
- **Backup:** repozytoria Forgejo leżą na PVC `forgejo-data` → VolSync → B2
  (`docs/runbooks/backup.md`), plus klon roboczy na bastionie.
- **Goście usług domowych przechodzą do `homelab-home`** razem ze swoimi grupami i regułami
  firewalla PVE (OpenTofu w tamtym repo; przeniesienie stanu blokami `removed` / `import`,
  bez przerwy w regułach). Obiekty firewalla klastra (ipsety, aliasy sieci, opcje klastra)
  zostają tutaj — to uzupełnia zasadę z ADR 0001, że firewall gości robi OpenTofu.

## Konsekwencje

- Publiczne repo opisuje platformę bez szczegółów domowych; kod ról jest w jednym miejscu,
  a `homelab-home` przyjmuje jego zmiany świadomie (PR z nowym SHA).
- Dwa repo do pilnowania. Zmiana roli w kolekcji działa w obu: `--check --diff` tutaj przed
  merge'em i tam po podbiciu SHA. Kolekcja jest publiczna — bez adresów i nazw usług domowych.
- Instalacja kolekcji w `homelab-home` wymaga dostępu do GitHuba (klon repo).
- Historia tego repo zachowuje dotychczasowe pliki usług domowych — świadomie bez
  przepisywania historii (force-push na `main`, ponowne podpisy, stare PR-y i tak trzymają
  diffy).
- Commity Renovate w `homelab-home` są niepodpisane (widoczne jako niezweryfikowane) do czasu
  dodania botowi klucza SSH do podpisywania.

## Rozważane alternatywy

- **Submoduł git** z tym repo — bez przeróbek, ale ręczne podbijanie i `clone --recursive`.
- **Kopie ról w `homelab-home`** — samowystarczalne, ale dwie wersje tych samych ról się
  rozjeżdżają.
- **Przepisanie historii** tego repo — patrz Konsekwencje.
- **tea** (CLI Gitei) do zakładania PR-ów — zarchiwizowane 29.10.2026; następca `gt` bez
  informacji o zgodności z Forgejo. API Forgejo przez `curl` nie wymaga dodatkowego programu.
- **„Require signed commits” + klucz podpisujący instancji** — działałoby, ale to kolejny
  klucz do przechowywania i rotacji. Do rozważenia, gdyby do repo doszły inne osoby.
