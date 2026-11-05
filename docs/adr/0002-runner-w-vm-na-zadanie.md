# ADR 0002: Runner Forgejo Actions w VM uruchamianej na żądanie

- **Status:** przyjęta, 05.11.2026
- **Dotyczy:** runner Forgejo Actions (`infrastructure/proxmox/runner.tf`, `infrastructure/ansible/runner.yml`)

## Kontekst

- Runner wykonuje kod z repozytoriów — także cudzy: zależności npm/pip, akcje z
  `data.forgejo.org`, wersje podbijane przez Renovate.
- Joby mają budować obrazy, więc dostają gniazdo podmana (`docker_host: automount`). Job
  steruje wtedy całym podmanem runnera — w praktyce ma jego uprawnienia. Jedyną prawdziwą
  granicą zostaje to, co oddziela runnera od hosta.
- Host to g-flip: 2 z 3 control-plane'ów Talosa, czyli cały klaster.
- Budowanie będzie rzadkie (rzędu raz w miesiącu), a RAM g-flipa ma też inne plany.

## Decyzja

- **VM zamiast LXC.** Granicą jest hypervisor (KVM), a nie wspólne jądro hosta z pełnym
  zestawem wywołań systemowych. Dokumentacja Forgejo: LXC chroni przed przypadkowym
  uszkodzeniem, nie przed złośliwym jobem; do izolacji runnera — VM.
- **Podman rootless w VM** (użytkownik `runner`). Job z gniazdem steruje podmanem tego
  użytkownika; do roota VM musiałby jeszcze eskalować uprawnienia. W nieuprzywilejowanym
  LXC rootless praktycznie odpada (brak zakresów uid).
- **Na żądanie:** VM domyślnie wyłączona (`on_boot = false`); `just runner-up` ją uruchamia,
  a timer w VM wyłącza ją po 30 min bez kontenera joba. Job czeka w kolejce Forgejo do 24 h
  (`ABANDONED_JOB_TIMEOUT`), więc kolejność push / start jest dowolna.
- **Rozmiar:** 2 vCPU, 4 GB RAM (zapas na budowanie obrazów; wyłączona VM nie zajmuje RAM-u),
  32 GB dysku. Jeden job naraz.

## Konsekwencje

- Wyłączona VM nie zajmuje RAM-u; dysk (z cache obrazów podmana) zostaje między startami.
- Pierwszy job po starcie czeka ok. pół minuty na boot. Wyłączona VM nie dostaje
  aktualizacji, ale też nic nie wystawia; po starcie aktualizacje doganiają od razu, a nowe
  jądro wchodzi przy każdym starcie — automatyczne restarty niepotrzebne.
- OpenTofu: `started` w `ignore_changes` modułu `vm` — inaczej każdy `tofu apply` włączałby
  wyłączoną VM.
- W Forgejo runner przez większość czasu ma status *Offline* — to stan normalny.

## Rozważane alternatywy

- **LXC** (pierwotny plan fazy 6) — lżejszy, ale granica = jądro hosta; jego przewagi
  (GPU dla kilku kontenerów, bind mount danych z hosta) runnerowi do niczego.
- **VM zawsze włączona** — najprościej, ale 4 GB RAM zajęte na stałe dla użytku raz w miesiącu.
- **Pełny automat** — „budzik” pytający Forgejo o czekające joby (`GET /api/v1/admin/actions/runners/jobs`)
  i startujący VM przez API PVE. Odłożone: wymaga dostępu z klastra do API hypervisora
  (dziś tylko sieć admin), tokenu PVE i tokenu admina Forgejo (brak zakresu „tylko
  runnery”). Do rozważenia, gdy CI zacznie chodzić regularnie — część w VM zostaje ta sama.
- **Świeża VM na każdy job** (klon + runner efemeryczny) — najsilniejsza izolacja, za dużo
  ruchomych części przy tej skali.
