# Runbook: Renovate dla repozytoriów w Forgejo

Renovate co godzinę sprawdza zależności w repozytoriach w Forgejo i otwiera PR-y
z aktualizacjami. To repo (GitHub) obsługuje osobno Renovate z GitHuba
(`.github/renovate.json5`) — ten tutaj widzi tylko Forgejo.

| Co | Gdzie |
|---|---|
| Application | `kubernetes/apps/renovate.yaml` (chart OCI `ghcr.io/renovatebot/charts/renovate`) |
| Values i konfiguracja globalna | `kubernetes/platform/renovate/values.yaml` |
| Token GitHuba | `kubernetes/platform/renovate/env.sops.yaml` → `just renovate-secret` → Secret `renovate-env` |
| Konto bota i jego token | `renovate` w Forgejo, konto *restricted*; `just renovate-bot` → Secret `renovate-forgejo-token` |
| Konfiguracja repozytorium | `renovate.json` w każdym repo (tworzy go onboarding PR) |

## Jak to działa

- CronJob `renovate` w ns `renovate` (Pod Security `restricted`, bez tokenu API Kubernetesa)
  co godzinę o :17 uruchamia jeden pod. Pod przechodzi po repozytoriach i kończy pracę.
- `autodiscover`: Renovate bierze wszystkie repozytoria, do których bot ma dostęp. Konto
  jest *restricted*, więc widzi **tylko** repozytoria, do których dodasz je jako
  współpracownika — to jest lista „co obsługuje Renovate”.
- Repo bez `renovate.json` dostaje najpierw onboarding PR („Configure Renovate”) z listą
  wykrytych zależności. Dopiero po jego merge'u przychodzą PR-y z aktualizacjami, a w repo
  pojawia się issue „Dependency Dashboard” (przegląd wszystkiego, ręczne wyzwalanie).
- Renovate nie uruchamia skryptów z repozytoriów (domyślne `ignoreScripts`, brak
  `allowedCommands`) — przy aktualizacji plików lock tylko pobiera paczki.

## Pierwsze uruchomienie

1. Token GitHuba tylko do odczytu (opis w `env.example.yaml`). Bez niego Renovate ma
   60 zapytań/h do API GitHuba i szybko je wyczerpuje. Do SOPS, commit, Secret:

   ```bash
   sops kubernetes/platform/renovate/env.sops.yaml      # wzór: env.example.yaml
   just renovate-secret
   ```

2. Konto bota i jego token (wymaga działającego Forgejo):

   ```bash
   just renovate-bot
   ```

   Zakłada konto `renovate` (*restricted*, losowe hasło, którego nikt nie używa), generuje
   token z uprawnieniami z dokumentacji Renovate (`write:repository`, `read:user`,
   `write:issue`, `read:organization`) i wkłada go prosto do Secretu
   `renovate-forgejo-token`. Tokenu nie ma na ekranie ani w gicie — w razie potrzeby
   (także po odbudowie klastra) przepis generuje nowy.
3. Po merge'u: `just refresh root` (nowa Application). Sprawdzenie:
   `kubectl get ns renovate --show-labels` (etykiety `pod-security…=restricted`)
   i `kubectl -n renovate get cronjob renovate`.
4. W każdym repo, które ma obsługiwać Renovate: Settings → Collaborators → `renovate`,
   uprawnienie **Write**.
5. `just renovate-run` — przebieg od razu, z logami. W repozytoriach pojawią się
   onboarding PR-y.

## Diagnostyka

```bash
kubectl -n renovate get cronjob,jobs,pods
kubectl -n renovate logs job/<nazwa-joba>        # albo: just renovate-run
```

- Pod w `CreateContainerConfigError` — brak Secretu `renovate-env` (`just renovate-secret`)
  albo `renovate-forgejo-token` (`just renovate-bot`).
- `401` / `403` z API Forgejo — zły albo usunięty token (`just renovate-bot rotate`).
- Repo pominięte — bot nie jest współpracownikiem, repo jest mirrorem albo ma wyłączone
  pull requesty (warunki autodiscover Renovate).
- Timeout do `git.int.dawidkraska.pl` — pod idzie do VIP-a Gatewaya (nazwa z DNS MikroTika).
  Test DNS, routingu i TLS z poda w ns `default` (ns `renovate` jest `restricted` i odrzuciłby
  pod bez utwardzenia); oczekiwane `{"status":"pass",…}`:

  ```bash
  kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl:8.11.1 -- \
    curl -sS https://git.int.dawidkraska.pl/api/healthz
  ```

- Więcej szczegółów w logach: tymczasowo `env: {LOG_LEVEL: debug}` w values (PR), potem
  z powrotem.

## Rotacja tokenu

1. `just renovate-bot rotate` — nowy token (nazwa z datą) od razu w Secrecie
   `renovate-forgejo-token`. Renovate używa go od następnego przebiegu.
2. Usunięcie starego tokenu: Forgejo nie ma do tego komendy CLI, robi się to jako bot.
   Tymczasowe hasło, logowanie w oknie prywatnym, Settings → Applications → usuń stare
   tokeny, wylogowanie:

   ```bash
   pw=$(openssl rand -base64 24); echo "$pw"      # hasło tylko na czas tej operacji
   kubectl -n forgejo exec deploy/forgejo -c forgejo -- forgejo admin user change-password \
     --username renovate --password "$pw" --must-change-password=false
   ```

   Po usunięciu tokenów to samo jeszcze raz, bez `echo` — hasło znów jest losowe i nieznane.

## Wyłączenie

- Jedno repo: usunąć bota ze współpracowników (otwarte PR-y zamknąć ręcznie).
- Całość: `cronjob.suspend: true` w values (PR) — Application zostaje, joby nie startują.
