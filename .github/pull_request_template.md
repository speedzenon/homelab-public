## Co
<!-- Krótki opis zmiany w 1-2 zdaniach -->

## Dlaczego
<!-- Motywacja, problem do rozwiązania, kontekst biznesowy/techniczny -->

## Jak
<!-- Podejście techniczne, kluczowe decyzje, zastosowane wzorce -->

## Faza projektu
<!-- Zaznacz fazę, której dotyczy zmiana (x w nawiasie) -->
- [ ] Phase 0 — Fundament Git + CI
- [ ] Phase 1 — Sieć (MikroTik, VLAN, WireGuard, Headscale)
- [ ] Phase 2 — Hypervisor + storage (Proxmox, ZFS, PBS)
- [ ] Phase 3 — Kubernetes (Talos, Cilium, ArgoCD)
- [ ] Phase 4 — PKI + secrets (Step-CA, OpenBao, ESO)
- [ ] Phase 5 — IAM + zero trust (Authentik, Pomerium)
- [ ] Phase 6 — Security detection (Wazuh, Tetragon, Kyverno)
- [ ] Phase 7 — Supply chain (Cosign, SBOM)
- [ ] Phase 8 — Observability (Prometheus, Grafana, Loki)
- [ ] Phase 9 — Backup / DR (Velero, B2)
- [ ] Phase 10 — Workloady
- [ ] Cross-cutting / inne

## Checklist weryfikacji

- [ ] Pre-commit hooks przechodzą lokalnie
- [ ] CI jest zielone
- [ ] Przetestowane w środowisku nie-produkcyjnym (jeśli dotyczy)
- [ ] Dokumentacja zaktualizowana (README / runbook / ADR)
- [ ] Pliki z sekretami zaszyfrowane SOPS — żadnego plaintext
- [ ] Brak breaking changes LUB breaking changes opisane poniżej

## Uwagi
<!-- Ryzyka, plan rollback, follow-upy, linki do powiązanych issue/PR -->
