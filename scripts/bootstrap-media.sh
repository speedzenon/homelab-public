#!/usr/bin/env bash
# bootstrap-media.sh - kontener LXC stosu mediow na hoscie PVE.
#
# Normalnie przez 'just media-bootstrap': just czyta adresy z network.sops.yaml
# i przesyla ten skrypt przez SSH (ssh root@<host> bash -s -- <argumenty>).
# Recznie na hoscie jako root:  bash bootstrap-media.sh <argumenty>
#
# Argumenty: <nazwa> <vmid> <vlan_id> <ip/prefiks> <brama>
#   nazwa: jellyfin | downloads | arr - profil zasobow, urzadzen i montowan ponizej
#
# Skrypt nie zawiera adresow (hook RFC1918) - wszystkie przychodza w argumentach.
# Idempotentny: istniejacy kontener o tym VMID i tej nazwie hosta jest pomijany,
# brakujace kroki (katalogi, podman) sa dokanczane.
# Konwencja VMID: (VLAN/10)*100 + ostatni oktet (docs/runbooks/local-addressing.md).
# Firewall kontenera wlaczony juz przy tworzeniu (wejscie DROP); reguly i dalsze
# zarzadzanie opcjami - OpenTofu (infrastructure/proxmox/firewall.tf).
set -euo pipefail

ST=${ST:-fast-ct}     # lokalny zfspool na NVMe (fast/pve-ct, recordsize 16K)
MEDIA=${MEDIA:-/data/media}  # dataset data/media, uklad TRaSH: torrents/ + media/
MEDIA_ID=101002       # UID/GID 1002 w nieuprzywilejowanym LXC (przesuniecie 100000)

die() { echo "STOP: $*" >&2; exit 1; }

main() {
    [[ $# -eq 5 ]] || die "uzycie: $0 <nazwa> <vmid> <vlan_id> <ip/prefiks> <brama>"
    local name=$1 vmid=$2 vlan_id=$3 ip=$4 gw=$5

    [[ $vmid =~ ^[0-9]+$ && $vlan_id =~ ^[0-9]+$ ]] || die "VMID i VLAN musza byc liczbami"
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "adres w formacie a.b.c.d/prefiks: $ip"
    local octet=${ip%/*}
    octet=${octet##*.}
    # Dzielenie calkowite celowo przed mnozeniem: floor(VLAN/10)*100, jak w firewall.tf
    local expected=$(( (vlan_id / 10) * 100 + octet ))
    (( vmid == expected )) \
        || die "VMID $vmid nie wynika z VLAN $vlan_id i oktetu .$octet (oczekiwane $expected)"

    # --- profil: zasoby, urzadzenia, montowania ---
    local cores mem disk
    local -a extra
    case $name in
        jellyfin)
            cores=4 mem=4096 disk=32
            # renderD128 dla VAAPI; gid=993 = grupa render widziana w kontenerze
            extra=(--dev0 "/dev/dri/renderD128,gid=993" --mp0 "$MEDIA/media,mp=/data/media,ro=1") ;;
        downloads)
            cores=2 mem=2048 disk=8
            extra=(--dev0 /dev/net/tun --mp0 "$MEDIA/torrents,mp=/data/torrents") ;;
        arr)
            cores=4 mem=4096 disk=32
            # caly dataset jednym montowaniem - dwa osobne bind mounty psuja hardlinki
            extra=(--mp0 "$MEDIA,mp=/data") ;;
        *) die "nieznany kontener: $name (jellyfin | downloads | arr)" ;;
    esac

    # --- warunki na hoscie ---
    local node tpl vnet
    node=$(uname -n)
    node=${node%%.*}    # nazwa noda PVE = hostname bez domeny (jak w PVE::INotify)
    tpl=$(pveam list local | awk '/debian-13-standard/ {print $1}' | sort -V | tail -1)
    [[ -n $tpl ]] || die "brak szablonu debian-13-standard (pveam update; pveam download local ...)"
    pvesm status --content rootdir | awk 'NR>1 {print $1}' | grep -qx "$ST" \
        || die "storage $ST nie przyjmuje rootfs kontenerow (docs/runbooks/nas-storage.md)"
    [[ -d $MEDIA ]] || die "brak $MEDIA"
    local dev
    for dev in /dev/dri/renderD128 /dev/net/tun; do [[ -e $dev ]] || die "brak $dev"; done

    # VNet szukany po tagu VLAN-u (nazwy VNetow: scripts/bootstrap-sdn.sh)
    vnet=$(pvesh get /cluster/sdn/vnets --output-format json \
        | TAG=$vlan_id perl -MJSON::PP -0777 -ne \
            'print map { "$_->{vnet}\n" } grep { ($_->{tag} // -1) == $ENV{TAG} } @{decode_json($_)}')
    [[ -n $vnet && $(wc -l <<<"$vnet") -eq 1 ]] \
        || die "oczekiwany dokladnie jeden VNet z tagiem $vlan_id, jest: ${vnet:-brak} (scripts/bootstrap-sdn.sh)"

    # --- katalogi wg TRaSH, wlasciciel = UID/GID 1002 w LXC; setgid = dziedziczenie grupy ---
    install -d -o "$MEDIA_ID" -g "$MEDIA_ID" -m 2775 \
        "$MEDIA/torrents" "$MEDIA/media" \
        "$MEDIA/torrents/tv" "$MEDIA/torrents/movies" "$MEDIA/media/tv" "$MEDIA/media/movies"

    # --- kontener ---
    if pct config "$vmid" >/dev/null 2>&1; then
        pct config "$vmid" | grep -qx "hostname: $name" || die "VMID $vmid istnieje, ale to nie '$name'"
        echo "== $name ($vmid): juz istnieje - pomijam tworzenie"
    else
        grep -qs "\"$vmid\"" /etc/pve/.vmlist && die "VMID $vmid zajety na innym wezle"
        echo "== $name ($vmid): tworze na $ST, VNet $vnet"
        pct create "$vmid" "$tpl" \
            --hostname "$name" --unprivileged 1 --features nesting=1,keyctl=1 \
            --onboot 1 --tags media --cores "$cores" --memory "$mem" \
            --rootfs "$ST:$disk" \
            --net0 "name=eth0,bridge=$vnet,ip=$ip,gw=$gw,firewall=1" \
            --nameserver "$gw" \
            "${extra[@]}"
        # Bezpieczny od narodzin: te same opcje co w firewall.tf; reguly doklada OpenTofu.
        pvesh set "/nodes/$node/lxc/$vmid/firewall/options" \
            --enable 1 --policy_in DROP --policy_out ACCEPT \
            --ipfilter 1 --macfilter 1 --dhcp 0 --ndp 0 --radv 0
    fi

    pct status "$vmid" | grep -q running || pct start "$vmid"

    # --- podman w kontenerze (dokanczane, jesli wczesniejszy przebieg sie przerwal) ---
    if pct exec "$vmid" -- sh -c 'command -v podman' >/dev/null 2>&1; then
        echo "== $name ($vmid): podman jest - gotowy"
        return 0
    fi
    local i
    for i in $(seq 1 30); do
        pct exec "$vmid" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
        [[ $i -eq 30 ]] && die "$name: brak DNS w kontenerze po 60 s (brama/DNS w VLAN $vlan_id?)"
        sleep 2
    done
    pct exec "$vmid" -- bash -c 'apt-get update && apt-get -y full-upgrade &&
        apt-get -y install podman curl &&
        ln -sf /usr/share/zoneinfo/Europe/Warsaw /etc/localtime'
    echo "== $name ($vmid): gotowy"
}

# stdin z /dev/null: przy 'bash -s' skrypt przychodzi przez stdin, a pct exec
# zjadlby jego reszte. Funkcja wczytuje sie w calosci, zanim cokolwiek ruszy.
main "$@" </dev/null
