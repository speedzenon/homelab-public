#!/usr/bin/env bash
#
# Kazdy plik *.sops.{yaml,yml,json,env} w commicie musi byc zaszyfrowany SOPS-em:
# zawierac metadane sops i zaszyfrowane wartosci ENC[AES256_GCM,...].
#
# Po co: hook no-plaintext-ips pomija pliki *.sops.* w calosci, a forbid-secrets
# sprawdza tylko Secrety Kubernetesa. Plik zapisany przez pomylke w postaci jawnej
# (np. po 'sops -d plik > plik') przeszedlby oba. Nie wymaga binarki sops.
#
set -euo pipefail

found=0

for file in "$@"; do
    if ! grep -qE '^sops:|"sops"[[:space:]]*:|^sops_mac=' "$file" \
        || ! grep -q 'ENC\[AES256_GCM,' "$file"; then
        echo "Niezaszyfrowany plik SOPS: $file"
        found=1
    fi
done

if [ "$found" -ne 0 ]; then
    cat <<'MSG'

Plik *.sops.* nie wyglada na zaszyfrowany (brak metadanych sops lub wartosci ENC[...]).
Opcje:
  1. Zaszyfruj w miejscu:   sops -e -i <plik>
  2. Edytuj zawsze przez:   sops <plik>   (SOPS szyfruje przy zapisie)
  3. Jesli plik nie jest sekretem, zmien nazwe - sufiks .sops. oznacza "zaszyfrowany"
MSG
    exit 1
fi
