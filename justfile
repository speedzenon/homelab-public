# https://just.systems
# Homelab command runner. Lista: `just`
set shell := ["bash", "-euo", "pipefail", "-c"]

net      := "infrastructure/network.sops.yaml"
tsecrets := "talos/secrets/lab-secrets.sops.yaml"
k8sver   := "1.35.2"

default:
    @just --list

# --- OpenTofu / Proxmox ---
tofu-plan:
    cd infrastructure/proxmox && sops exec-env secrets.sops.yaml 'tofu plan'

tofu-apply:
    cd infrastructure/proxmox && sops exec-env secrets.sops.yaml 'tofu apply'

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
talos-apply node *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    repo="$PWD"
    test -f "$repo/talos/patches/cluster.yaml" || { echo "BLAD: brak talos/patches/*.yaml"; exit 1; }
    tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
    NODE_IP=$(sops -d --extract '["k8s_clusters"]["lab"]["nodes"]["{{node}}"]["ip"]' {{net}})
    VIP=$(sops -d --extract '["k8s_clusters"]["lab"]["vip"]' {{net}})
    GW=$(sops -d --extract '["vlans"]["k8s"]["gateway"]' {{net}})
    DNS="$GW"; export NODE_IP VIP GW DNS
    sops exec-file --no-fifo {{tsecrets}} "talosctl gen config lab https://${VIP}:6443 \
        --with-secrets {} \
        --kubernetes-version {{k8sver}} \
        --config-patch @$repo/talos/patches/cluster.yaml \
        --config-patch @$repo/talos/patches/machine-base.yaml \
        --output-types controlplane \
        --output $tmpdir/controlplane.yaml --force"
    envsubst '${NODE_IP} ${GW} ${VIP} ${DNS}' < "$repo/talos/patches/network.tmpl.yaml" > "$tmpdir/net.yaml"
    talosctl machineconfig patch "$tmpdir/controlplane.yaml" --patch @"$tmpdir/net.yaml" -o "$tmpdir/final.yaml"
    talosctl validate -c "$tmpdir/final.yaml" -m cloud
    talosctl apply-config -n "$NODE_IP" -e "$NODE_IP" -f "$tmpdir/final.yaml" {{flags}}

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
    git switch main && git pull && git fetch --prune

# --- Cilium
cilium_ver := "1.19.4"
# break-glass: tylko gdy ArgoCD lezy; normalnie zarzadza Argo
cilium-install:
    helm repo add cilium https://helm.cilium.io/ --force-update
    helm upgrade --install cilium cilium/cilium \
        --version {{cilium_ver}} \
        --namespace kube-system \
        --values kubernetes/bootstrap/cilium/values.yaml

# --- ArgoCD
argocd_ver := "9.5.20"

argocd-install:
    helm repo add argo https://argoproj.github.io/argo-helm --force-update
    helm upgrade --install argocd argo/argo-cd \
        --version {{argocd_ver}} \
        --namespace argocd --create-namespace \
        --values kubernetes/bootstrap/argocd/values.yaml
    kubectl apply -f kubernetes/bootstrap/argocd/root-app.yaml

argocd-password:
    @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo

argocd-ui:
    kubectl -n argocd port-forward svc/argocd-server 8080:80
