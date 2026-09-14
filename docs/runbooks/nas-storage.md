# Runbook: storage na hoście nas

Stan as-built po Fazach 6–8 (lipiec–sierpień 2026). Opisuje warstwę storage:
datasety ZFS, target iSCSI (LIO), eksporty NFS, użytkownika `csi` oraz sterownik
democratic-csi w klastrze.

Adresy nie są tu wpisane wprost — źródłem prawdy jest `infrastructure/network.sops.yaml`.
W komendach `<nas-storage>` oznacza adres hosta nas w VLAN 50, `<nas-mgmt>` w VLAN 10.

## 1. Architektura w skrócie

democratic-csi **nie jest storage'em** — to translator. Controller-pod w klastrze
przyjmuje wywołania CSI (gRPC: `CreateVolume`, `CreateSnapshot`, `DeleteVolume`)
i tłumaczy je na komendy wykonywane **po SSH na hoście nas**:

- `zfs create -V ...` tworzy zvol (wolumen blokowy),
- `targetcli` wystawia go jako LUN po iSCSI.

Node-pody (DaemonSet) robią drugą połowę: `iscsiadm` loguje się do targetu i
podpina urządzenie blokowe pod poda.

Host nas musi więc umieć trzy rzeczy: mieć strukturę datasetów, mieć działający
**target** iSCSI z persystencją po reboocie, i przyjmować sterowanie po SSH.

## 2. Layout datasetów

```text
fast/k8s/iscsi/v     # zvole per PVC (RWO fs + RWX Block dla KubeVirt)
fast/k8s/iscsi/s     # detached snapshots — RODZEŃSTWO v, nie dziecko
fast/k8s/nfs/v       # przygotowane pod Fazę 7b (RWX Filesystem)
fast/k8s/nfs/s
data/media           # recordsize=1M, statyczny eksport NFS
data/immich          # recordsize=1M, statyczny eksport NFS
data/pve-vms         # 128K, shared storage PVE (HDD tier)
fast/pve-vms         # 64K, shared storage PVE (NVMe tier)
```

### Dlaczego `v` i `s` są rodzeństwem

Detached snapshoty to nie zwykłe snapshoty w drzewie wolumenu, tylko pełne,
niezależne kopie (`zfs send | zfs recv`). Gdyby `s` był dzieckiem `v`, rekurencyjne
operacje sterownika na drzewie wolumenów (`zfs destroy -r`) przecinałyby drzewo
snapshotów. Dokumentacja democratic-csi zakazuje zawierania się tych ścieżek
w sobie — w obu kierunkach.

Dodatkowo: `detachedSnapshotsDatasetParentName` musi być ustawione **nawet jeśli
nie planuje się snapshotów** — sterownik nie akceptuje braku tego pola.

### Dlaczego takie recordsize

- **1M na media/immich** — duże pliki czytane sekwencyjnie. Mniej rekordów na plik,
  mniej metadanych, mniej seeków na HDD, lepsza kompresja per rekord. Kara za 1M
  istnieje tylko przy losowych *częściowych* nadpisaniach wewnątrz dużych plików;
  media to workload zapisz-raz-czytaj-wiele. Małe pliki (miniatury) nie tracą,
  bo `recordsize` to *górny limit*, nie stały rozmiar.
- **64K na fast/pve-vms** — qcow2 ma domyślny cluster size 64K; wyrównanie
  eliminuje read-modify-write.
- **128K na data/pve-vms** — domyślne, mniej IOPS-ożerne na HDD.
- **16K volblocksize na zvolach** (w configu sterownika) — kompromis dla ext4/xfs
  z blokiem 4K. Mniej → narzut metadanych i gorsza kompresja; więcej → write
  amplification. Na mirrorze brak problemu z paddingiem parzystości (inaczej niż RAIDZ).

**Uwaga:** `recordsize` działa tylko na nowo zapisywane bloki, a `volblocksize`
jest niezmienialny po utworzeniu zvolu. Ustawiać **przed** wgraniem danych.

## 3. Target iSCSI (LIO) i persystencja

LIO to target iSCSI wbudowany w kernel, konfigurowany przez configfs
(`/sys/kernel/config/target`). Configfs jest **ulotny** — po reboocie pusty.
`targetcli saveconfig` zrzuca stan do `/etc/rtslib-fb-target/saveconfig.json`,
a usługa systemd odtwarza go przy starcie.

```bash
apt install -y targetcli-fb
systemctl list-unit-files | grep -i rtslib     # potwierdzić nazwę usługi
systemctl enable --now rtslib-fb-targetctl
```

Bez włączonej usługi restore targety utworzone przez sterownik **znikną po
pierwszym reboocie** — zvole (dane) przetrwają, ale PVC przestaną się podpinać.
Zweryfikowane testem rebootu w Fazie 8: trzy aktywne sesje iSCSI wróciły poprawnie.

### Port 3260 nie nasłuchuje od razu

LIO otwiera portal dopiero, gdy istnieje pierwszy obiekt targetu — a te tworzy
sterownik per wolumen. **`connection refused` na 3260 przy zerowej liczbie PVC
jest stanem poprawnym**, nie awarią.

## 4. Eksporty NFS (v4-only)

```bash
apt install -y nfs-kernel-server
```

Wyłączenie v3 (`/etc/nfs.conf.d/zz-v4only.conf`):

```ini
[nfsd]
vers3=n
```

Drop-in eliminujący race przy boocie (`/etc/systemd/system/nfs-server.service.d/zfs.conf`):

```ini
[Unit]
After=zfs-mount.service
```

Bez tego `nfs-server` potrafi wystartować przed zamontowaniem datasetów ZFS
i wyeksportować **puste katalogi**.

Eksporty w `/etc/exports` (nie przez `zfs set sharenfs` — jedna widoczna prawda
w jednym pliku; sterownik NFS w Fazie 7b będzie zarządzał swoimi eksportami
przez `exportfs` obok, bez konfliktu):

```text
/data/media    <storage-cidr>(rw,sync,no_subtree_check,root_squash)
/data/immich   <storage-cidr>(rw,sync,no_subtree_check,root_squash)
/data/pve-vms  <storage-cidr>(rw,sync,no_subtree_check,no_root_squash)
/fast/pve-vms  <storage-cidr>(rw,sync,no_subtree_check,no_root_squash)
```

`no_root_squash` **tylko** dla pve-vms — PVE zapisuje obrazy jako root.
Media i Immich mają `root_squash`: dostęp idzie przez konkretny UID, więc
skompromitowany pod z prawami roota nie przejmie biblioteki.

`rpcbind` nasłuchuje na 111 mimo v4-only — to `nfs-common`, które PVE ciągnie
jako *klient* NFS. Świadomie zostawione: firewall nie otwiera 111, a wyłączanie
rpcbind na siłę gryzie się z zależnościami pakietowymi PVE.

## 5. Użytkownik csi

### PVE nie ma sudo

Instalator Proxmoksa nie instaluje pakietu `sudo` (model administracyjny jest
root-centryczny). Sterownik wykonuje `sudo zfs` / `sudo targetcli`, więc sudo
jest **twardą zależnością runtime**:

```bash
apt install -y sudo
grep -E '^[@#]includedir' /etc/sudoers    # musi być: @includedir /etc/sudoers.d
```

`#includedir` (starsza forma) **nie jest komentarzem** — sudo parsuje ją specjalnie.

### Klucz i uprawnienia

Klucz generowany na bastionie; część prywatna nigdy nie trafia na nas —
idzie do SOPS i do Secretu w klastrze.

```bash
# BASTION
ssh-keygen -t ed25519 -N '' -C 'democratic-csi@lab' -f ~/csi_ed25519
```

Pusta passphrase jest świadoma: klucza używa bezobsługowo controller-pod.
Ochroną w spoczynku jest SOPS+age, w runtime — Secret w klastrze.

```bash
# NAS
useradd -m -s /bin/bash csi
install -d -m 700 -o csi -g csi /home/csi/.ssh
# authorized_keys z ograniczeniem from= (patrz niżej)
chown csi:csi /home/csi/.ssh/authorized_keys && chmod 600 /home/csi/.ssh/authorized_keys

command -v zfs targetcli    # sudoers matchuje pełne ścieżki — zweryfikować PRZED
```

`/etc/sudoers.d/csi`:

```text
csi ALL=(root) NOPASSWD: /usr/sbin/zfs, /usr/bin/targetcli
```

```bash
chmod 440 /etc/sudoers.d/csi
visudo -cf /etc/sudoers.d/csi    # MUSI dać "parsed OK"
```

Błąd składni w `sudoers.d` potrafi zablokować sudo globalnie — walidować
**zawsze przed** wyjściem z sesji root.

Zasada least privilege: dokładamy uprawnienia punktowo, gdy sterownik zgłosi
brak (nazywa brakującą komendę w błędzie). `exportfs` dojdzie przy Fazie 7b.

### Ograniczenie from=

Logi sshd potwierdziły, że controller łączy się ze **storage IP węzła** klastra
(SNAT), nie z adresu poda. Adresy węzłów są statyczne, więc ograniczenie jest trwałe:

```text
from="<cp1-storage>,<cp2-storage>,<cp3-storage>" ssh-ed25519 AAAA... democratic-csi@lab
```

**Punkt utrzymaniowy:** przy dodaniu czwartego węzła trzeba dopisać jego adres,
inaczej dostanie odmowę bez oczywistego komunikatu.

## 6. Sterownik w klastrze

Dwie Application ArgoCD, w tej kolejności:

1. **snapshot-controller** — CRD `snapshot.storage.k8s.io` (VolumeSnapshot,
   VolumeSnapshotContent, VolumeSnapshotClass) + kontroler. Kubernetes nie ma
   tych typów w rdzeniu; SIG-Storage zostawił je poza core, żeby cykl życia API
   nie był przykuty do wydań k8s. **Jedyne miejsce instalujące te CRD** — są
   cluster-scoped, więc drugi chart dałby konflikt właścicielstwa.
2. **democratic-csi-iscsi** — sam sterownik. Bez CRD sidecar `csi-snapshotter`
   wpada w crashloop.

Podział ról przy snapshotach: `snapshot-controller` obserwuje `VolumeSnapshot`
(namespaced, "prośba") i tworzy `VolumeSnapshotContent` (cluster-scoped, faktyczny
snapshot). Sidecar `csi-snapshotter` obserwuje `VolumeSnapshotContent` i woła
`CreateSnapshot` na sterowniku. Analogia: `VolumeSnapshot` ma się do
`VolumeSnapshotContent` jak PVC do PV.

### Sekret z configiem

Config sterownika zawiera klucz prywatny SSH → nie może trafić do publicznych
values. Używamy `existingConfigSecret`; procedura w
`kubernetes/platform/democratic-csi-iscsi/README.md`.

Klucz w Secrecie **musi** nazywać się `driver-config-file.yaml` — sterownik montuje
Secret pod `/config` i czyta plik o tej nazwie (`--driver-config-file`). Zła nazwa
= udany montaż i crashloop z mylącym komunikatem.

**Ten sekret zostaje poza ESO na stałe.** ESO ciągnąłby go z OpenBao, a OpenBao
potrzebuje trwałego storage — który dostarcza ten sterownik. Cyrkularność bootstrapu.
Należy do warstwy bootstrapu, jak klucz age czy `talosconfig`.

### Pułapki konfiguracji

- **`driver.config.driver` musi być jawnie w values** mimo `existingConfigSecret` —
  chart używa go do logiki warunkowej (`contains "iscsi"` → montowania iSCSI
  w node-podach). Bez tego node-pody nie działają.
- **`sudoEnabled: true` w dwóch miejscach** (`zfs.cli` i `shareStrategyTargetCli`) —
  w przykładzie upstream to drugie jest **zakomentowane**, bo przykład zakłada roota.
- **`iscsiDirHostPath: /var/iscsi`** — Talos ma read-only rootfs; domyślne
  `/etc/iscsi` daje błąd zapisu przy pierwszym logowaniu do targetu.
  Wymaga też extension `iscsi-tools` w schematicu Talosa.
- **Namespace z etykietą `pod-security.kubernetes.io/enforce: privileged`** —
  node-pody potrzebują `privileged`, montowań z propagacją `Bidirectional`
  i namespace'ów hosta. Bez etykiety apiserver odrzuca pody **po cichu**:
  DaemonSet istnieje, zero podów, brak błędu. Ustawiane deklaratywnie przez
  `managedNamespaceMetadata`.

### IQN

Format: `iqn.RRRR-MM.odwrócona-domena:etykieta`. Data oznacza miesiąc, w którym
byłeś właścicielem domeny (nie "dziś") — to gwarantuje globalną unikalność.
Limit 223 bajty na całą nazwę; sterownik dokleja identyfikator wolumenu, więc
długi basename zjada budżet. Wpisywany na stałe w każdy target — **zmiana po
fakcie = migracja wolumenów**.

ACL: `generate_node_acls: 1` włącza tryb demo (każdy initiator z VLAN 50 może się
podłączyć). Izolacja jest **sieciowa** (nieroutowany VLAN + INPUT DROP), nie
tożsamościowa. CHAP dokładałby zarządzanie hasłami bez realnego zysku.

### emulate_tpu

Ustawione na `1` (upstream ma `0`). Ogłasza obsługę SCSI UNMAP. Bez tego thin-zvol
rośnie monotonicznie do rozmiaru nominalnego: gdy system plików w podzie kasuje
pliki, aktualizuje tylko własne struktury — warstwa blokowa nie wie o zwolnieniu
i ZFS trzyma bloki zaalokowane w nieskończoność. Klasyczna przyczyna "znikającego"
miejsca na thin-provisioned SAN.

Wykorzystanie po stronie klienta: `fstrim` (zbiorczo, preferowane) albo
`-o discard` (inline, dokłada operację do ścieżki krytycznej). Dla KubeVirta
z `discard=unmap` TRIM z gościa przechodzi przez QEMU aż do LUN-a.

## 7. Wyniki testów E2E (Faza 8)

Zweryfikowane empirycznie:

| Test | Wynik |
|---|---|
| PVC RWO + zapis danych | ✅ zvol pod `/v`, target w LIO, mount w podzie |
| Snapshot natywny | ✅ jako `@snapshot` na zvolu |
| Snapshot detached | ✅ osobny dataset pod `/s` |
| Restore ze snapshotu (`dataSource`) | ✅ dane odtworzone |
| RWX Block na 2 węzłach naraz | ✅ podwójny attach działa → KubeVirt odblokowany |
| Usunięcie PVC + snapshotów | ✅ czyste, zero pozostałości |
| Reboot nas z aktywnymi sesjami | ✅ 3 sesje iSCSI wróciły |

### Czego NIE przetestowano

**RWX Filesystem** — to inny mechanizm niż RWX Block. Test RWX Block używał
`volumeMode: Block`: pody dostały surowe urządzenie i **nic nie zapisywały**.
Dwa pody z własnym ext4 na wspólnym urządzeniu = natychmiastowa korupcja
(lokalny FS zakłada wyłączne władztwo nad metadanymi). Przy KubeVircie koordynację
zapewnia QEMU.

Współdzielenie *plików* wymaga protokołu koordynującego dostęp — czyli drugiej
instancji sterownika z `zfs-generic-nfs` (Faza 7b), która używa `fast/k8s/nfs/v` i `/s`.

## 8. Storage PVE

Dwa storage NFS zarejestrowane na obu nodach:

```bash
pvesm add nfs nfs-data-vms --server <nas-storage> --export /data/pve-vms \
  --content images --options vers=4.2
pvesm add nfs nfs-fast-vms --server <nas-storage> --export /fast/pve-vms \
  --content images --options vers=4.2
```

Wymuszony `vers=4.2` (bez rpcbind). Mount **hard** (domyślny) zostaje — `soft`
przy shared storage dla VM to przepis na cichą korupcję obrazów przy timeoutach.
Pad nas = VM-ki wiszą do powrotu storage'u, co jest pożądaną semantyką przy
świadomym SPOF mitygowanym backupem.

Zvole democratic-csi nie kolidują z PVE: plugin zfspool uznaje za swoje tylko
nazwy pasujące do `(vm|base|subvol|basevol)-<vmid>-disk-*`. **Zasada higieny:**
nigdy nie tworzyć ręcznie datasetów o takich nazwach pod naszymi ścieżkami.

Przepustowość: dyski VM z `fast` po NFS są ograniczone siecią (2,5G ≈ 280 MB/s
plus latencja na każdym sync). To cena za live migration. Alternatywa lokalna
(storage zfspool `fast`) pozostaje dostępna per VM.

## 9. Diagnostyka — katalog odcisków palca

| Objaw | Znaczenie | Działanie |
|---|---|---|
| `connection refused` na 3260 | Portal LIO nie istnieje (zero PVC) | Poprawne — nie diagnozować |
| `timeout` / 100% loss na ping | Firewall DROP | Weryfikować `nc` na porty z grupy, nie pingiem |
| `access denied by server` (NFS) | Tablica eksportów | `exportfs -v`, `journalctl -t rpc.mountd` |
| `secret ... not found` | Brak Secretu z configiem | Utworzyć wg README |
| `csiDriver.name is required` | Chart nie widzi values | Sprawdzić plik values, potem Hard Refresh |
| DaemonSet bez podów, brak błędu | PSA odrzuca privileged | Etykiety namespace |
| Zwiększające się `used` mimo kasowania | Brak UNMAP | `emulate_tpu: 1` + fstrim |

ArgoCD cachuje błędy renderowania — po poprawce **wymagany Hard Refresh**:

```bash
kubectl -n argocd patch app <nazwa> --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

Logi sterownika (główne narzędzie diagnostyczne):

```bash
kubectl -n democratic-csi logs -f deploy/democratic-csi-iscsi-controller -c csi-driver
```
