# Archived docs

Guides for things that were **removed or superseded**. The three original write-ups (old logging stack,
Vaultwarden, the first SOPS plan) were deleted in Oct 2026; what remains of them is the summary below.

| Was | Status |
|---|---|
| Loki + Alloy + Grafana logging stack | removed from the cluster (Sept 2026). Uptime/alerting is Gatus now (`docs/apps/gatus.md`); Grafana may return later for history. Cluster leftovers: `docs/runbooks/cluster-cleanup.md` §1. |
| Vaultwarden (password manager) | removed from the homelab (Oct 2026). Its `vaultwarden` database on the Postgres LXC (`.7`) was left as a backup; drop it once the vault export is confirmed. Cleanup: `cluster-cleanup.md` §4. |
| RomM (ROM library) | removed (Nov 2026). Its setup guide is kept here: [`romm.md`](romm.md). ROMs and saves stay on NFS; DB, Valkey user and cluster leftovers: `cluster-cleanup.md` §9. |
| Ghostfolio (portfolio tracking) | removed (Nov 2026); Wealthfolio replaces it. Setup guide [`ghostfolio.md`](ghostfolio.md) and the DB-app walkthrough [`deploy-ghostfolio.md`](deploy-ghostfolio.md) kept here. Its Postgres DB is kept as a backup; cleanup: `cluster-cleanup.md` §10. |
| Komf (manga metadata for Kavita) | removed (Nov 2026). Cluster leftovers: `cluster-cleanup.md` §8. |
| The original SOPS + age + KSOPS plan | done. Current docs: `docs/platform/secrets.md` (day-to-day), `docs/platform/secrets-architecture.md` (deep dive). |
