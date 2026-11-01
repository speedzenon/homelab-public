# Runbook: backup danych z klastra (VolSync → B2)

Obiekty Kubernetesa są w gicie (GitOps), sekrety w SOPS — kopii wymagają tylko dane
na wolumenach (PVC). Robi to VolSync: dla każdego PVC z polityki robi migawkę ZFS,
montuje ją tymczasowo i wysyła resticiem do Backblaze B2 (region EU Central).
restic szyfruje dane po stronie klastra, zanim cokolwiek wyjdzie do chmury.

| Co | Gdzie |
|---|---|
| Operator | Application `volsync` (ns `volsync-system`), chart `backube/volsync` |
| Polityka (co i jak często) | `kubernetes/infrastructure/backup/` — jeden ReplicationSource na PVC |
| Repozytoria | bucket B2 (prywatny), osobne repozytorium restica na PVC: `<bucket>/<ns>/<pvc>` |
| Dostęp | `kubernetes/platform/volsync/restic.sops.yaml` → `just volsync-secret <ns> <pvc>` → Secret `<pvc>-restic` |
| Stan | `just backup-status` |

## Jak przebiega jeden backup

1. O godzinie z `trigger.schedule` (cron w UTC) VolSync tworzy VolumeSnapshot PVC
   (klasa `iscsi-zfs-snap` — natywna migawka ZFS, atomowa i natychmiastowa).
2. Z migawki powstaje tymczasowy PVC (klasa `iscsi-zfs`), który montuje Job movera
   `volsync-src-<nazwa>`. Mover działa jako uid 1000 bez dodatkowych uprawnień.
3. `restic backup`, potem `restic forget` wg `retain` (u nas: 7 dziennych, 4 tygodniowe,
   12 miesięcznych); `restic prune` co `pruneIntervalDays` (7 dni).
4. VolSync usuwa tymczasowy PVC, migawkę i Job. Zostaje tylko PVC cache restica
   (`volsync-src-<nazwa>-cache`, metadane repozytorium — przyspiesza kolejne backupy).

Pierwszy backup startuje od razu po utworzeniu ReplicationSource, kolejne wg harmonogramu.

### Spójność migawki

Migawkę robi ZFS na nodzie storage, na poziomie zvola. Widzi tylko to, co węzeł Kubernetesa
zdążył już zapisać przez iSCSI — **nie widzi jego page cache**. Efekt jest taki jak po nagłym
zaniku zasilania węzła. Aplikacja przetrwa to bez strat tylko wtedy, gdy sama robi fsync
tego, co musi przeżyć:

- SQLite robi fsync przy każdym commicie, więc baza jest spójna;
- git **domyślnie nie** robi fsync luźnych obiektów ani refów (tylko paczek). Mały push
  (< 100 obiektów) trafia jako luźne obiekty, więc migawka zrobiona do ~30 s po nim ma puste
  pliki obiektów i pusty ref (ext4 z opóźnioną alokacją). Wykrył to pierwszy test odtworzenia
  (01.11.2026); naprawa: `git.config: core.fsync: all` w values Forgejo — git utrwala każdy
  plik, zanim nada mu docelową nazwę, więc repo jest w stanie sprzed pusha albo po nim.
  Ta sama poprawka chroni świeży push przy awarii zasilania węzła;
- pliki pisane bez fsync (załączniki, awatary) są w migawce pewne po ~30 s bezczynności
  (zapis z page cache), stąd harmonogram w nocy.

Przy nowej aplikacji sprawdzić, czy robi fsync ważnych danych. Bazy z własnymi mechanizmami
(Postgres) dostaną własny backup (CNPG + Barman), nie migawkę wolumenu.

## Konfiguracja B2 (jednorazowo)

- Bucket tylko na backup klastra: **Private**, bez Object Lock; szyfrowanie po stronie B2
  zbędne (robi to restic).
- Lifecycle: **Keep prior versions for this number of days: 30**. Przez API S3 restic nie
  kasuje plików, tylko je „ukrywa”; reguła usuwa ukryte wersje po 30 dniach. Daje to
  30 dni na odwrócenie przypadkowego (albo wrogiego) skasowania backupów.
- Klucz aplikacyjny ograniczony do tego bucketu, **Read and Write**. Gdyby restic dostawał
  „Access Denied” przy inicjalizacji repozytorium, dodać kluczowi „Allow List All Bucket Names”.

## Bez czego backup jest bezużyteczny

- **`RESTIC_PASSWORD`** — szyfruje wszystkie repozytoria. Kopia musi leżeć poza labem
  (menedżer haseł, papier). Bez niej danych w B2 nie da się odczytać.
- **Klucz age** (SOPS) — bez niego nie odszyfrujesz `restic.sops.yaml`; kopia hasła restica
  poza labem rozwiązuje to niezależnie od klucza age.

## Sekret repozytorium

```bash
sops kubernetes/platform/volsync/restic.sops.yaml      # wzór: restic.example.yaml
just volsync-secret forgejo forgejo-data               # Secret forgejo-data-restic w ns forgejo
```

Przepis zamienia `RESTIC_REPOSITORY_BASE` na `RESTIC_REPOSITORY=<BASE>/<ns>/<pvc>`.
Trzeci argument zmienia ścieżkę repozytorium (test odtworzenia w innym namespace).
Repozytorium restic inicjalizuje VolSync przy pierwszym backupie.

## Stan i diagnostyka

```bash
just backup-status
kubectl -n forgejo get replicationsource forgejo-data -o jsonpath='{.status.latestMoverStatus.logs}{"\n"}'
kubectl -n forgejo describe replicationsource forgejo-data     # warunki, błędy
```

`latestMoverStatus.logs` to przefiltrowany wynik restica z ostatniego przebiegu (także
po usunięciu Joba). W trakcie backupu: `kubectl -n forgejo logs -f job/volsync-src-forgejo-data`.

## Test odtworzenia

Backup bez sprawdzonego odtworzenia to tylko nadzieja. Test przy wdrożeniu (bramka fazy 5),
potem co kwartał. Odtwarzamy do osobnego namespace'u — produkcja zostaje nietknięta.
Test ma sens tylko z danymi: co najmniej jedno repo z commitami (stałe repo testowe
`backup-test`). Najsurowsza wersja: push i natychmiast wymuszony backup
(`kubectl -n forgejo delete replicationsource forgejo-data` — ArgoCD odtworzy obiekt, a nowy
ReplicationSource robi pierwszy backup od razu) — sprawdza też fsync gita.

```bash
kubectl create namespace restore-test
kubectl label namespace restore-test pod-security.kubernetes.io/enforce=restricted
just volsync-secret restore-test forgejo-data forgejo/forgejo-data
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: forgejo-data-restore
  namespace: restore-test
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: iscsi-zfs
  resources:
    requests:
      storage: 10Gi
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: forgejo-data-restore
  namespace: restore-test
spec:
  trigger:
    manual: restore-1
  restic:
    repository: forgejo-data-restic
    destinationPVC: forgejo-data-restore
    copyMethod: Direct
    cacheStorageClassName: iscsi-zfs
    moverSecurityContext:
      runAsNonRoot: true
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
      seccompProfile:
        type: RuntimeDefault
EOF
kubectl -n restore-test get replicationdestination forgejo-data-restore -w   # aż LAST SYNC się wypełni
```

Weryfikacja: baza na miejscu i spójność wszystkich repozytoriów (`git fsck` sprawdza każdy obiekt):

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: verify
  namespace: restore-test
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: verify
      image: code.forgejo.org/forgejo/forgejo:15-rootless
      command:
        - sh
        - -c
        - |
          ls -la /data/*.db /data/gitea/conf/app.ini || exit 1
          n=0
          for r in /data/git/gitea-repositories/*/*.git; do
            [ -d "$r" ] || continue
            echo "== $r"; git -C "$r" fsck --no-progress || exit 1
            n=$((n+1))
          done
          echo "RESTORE-OK, repozytoria: $n"
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: forgejo-data-restore
EOF
kubectl -n restore-test logs -f verify      # na końcu: RESTORE-OK i liczba repozytoriów
kubectl delete namespace restore-test       # PVC z klasą iscsi-zfs znika razem z zvolem
```

Starszy stan zamiast najnowszego: w ReplicationDestination `previous: N` (N-ty snapshot
wstecz) albo `restoreAsOf: "2026-11-01T03:00:00+01:00"`.

Przeprowadzone testy (następny: luty 2027):

| Data | Wynik |
|---|---|
| 01.11.2026 | błąd: puste obiekty i ref w świeżo wypchniętym repo (git bez fsync) → `core.fsync: all` (#79) |
| 01.11.2026 | OK: push i migawka ~10 s później, `git fsck` bez błędów, baza i `app.ini` na miejscu |

## Odbudowa po awarii (z danymi)

Zasada: aplikacja nie może zainicjować pustego wolumenu, zanim dane wrócą, a backup
nie może zrobić kopii pustego wolumenu (retencja liczy dni — pusty snapshot z dzisiaj
wypchnąłby dzisiejszy dobry).

1. Bootstrap jak zwykle, ale **bez** `just volsync-secret` (ReplicationSource bez sekretu
   nie zrobi kopii). Forgejo wstanie na pustym wolumenie — to nic, zaraz go nadpiszemy.
2. Wstrzymanie automatyki i aplikacji:

   ```bash
   for a in root forgejo backup; do
     kubectl -n argocd patch application $a --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
   done
   kubectl -n forgejo scale deployment forgejo --replicas=0
   kubectl -n forgejo delete replicationsource forgejo-data
   ```

3. `just volsync-secret forgejo forgejo-data`, potem ReplicationDestination jak w teście,
   ale w ns `forgejo`, z `destinationPVC: forgejo-data`, `enableFileDeletion: true`
   i `restoreAsOf` sprzed awarii. Po zakończeniu usunąć ReplicationDestination.
4. Przywrócenie automatyki: `kubectl apply -f kubernetes/bootstrap/argocd/root-app.yaml`
   (root odzyskuje automated i przywraca je aplikacjom) → Forgejo wraca, ReplicationSource
   też i od razu robi pierwszą kopię odtworzonych danych.

## Nowy PVC w backupie

1. Manifest w `kubernetes/infrastructure/backup/` na wzór `forgejo-data.yaml`:
   `sourcePVC`, `repository: <pvc>-restic`, `moverSecurityContext` z uid/gid właściciela
   plików aplikacji, klasy tymczasowe zawsze `iscsi-zfs`.
   Sprawdzić, czy aplikacja robi fsync danych, które muszą przeżyć (patrz „Spójność migawki”).
2. `just volsync-secret <ns> <pvc>` przed merge'em.
3. Po pierwszym backupie — test odtworzenia jak wyżej.
