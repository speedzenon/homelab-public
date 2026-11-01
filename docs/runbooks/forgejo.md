# Runbook: Forgejo

Własny serwer Git na repozytoria domowe. Platforma i samo Forgejo żyją w tym repo
na GitHubie — nic potrzebnego do odbudowy klastra nie jest wyłącznie w Forgejo.

| Co | Gdzie |
|---|---|
| UI / HTTPS | `https://git.int.dawidkraska.pl` (HTTPRoute z chartu, listener `https` Gatewaya `internal`) |
| SSH | `git@git.int.dawidkraska.pl`, port 22 na VIP-ie Gatewaya (TCPRoute → Service `forgejo-ssh` → pod:2222) |
| Application | `kubernetes/apps/forgejo.yaml` (chart OCI `code.forgejo.org/forgejo-helm/forgejo`, linia 17.x = Forgejo 15 LTS) |
| Values | `kubernetes/platform/forgejo/values.yaml` |
| Konto admina | `kubernetes/platform/forgejo/admin.sops.yaml` → `just forgejo-secret` → Secret `forgejo-admin` |
| Dane | PVC `forgejo-data` (klasa `iscsi-zfs-retain`): repozytoria, baza SQLite, klucze hosta SSH, `app.ini` |

`app.ini` na wolumenie zawiera klucze generowane raz przy pierwszym starcie
(`SECRET_KEY`, `JWT_SECRET` i in.). Utrata wolumenu bez kopii to nie tylko repozytoria:
także zaszyfrowane nimi sekrety 2FA i tokeny. Kopia musi obejmować cały wolumen.

## Pierwsze uruchomienie

1. Konto admina w SOPS (wzór: `admin.example.yaml`). Nazwa **nie** `admin` — jest
   zastrzeżona w Forgejo i tworzenie konta się nie powiedzie.

   ```bash
   sops kubernetes/platform/forgejo/admin.sops.yaml
   ```

2. Secret w klastrze: `just forgejo-secret` (tworzy też namespace, jeśli go nie ma).
   Bez Secretu pod czeka w `CreateContainerConfigError` i rusza sam, gdy Secret się pojawi.
3. Po merge'u: `just refresh root` (nowa Application w `kubernetes/apps/`).
4. Logowanie jako admin → Site Administration → User Accounts → Create User Account:
   konto do codziennej pracy (rejestracja jest wyłączona). Na tym koncie: klucz SSH i test:

   ```bash
   ssh -T git@git.int.dawidkraska.pl
   ```

   Przy pierwszym połączeniu klient pyta o klucz hosta — Forgejo trzyma go na wolumenie,
   więc nie zmienia się przy restartach poda.

## Rotacja hasła admina

`passwordMode: keepUpdated` — każdy start poda ustawia hasło z Secretu, więc źródłem
prawdy jest SOPS, nie UI (zmiana w UI zniknie przy restarcie).

```bash
sops kubernetes/platform/forgejo/admin.sops.yaml
just forgejo-secret
kubectl -n forgejo rollout restart deployment/forgejo
```

## Aktualizacje

- Patch/minor chartu 17.x (poprawki Forgejo 15 LTS) — zwykły PR Renovate.
- Major chartu — PR dopiero po akceptacji w Dependency Dashboard. Przed merge'em
  sprawdzić, którą wersję Forgejo instaluje (README chartu, „Upgrading”), i zrobić
  snapshot wolumenu — migracje bazy są jednokierunkowe:

  ```bash
  kubectl apply -f - <<'EOF'
  apiVersion: snapshot.storage.k8s.io/v1
  kind: VolumeSnapshot
  metadata:
    name: forgejo-data-pre-upgrade
    namespace: forgejo
  spec:
    volumeSnapshotClassName: iscsi-zfs-snap
    source:
      persistentVolumeClaimName: forgejo-data
  EOF
  ```

  Snapshot ZFS jest atomowy (spójny jak po zaniku zasilania — SQLite to znosi).
  To kopia na tym samym nodzie storage, nie backup.

## Ochrona danych

- `helm.sh/resource-policy: keep` (domyślne w chartcie) — ArgoCD traktuje jak
  `Delete=false`: PVC przeżywa usunięcie Application.
- `Prune=false` — PVC przeżywa zmianę nazwy lub usunięcie z values.
- Klasa `iscsi-zfs-retain` — po usunięciu PVC zostaje PV (`Released`) i zvol.

Ponowne podpięcie zachowanego PV do nowego PVC: zdjąć stare powiązanie
(`kubectl patch pv <pv> --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'`)
i wskazać PV w `persistence.volumeName`. Świadome skasowanie danych: zmienić
`persistentVolumeReclaimPolicy` PV na `Delete` — sterownik usunie zvol i target iSCSI.

## Czego jeszcze nie ma

- Backupu poza nodem storage (faza 5: snapshoty + restic → B2, test odtworzenia).
- Runnera Forgejo Actions (faza 6).
- SSO — logowanie lokalnymi kontami do czasu Authentika.
