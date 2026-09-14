# Runbook: renumeracja adresów węzłów PVE

Procedura zmiany adresów IP węzłów w działającym klastrze Proxmox VE, wykonana
w lipcu 2026 (hosty przeniesione do docelowego bloku adresowego zgodnie
z `local-addressing.md`). Zawiera trzy incydenty, które wystąpiły w praktyce.

Adresy nie są tu wpisane wprost — źródłem prawdy jest `infrastructure/network.sops.yaml`.

## 1. Zasada: jeden węzeł na raz

Klaster ma 3 głosy (2 węzły + QDevice), próg kworum = 2. Wyłączenie corosync
na jednym węźle zostawia drugi + QDevice = **2 głosy, klaster kworalny przez
całe okno**.

Cena po stronie renumerowanego węzła: jego pmxcfs (`/etc/pve`) przechodzi
w read-only do czasu powrotu. **VM-ki działają dalej** — QEMU/LXC nie zależą
od pmxcfs w runtime.

To fundamentalna różnica względem zmiany obu naraz: tam traci się kworum
globalnie i pmxcfs zamarza wszędzie.

## 2. Bramka przed startem

```bash
ha-manager status
```

**Musi** pokazać brak zasobów HA / watchdog w standby. HA + flap kworum =
ryzyko fencingu (samowolnego restartu węzła przez softdog).

Sprawdzić też, gdzie mieszka bastion — jeśli na renumerowanym hoście, reboot
zabija stację roboczą operacji. Wtedy całe okno prowadzić z innego punktu
i potwierdzić `qm config <vmid> | grep onboot` (ma być `onboot: 1`).

Mieć fizyczną konsolę w zasięgu.

## 3. Trzy warstwy konfiguracji corosync

Kluczowa wiedza, bez której incydenty poniżej są nie do zdiagnozowania:

1. **`/etc/pve/corosync.conf`** — stan pożądany w pmxcfs (klastrowy, replikowany).
2. **`/etc/corosync/corosync.conf`** — lokalna kopia, z której demon **faktycznie
   startuje**. pmxcfs synchronizuje (1) → (2) na każdym węźle, ale **tylko póki
   węzeł jest kworalny**.
3. **Stan runtime knet** — tablica peerów z adresami, budowana przy starcie demona.

Każde przejście między warstwami ma własny tryb awarii.

## 4. Procedura (per węzeł)

### 4.1 Dead-man switch

Wariant przeżywający reboot (transient timer `systemd-run` ginie przy restarcie):

```bash
cp /etc/network/interfaces /etc/network/interfaces.bak
cp /etc/hosts /etc/hosts.bak
touch /root/netchange.pending
crontab -l 2>/dev/null | { cat; echo '@reboot sleep 900 && test -f /root/netchange.pending && cp /etc/network/interfaces.bak /etc/network/interfaces && cp /etc/hosts.bak /etc/hosts && reboot'; } | crontab -
```

Jeśli w 15 min po reboocie nie zalogujesz się i nie skasujesz flagi — host wraca
do stanu sprzed. **Rozbroić natychmiast po udanym logowaniu**, przed diagnostyką
czegokolwiek:

```bash
rm -f /root/netchange.pending
crontab -l | grep -v netchange.pending | crontab -
```

### 4.2 Edycja corosync.conf — z węzła OCALAŁEGO

Zapis do pmxcfs wymaga kworum w chwili zapisu; edycja z węzła, który pozostanie
kworalny, wyklucza wyścig.

```bash
# WĘZEŁ OCALAŁY
cp /etc/pve/corosync.conf /root/corosync.conf.new
# w kopii: ring0_addr renumerowanego węzła → nowy adres
#          config_version: N → N+1
nano /root/corosync.conf.new
cp /root/corosync.conf.new /etc/pve/corosync.conf

# peer-wpis w /etc/hosts (API bierze stąd adres partnera)
sed -i 's/<stary-adres>/<nowy-adres>/' /etc/hosts
```

W momencie zapisu corosync przeładowuje się na obu węzłach. Ring zaczyna oczekiwać
renumerowanego węzła pod nowym adresem, którego jeszcze nie ma → **węzeł wypada
z membership**. To oczekiwane.

### 4.3 Bramka synchronizacji lokalnej kopii

**Krok obowiązkowy, nie warunkowy** (patrz incydent 1):

```bash
# WĘZEŁ RENUMEROWANY — PRZED rebootem
grep -E 'config_version|ring0_addr' /etc/corosync/corosync.conf
```

Musi pokazać **nową** wersję i **nowy** adres. Jeśli nie — skopiować ręcznie
z węzła ocalałego (`/etc/corosync/` to zwykły lokalny FS, nie wymaga kworum):

```bash
scp root@<ocalały>:/etc/corosync/corosync.conf /etc/corosync/corosync.conf
```

### 4.4 Pliki lokalne i reboot

```bash
# /etc/network/interfaces — nowy adres na vmbr0 (i ew. nowa noga VLAN storage)
# /etc/hosts — własny wpis węzła
reboot
```

### 4.5 Restart corosync na węźle nie-renumerowanym

**Krok obowiązkowy, wykonywany zawsze** (patrz incydent 2):

```bash
# WĘZEŁ OCALAŁY — po powrocie renumerowanego
systemctl restart corosync
sleep 5 && pvecm status
```

Koszt: ~5 sekund read-only pmxcfs. Zysk: determinizm zamiast czekania, czy knet
sam zaktualizuje tablicę peerów.

### 4.6 Weryfikacja

```bash
pvecm status                    # 3 głosy, oba węzły A,V,NMW, nowy adres
pvecm updatecerts -f && systemctl restart pveproxy   # cert pveproxy ma IP w SAN
```

Z bastionu:

```bash
ssh-keygen -R <stary-adres>     # stary klucz hosta z known_hosts
cd infrastructure/proxmox && tofu plan   # BRAMKA: "No changes"
```

Jeśli endpoint providera wskazywał na renumerowany węzeł — podmienić
w `secrets.sops.yaml` przed `tofu plan`.

## 5. Incydenty (lipiec 2026)

### Incydent 1: lokalna kopia corosync.conf

**Objaw:** `pvecm updatecerts` w pętli wypisuje `waiting for pmxcfs mount to appear
and get quorate`, kończy się timeoutem.

**Mechanizm:** węzeł po reboocie startuje ze **starą** lokalną kopią i próbuje
bindować się do adresu, którego już nie ma na żadnym interfejsie. W praktyce
synchronizacja zdążyła (wersja była poprawna), ale to był pierwszy typowany
podejrzany i bramka z 4.3 pozostaje.

**Diagnostyka:**

```bash
grep -E 'config_version|ring0_addr' /etc/corosync/corosync.conf
journalctl -u corosync -b --no-pager | tail -25
```

### Incydent 2: stale peer-table knet

**To była prawdziwa przyczyna zawieszenia w incydencie 1.**

**Objaw:** w journalu węzła ocalałego, powtarzane co sekundę:

```text
[KNET] rx: Packet rejected from <nowy-adres>:5405
```

Na węźle renumerowanym: `[KNET] host: host: 1 has no active links`.

**Mechanizm:** knet trzyma tablicę peerów budowaną przy starcie. Reload
konfiguracji poprawnie dokłada i usuwa węzły, ale **zmiana adresu istniejącego
peera przy reloadzie jest zawodna** — węzeł ocalały dalej celuje w stary adres,
a pakiety z nowego odrzuca na wejściu (przed kryptografią i członkostwem).
Link martwy w obie strony, mimo że **oba pliki konfiguracyjne są poprawne**.

Charakterystyczna poszlaka: QDevice widoczny jako `A` (Alive — połączenie do
qnetd działa), ale `NV` (Non-Voting) — algorytm ffsplit oddał głos drugiej
partycji. To nie split-brain, tylko czysta partycja z jedną stroną uprzywilejowaną.
`Expected votes: 2` po stronie odciętej to widok z wnętrza jego partycji, nie
globalna prawda.

**Rozwiązanie:** `systemctl restart corosync` na węźle odrzucającym. Handshake
zajmuje sekundę (`host: 2 link: 0 is up`). Stąd krok 4.5 jako obowiązkowy.

**Weryfikacja runtime (nie pliku):**

```bash
corosync-cfgtool -n     # węzły z perspektywy działającego demona
```

Przed restartem pokazywał tylko lokalny węzeł, zero peerów z linkami.

### Incydent 3: fałszywy alarm ICMP

**Objaw:** `ping` do hosta w segmencie storage — 100% packet loss, mimo że
wszystko działa.

**Mechanizm:** host INPUT policy DROP przepuszczała tylko TCP z grupy
bezpieczeństwa (iSCSI, NFS, SSH). ICMP nie było na liście → spadało na policy.
Ruch z VLAN mgmt tego problemu nie ma, bo pve-firewall automatycznie akceptuje
sieć klastra (corosync musi żyć) — stąd zaskoczenie akurat na storage.

**Rozwiązanie:** reguła ICMP dodana do grupy storage (segment nieroutowany,
więc echo-request może wysłać tylko maszyna fizycznie w nim obecna).

**Wniosek metodyczny:** w segmentach z policy DROP weryfikować `nc -zv` na porty
z grupy, nie pingiem. `TTL 64` w odpowiedzi potwierdza dodatkowo, że ruch nie
przeszedł przez router (czysty L2).

## 6. Katalog odcisków palca

| Komunikat | Warstwa | Działanie |
|---|---|---|
| `waiting for pmxcfs ... get quorate` | Kworum | Sprawdzić membership, nie certy |
| `Packet rejected from <ip>:5405` | knet runtime | `systemctl restart corosync` po stronie odrzucającej |
| `host: N has no active links` | knet runtime | jw., z drugiej strony |
| `Could not bind to address` | Lokalna kopia conf | Skopiować conf z węzła ocalałego |
| Ping timeout, usługi działają | Firewall | Weryfikować `nc`, nie pingiem |
| QDevice `A,NV` | Partycja | Jedna strona uprzywilejowana — nie split-brain |

## 7. Pozostałe do zrobienia

Migracja QDevice (obecnie na sieci legacy) wymaga edycji `quorum.device.net.host`
i najpewniej `pvecm qdevice remove && setup` — `remove` zdejmuje expected votes
do 2/2, więc oba węzły muszą żyć w tym oknie. Mniejsza operacja niż renumeracja
członka ringu (arbiter nie ma `ring0_addr`), ale ta sama dyscyplina.
