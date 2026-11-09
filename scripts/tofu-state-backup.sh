#!/usr/bin/env bash
#
# Kopia lokalnego stanu OpenTofu (proxmox, mikrotik) do B2 przez restic.
# Uruchamiany przez 'just tofu-state-backup [backup|snapshots|verify]' pod
# 'sops exec-env kubernetes/platform/volsync/restic.sops.yaml' - zmienne AWS_*,
# RESTIC_PASSWORD i RESTIC_REPOSITORY_BASE przychodza z SOPS (te same co VolSync).
#
# Po co: stan zyje tylko na bastionie, a bastion na g-flipie (stripe ZFS bez
# redundancji). Bez stanu tofu nie wie, ktore VM-ki, reguly firewalla i rekordy
# DNS sa jego - odbudowa to reczny import kazdego zasobu.
#
# Stan zawiera odszyfrowane wartosci z SOPS (data.sops_file trafia do state),
# wiec nie wolno go kopiowac jawnie - restic szyfruje po stronie klienta.
# Odtworzenie NIE wymaga klucza age: haslo restica (kopia poza labem) + klucz
# aplikacyjny B2 utworzony w konsoli Backblaze.
#
# Repozytorium: ${RESTIC_REPOSITORY_BASE}/bastion/tofu-state (obok repozytoriow
# PVC <ns>/<pvc> z VolSync). Wymaga restic >= 0.17 (kod wyjscia 10 dla
# nieistniejacego repo, --skip-if-unchanged).
#
set -euo pipefail

: "${RESTIC_REPOSITORY_BASE:?brak RESTIC_REPOSITORY_BASE - uruchamiaj przez 'just tofu-state-backup'}"
: "${RESTIC_PASSWORD:?brak RESTIC_PASSWORD - uruchamiaj przez 'just tofu-state-backup'}"
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY_BASE}/bastion/tofu-state"

mode="${1:-backup}"

ver=$(restic version | awk '{print $2}')
if [ "$(printf '%s\n' 0.17.0 "$ver" | sort -V | head -1)" != 0.17.0 ]; then
    echo "BLAD: restic $ver - potrzebny >= 0.17" >&2
    exit 2
fi

states=()
for d in proxmox mikrotik; do
    f="infrastructure/$d/terraform.tfstate"
    if [ -s "$f" ]; then
        states+=("$f")
    else
        echo "UWAGA: brak $f - pomijam" >&2
    fi
done

case "$mode" in
    backup)
        [ "${#states[@]}" -gt 0 ] || { echo "BLAD: zaden plik stanu nie istnieje" >&2; exit 1; }
        # 10 = repozytorium nie istnieje -> init; inny blad (haslo, siec, B2) -> stop,
        # zeby nie probowac init na istniejacym repo
        rc=0
        restic cat config >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 10 ]; then
            restic init
        elif [ "$rc" -ne 0 ]; then
            echo "BLAD: restic nie otworzyl repozytorium (kod $rc: 12 = zle haslo, 1 = siec/uprawnienia B2)" >&2
            exit "$rc"
        fi
        restic backup --host bastion --tag tofu-state --skip-if-unchanged "${states[@]}"
        ;;
    snapshots)
        restic snapshots --tag tofu-state
        ;;
    verify)
        # Test odtworzenia: ostatni snapshot do RAM-u (/dev/shm, nie na dysk -
        # stan zawiera sekrety) i porownanie bajt po bajcie z plikami lokalnymi.
        # Ma sens zaraz po backupie, zanim kolejny apply zmieni stan.
        [ "${#states[@]}" -gt 0 ] || { echo "BLAD: zaden plik stanu nie istnieje" >&2; exit 1; }
        tmp=$(mktemp -d /dev/shm/tofu-state-verify.XXXXXX)
        trap 'rm -rf "$tmp"' EXIT
        restic restore latest --host bastion --tag tofu-state --target "$tmp" >/dev/null
        rc=0
        for f in "${states[@]}"; do
            restored=$(find "$tmp" -type f -path "*/$f" | head -1)
            if [ -n "$restored" ] && cmp -s "$restored" "$f"; then
                echo "OK      $f"
            else
                echo "ROZNICA $f (brak w snapshocie albo inna zawartosc)" >&2
                rc=1
            fi
        done
        exit "$rc"
        ;;
    *)
        echo "uzycie: $0 [backup|snapshots|verify]" >&2
        exit 2
        ;;
esac
