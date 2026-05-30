# Local development setup

Instrukcja konfiguracji lokalnego środowiska do pracy z repo.

## Wymagane narzędzia

Zainstaluj: age, sops, gh, gpg, pre-commit, yamllint, shellcheck, gitleaks

## Konfiguracja

1. Wygeneruj klucz GPG do podpisywania commitów
2. Wygeneruj klucz age dla SOPS, ustaw `SOPS_AGE_KEY_FILE`
3. Skonfiguruj SSH do GitHuba
4. Zainstaluj pre-commit hooks: `pre-commit install`

Szczegóły zostaną rozbudowane.
