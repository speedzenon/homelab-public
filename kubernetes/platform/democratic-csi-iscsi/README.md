# democratic-csi iSCSI - konfiguracja sekretu

Sterownik potrzebuje configu z kluczem prywatnym SSH usera `csi`. Ten config NIE
moze trafic jawny do repo, wiec uzywamy `existingConfigSecret`: Secret tworzymy
z bastionu z zaszyfrowanego SOPS-em pliku.

## Dlaczego ten sekret zostaje poza ESO na stale

External Secrets Operator ciagnalby ten klucz z OpenBao, a OpenBao potrzebuje
trwalego storage - ktory dostarcza wlasnie ten sterownik. Petla bootstrapu nie
do rozwiazania. Ten sekret nalezy do warstwy bootstrapu (jak klucz age czy
talosconfig), nie do ESO - to decyzja architektoniczna, nie prowizorka.

## Jednorazowe utworzenie configu

Na bastionie, z klucza csi wygenerowanego w Fazie 6 (`~/csi_ed25519`):

1. Skopiuj `config.example.yaml` -> `config.sops.yaml` w tym katalogu.
2. Wklej prawdziwy klucz prywatny w miejsce placeholdera w `privateKey`.
3. Zaszyfruj w miejscu (`.sops.yaml` w repo pokrywa ten katalog regula creation_rules):

   ```bash
   sops -e -i kubernetes/platform/democratic-csi-iscsi/config.sops.yaml
   ```

   Od tej chwili plik w repo jest zaszyfrowany - bezpieczny do commitu.

## Utworzenie Secretu w klastrze

Klucz w Secrecie MUSI nazywac sie `driver-config-file.yaml` - sterownik montuje
Secret pod /config i czyta plik o tej nazwie (flaga --driver-config-file w chartcie).
Zla nazwa = udany montaz, ale sterownik nie znajdzie pliku i wpadnie w crashloop.

```bash
kubectl create namespace democratic-csi \
  --dry-run=client -o yaml | kubectl apply -f -

sops -d kubernetes/platform/democratic-csi-iscsi/config.sops.yaml | \
  kubectl create secret generic democratic-csi-iscsi-config \
    --namespace democratic-csi \
    --from-file=driver-config-file.yaml=/dev/stdin
```

Rotacja klucza: usun Secret i odtworz go powyzsza komenda z nowym configiem,
potem `kubectl rollout restart` na controllerze i node DaemonSecie.

## Kolejnosc wdrozenia (Faza 7)

1. snapshot-controller (App) - CRD snapshot.storage.k8s.io. Sam wchodzi z automated.
2. Secret (powyzej) - PRZED sterownikiem, inaczej controller-pod nie wstanie.
3. democratic-csi-iscsi (App) - pierwszy Sync RECZNY (App Diff -> Sync), zgodnie
   ze szkola adopcji. automated osobnym PR po E2E (Faza 8).
