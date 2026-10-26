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
just csi-secret
```

Recepta tworzy namespace i Secret z `config.sops.yaml` (`sops -d | kubectl create
secret --dry-run | kubectl apply`), wiec jest idempotentna - pasuje i do Day-1,
i do odbudowy klastra.

Rotacja klucza: zaktualizuj `config.sops.yaml`, uruchom ponownie `just csi-secret`,
potem `kubectl rollout restart` na controllerze i node DaemonSecie.

## Kolejnosc wdrozenia (Day-1 / odbudowa)

`just gateway-crds` -> `just cilium-install` -> `just csi-secret` -> `just argocd-install`. Secret musi
byc PRZED syncem sterownika (wszystkie App-y maja automated) - inaczej controller-pod
wisi w ContainerCreating (FailedMount) do czasu utworzenia Secretu. Argo
(CreateNamespace + managedNamespaceMetadata) naklada etykiety PSA na istniejacy namespace.

snapshot-controller (CRD snapshot.storage.k8s.io) wchodzi przed sterownikiem; jesli
sterownik zsynchronizuje sie pierwszy, sidecar csi-snapshotter restartuje sie, az CRD
sie pojawia. Historycznie (Faza 7-8) pierwszy Sync byl reczny, automated po E2E.
