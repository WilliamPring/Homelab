# Archived docs

Guides for things that were **removed or superseded**. The three original write-ups (old logging stack,
Vaultwarden, the first SOPS plan) were deleted in Oct 2026; what remains of them is the summary below.

| Was | Status |
|---|---|
| Loki + Alloy + Grafana logging stack | removed from the cluster (Sept 2026). Uptime/alerting is Gatus now (`docs/apps/gatus.md`); Grafana may return later for history. Cluster leftovers: `docs/runbooks/cluster-cleanup.md` §1. |
| Vaultwarden (password manager) | removed from the homelab (Oct 2026). Its `vaultwarden` database on the Postgres LXC (`.7`) was left as a backup; drop it once the vault export is confirmed. Cleanup: `cluster-cleanup.md` §4. |
| The original SOPS + age + KSOPS plan | done. Current docs: `docs/platform/secrets.md` (day-to-day), `docs/platform/secrets-architecture.md` (deep dive). |
