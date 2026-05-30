#!/usr/bin/env bash
#
# Blokuje commitowanie prywatnych adresów IP (RFC1918) w plaintext.
# Pliki *.sops.yaml są pomijane (zaszyfrowane).
# By świadomie dopuścic IP w danej linii, dodaj komentarz zawierajacy: allowlist-ip
#
set -euo pipefail

# Zakresy prywatne RFC1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
ip_regex='(\b10\.([0-9]{1,3}\.){2}[0-9]{1,3}\b|\b172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}\b|\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b)'

found=0

for file in "$@"; do
    case "$file" in
        *.sops.yaml | *.sops.yml) continue ;;
    esac

    if matches=$(grep -nEI "$ip_regex" "$file" 2>/dev/null | grep -v 'allowlist-ip'); then
        echo "Prywatne IP w plaintext: $file"
        echo "$matches"
        found=1
    fi
done

if [ "$found" -ne 0 ]; then
    cat <<'MSG'

Znaleziono prywatne adresy IP (RFC1918) w plaintext.
Opcje:
  1. Przenies wartosc do pliku *.sops.yaml (zaszyfrowane)
  2. Uzyj zmiennej/templatu zamiast literalu IP
  3. W dokumentacji uzyj zakresow przykladowych (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24)
  4. Jesli IP jest celowe i bezpieczne, dodaj w tej linii komentarz: allowlist-ip
MSG
    exit 1
fi
