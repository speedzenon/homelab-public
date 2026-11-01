# https://just.systems
# Homelab command runner. Lista: `just`
set shell := ["bash", "-euo", "pipefail", "-c"]

net       := "infrastructure/network.sops.yaml"
tsecrets  := "talos/secrets/lab-secrets.sops.yaml"

# Wersje z jednego zrodla: talos/versions.yaml (czyta je tez tofu) oraz
# targetRevision Application-ow w kubernetes/apps/ (podbijane przez Renovate;
# wyjatek: CRD Gateway API - recznie, razem z Cilium).
talos_version   := `awk -F': *' '$1=="version"{gsub(/"/,"",$2); split($2,a," "); print a[1]}' talos/versions.yaml`
talos_schematic := `awk -F': *' '$1=="schematic"{gsub(/"/,"",$2); split($2,a," "); print a[1]}' talos/versions.yaml`
k8s_version     := `awk -F': *' '$1=="kubernetes"{gsub(/"/,"",$2); split($2,a," "); print a[1]}' talos/versions.yaml`
install_image   := "factory.talos.dev/installer/" + talos_schematic + ":v" + talos_version
cilium_version  := `awk '/^[[:space:]]+targetRevision:/{print $2; exit}' kubernetes/apps/cilium.yaml`
argocd_version  := `awk '/^[[:space:]]+targetRevision:/{print $2; exit}' kubernetes/apps/argocd.yaml`
gateway_version := `awk '/^[[:space:]]+targetRevision:/{print $2; exit}' kubernetes/apps/gateway-api-crds.yaml`

default:
    @just --list

# Pusta wartosc = zly format pliku z wersjami; blokuje recepty, zanim cos zepsuja
_versions:
    @for v in "talos_version={{talos_version}}" "talos_schematic={{talos_schematic}}" "k8s_version={{k8s_version}}" "cilium_version={{cilium_version}}" "argocd_version={{argocd_version}}" "gateway_version={{gateway_version}}"; do [ -n "${v#*=}" ] || { echo "BLAD: pusta wersja ${v%%=*} (talos/versions.yaml / kubernetes/apps)"; exit 1; }; done

# --- OpenTofu (dir: proxmox | mikrotik) ---
tofu-plan dir="proxmox":
    cd infrastructure/{{dir}} && sops exec-env secrets.sops.yaml 'tofu plan'

tofu-apply dir="proxmox":
    cd infrastructure/{{dir}} && sops exec-env secrets.sops.yaml 'tofu apply'

# Skrypt plynie przez SSH na stdin perla - na hoscie nic nie zostaje.
# --- PVE: audyt firewalla gosci i szablonow (tylko odczyt). Kod: 0 OK, 1 odstepstwa, 2 blad ---
fw-audit host="wtrmax":
    #!/usr/bin/env bash
    set -euo pipefail
    IP=$(sops -d --extract '["hosts"]["{{host}}"]["mgmt_ip"]' {{net}})
    ssh "root@${IP}" perl - < scripts/pve-fw-audit

# Adresy z SOPS -> argumenty scripts/bootstrap-media.sh, ktory sam ich nie zawiera.
# --- Media: kontenery LXC stosu mediow (np. just media-bootstrap arr). Idempotentne. ---
media-bootstrap +cts="jellyfin downloads arr":
    #!/usr/bin/env bash
    set -euo pipefail
    x() { sops -d --extract "$1" {{net}}; }
    c() { x "[\"lxc\"][\"$ct\"][\"$1\"]"; }
    v() { x "[\"vlans\"][\"$vlan\"][\"$1\"]"; }
    for ct in {{cts}}; do
        vlan=$(c vlan); host=$(c host); vmid=$(c vmid); ip=$(c ip)
        vlan_id=$(v id); cidr=$(v cidr); gw=$(v gateway)
        host_ip=$(x "[\"hosts\"][\"$host\"][\"mgmt_ip\"]")
        echo "### $ct -> $host (VMID $vmid, VLAN $vlan_id)"
        ssh "root@${host_ip}" bash -s -- "$ct" "$vmid" "$vlan_id" "$ip/${cidr#*/}" "$gw" < scripts/bootstrap-media.sh
    done

# --- Talos: sekrety klastra (JEDNORAZOWO; zaszyfrowane SOPS, nigdy plaintext w repo) ---
talos-gen-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    test ! -f {{tsecrets}} || { echo "BLOKADA: {{tsecrets}} juz istnieje"; exit 1; }
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    talosctl gen secrets -o "$tmp" --force
    sops -e --filename-override {{tsecrets}} "$tmp" > {{tsecrets}}
    echo "OK: $(basename {{tsecrets}}) zaszyfrowany"

# --- Talos: render + walidacja + apply (pierwszy raz: just talos-apply talos-lab-cp1 --insecure) ---
talos-apply node *flags: _versions
    #!/usr/bin/env bash
    set -euo pipefail
    repo="$PWD"
    test -f "$repo/talos/patches/cluster.yaml" || { echo "BLAD: brak talos/patches/*.yaml"; exit 1; }
    tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
    NODE_IP=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["ip"]' {{net}})
    VIP=$(sops -d --extract '["k8s_clusters"]["lab"]["vip"]' {{net}})
    MAC=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["mac"]' {{net}})
    STORAGE_IP=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["storage_ip"]' {{net}})
    STORAGE_MAC=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["storage_mac"]' {{net}})
    GW=$(sops -d --extract '["vlans"]["k8s"]["gateway"]' {{net}})
    K8S_CIDR=$(sops -d --extract '["vlans"]["k8s"]["cidr"]' {{net}})
    STORAGE_CIDR=$(sops -d --extract '["vlans"]["storage"]["cidr"]' {{net}})
    K8S_PREFIX=${K8S_CIDR#*/}; STORAGE_PREFIX=${STORAGE_CIDR#*/}
    DNS="$GW"; export NODE_IP MAC STORAGE_IP STORAGE_MAC VIP GW DNS K8S_PREFIX STORAGE_PREFIX
    sops exec-file --no-fifo {{tsecrets}} "talosctl gen config lab https://${VIP}:6443 \
        --with-secrets {} \
        --kubernetes-version {{k8s_version}} \
        --install-image {{install_image}} \
        --config-patch @$repo/talos/patches/cluster.yaml \
        --config-patch @$repo/talos/patches/machine-base.yaml \
        --output-types controlplane \
        --output $tmpdir/controlplane.yaml --force"
    envsubst '${NODE_IP} ${MAC} ${STORAGE_IP} ${STORAGE_MAC} ${GW} ${VIP} ${DNS} ${K8S_PREFIX} ${STORAGE_PREFIX}' < "$repo/talos/patches/network.tmpl.yaml" > "$tmpdir/net.yaml"
    talosctl machineconfig patch "$tmpdir/controlplane.yaml" --patch @"$tmpdir/net.yaml" -o "$tmpdir/final.yaml"
    talosctl validate -c "$tmpdir/final.yaml" -m cloud
    talosctl apply-config -n "$NODE_IP" -e "$NODE_IP" -f "$tmpdir/final.yaml" {{flags}}

# --image z Image Factory: bez niego talosctl bierze czysty installer i gubi extensions
# --- Talos: upgrade wezla do wersji z versions.yaml. WEZEL PO WEZLE (etcd: max 1 naraz) ---
talos-upgrade node: _versions
    #!/usr/bin/env bash
    set -euo pipefail
    NODE_IP=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["ip"]' {{net}})
    talosctl upgrade -n "$NODE_IP" -e "$NODE_IP" --image {{install_image}}

# --- Kubernetes: upgrade control plane + kubeletow do wersji z versions.yaml ---
talos-upgrade-k8s node="talos-lab-cp1": _versions
    #!/usr/bin/env bash
    set -euo pipefail
    NODE_IP=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["ip"]' {{net}})
    talosctl upgrade-k8s -n "$NODE_IP" -e "$NODE_IP" --to {{k8s_version}}

# --- Talos: talosconfig klienta -> ~/.talos/config (po pierwszym apply) ---
talos-talosconfig node="talos-lab-cp1":
    #!/usr/bin/env bash
    set -euo pipefail
    tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
    NODE_IP=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["ip"]' {{net}})
    VIP=$(sops -d --extract '["k8s_clusters"]["lab"]["vip"]' {{net}})
    sops exec-file --no-fifo {{tsecrets}} "talosctl gen config lab https://${VIP}:6443 \
        --with-secrets {} --output-types talosconfig \
        --output $tmpdir/talosconfig --force"
    talosctl config merge "$tmpdir/talosconfig"
    talosctl config endpoint "$NODE_IP"
    talosctl config node "$NODE_IP"
    echo "OK: kontekst 'lab' w ~/.talos/config (endpoint=IP wezla, NIE VIP)"

# --- Talos: bootstrap etcd. RAZ NA ZYCIE KLASTRA, tylko na pierwszym CP ---
talos-bootstrap node="talos-lab-cp1":
    #!/usr/bin/env bash
    set -euo pipefail
    NODE_IP=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["ip"]' {{net}})
    talosctl bootstrap -n "$NODE_IP" -e "$NODE_IP"

talos-kubeconfig node="talos-lab-cp1":
    #!/usr/bin/env bash
    set -euo pipefail
    NODE_IP=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["ip"]' {{net}})
    talosctl kubeconfig -n "$NODE_IP" -e "$NODE_IP"

talos-dmesg node="talos-lab-cp1":
    #!/usr/bin/env bash
    set -euo pipefail
    NODE_IP=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["ip"]' {{net}})
    talosctl dmesg -f -n "$NODE_IP" -e "$NODE_IP"

# --- Git workflow ---
feat name:
    git switch main && git pull && git switch -c feat/{{name}}

pr:
    git push -u origin HEAD
    gh pr create --title "$(git log -1 --pretty=%s)" --body ""

done:
    #!/usr/bin/env bash
    set -euo pipefail
    git switch main && git pull && git fetch --prune
    for b in $(git branch --format='%(refname:short)' | grep -v '^main$'); do
        state=$(gh pr view "$b" --json state -q .state 2>/dev/null || echo NONE)
        if [ "$state" = "MERGED" ]; then git branch -D "$b" && echo "sprzatnieto: $b"; fi
    done

# --- Bootstrap klastra (Day-1 / odbudowa), w tej kolejnosci:
#     gateway-crds -> cilium-install -> csi-secret -> ovh-secret -> forgejo-secret -> argocd-install
# Wersje chartow i CRD = targetRevision z kubernetes/apps/ - helm i kubectl instaluja
# dokladnie to, co potem adoptuje ArgoCD.

# Release'owy standard-install.yaml = te same obiekty co katalog config/crd/standard,
# z ktorego synchronizuje Application gateway-api-crds. --force-conflicts: przy
# ponownym uruchomieniu (break-glass) pola naleza juz do Argo.
# Day-1 PRZED cilium-install: CRD Gateway API (operator Cilium sprawdza je przy starcie)
gateway-crds: _versions
    kubectl apply --server-side --force-conflicts \
        -f https://github.com/kubernetes-sigs/gateway-api/releases/download/{{gateway_version}}/standard-install.yaml

# Day-1 (bez CNI pody ArgoCD nie wstana) oraz break-glass, gdy ArgoCD lezy
cilium-install: _versions
    helm repo add cilium https://helm.cilium.io/ --force-update
    helm upgrade --install cilium cilium/cilium \
        --version {{cilium_version}} \
        --namespace kube-system \
        --values kubernetes/bootstrap/cilium/values.yaml

# sops uruchamia kubectl: gdy odszyfrowanie padnie, do apply nie trafia nic (pusty
# Secret nie nadpisze dzialajacego). Idempotentne - takze do rotacji klucza.
# Secret z configiem democratic-csi (klucz SSH, poza GitOps) - PRZED argocd-install
csi-secret:
    kubectl create namespace democratic-csi --dry-run=client -o yaml | kubectl apply -f -
    sops exec-file --no-fifo kubernetes/platform/democratic-csi-iscsi/config.sops.yaml \
        'kubectl create secret generic democratic-csi-iscsi-config --namespace democratic-csi --from-file=driver-config-file.yaml={} --dry-run=client -o yaml' | \
        kubectl apply --server-side --force-conflicts -f -

# Ten sam wzorzec co csi-secret. --output-type dotenv: sops oddaje plik jako
# KLUCZ=wartosc, a kubectl robi z kazdej linii osobny klucz Secretu.
# Secret z kluczem API OVH dla webhooka DNS-01 cert-managera (poza GitOps)
ovh-secret:
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    sops exec-file --no-fifo --output-type dotenv kubernetes/platform/cert-manager-webhook-ovh/ovh-credentials.sops.yaml \
        'kubectl create secret generic ovh-credentials --namespace cert-manager --from-env-file={} --dry-run=client -o yaml' | \
        kubectl apply --server-side --force-conflicts -f -

# Ten sam wzorzec co ovh-secret (klucze username/password). Chart czyta Secret przez
# gitea.admin.existingSecret, a przy passwordMode keepUpdated kazdy start poda ustawia
# haslo z Secretu - rotacja: sops edit, ten przepis, restart Deploymentu forgejo.
# Secret z kontem admina Forgejo (poza GitOps)
forgejo-secret:
    kubectl create namespace forgejo --dry-run=client -o yaml | kubectl apply -f -
    sops exec-file --no-fifo --output-type dotenv kubernetes/platform/forgejo/admin.sops.yaml \
        'kubectl create secret generic forgejo-admin --namespace forgejo --from-env-file={} --dry-run=client -o yaml' | \
        kubectl apply --server-side --force-conflicts -f -

argocd-install: _versions
    helm repo add argo https://argoproj.github.io/argo-helm --force-update
    helm upgrade --install argocd argo/argo-cd \
        --version {{argocd_version}} \
        --namespace argocd --create-namespace \
        --values kubernetes/bootstrap/argocd/values.yaml
    kubectl apply -f kubernetes/bootstrap/argocd/root-app.yaml

# Secret istnieje tylko do pierwszej zmiany hasla (potem do usuniecia - zalecenie ArgoCD).
# Day-1: pierwsze haslo admina ArgoCD
argocd-password:
    @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo

# Na co dzien UI jest pod https://argocd.int.dawidkraska.pl (Gateway 'internal').
# UI ArgoCD przez port-forward (break-glass, gdy Gateway/DNS/certyfikat leza): http://localhost:8080
argocd-ui:
    kubectl -n argocd port-forward svc/argocd-server 8080:80

# ArgoCD sprawdza repo co kilka minut; refresh robi to od razu, a synchronizacje
# automated sync. 'root' - gdy zmieniaja sie pliki w kubernetes/apps/; gdy tylko
# zasoby lub values aplikacji - jej nazwa (mozna kilka: just refresh gateway argocd)
# Wymusza odswiezenie aplikacji ArgoCD po merge'u (domyslnie root)
refresh +apps="root":
    kubectl -n argocd annotate applications.argoproj.io {{apps}} argocd.argoproj.io/refresh=normal --overwrite
