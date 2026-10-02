# Archived docs

Guides for things that were **removed or superseded**. Kept for the learning record; nothing
here describes the current cluster.

| Doc | Status |
|---|---|
| `logging.md` | Loki + Alloy + Grafana stack — removed from the cluster (Sept 2026). If monitoring comes back, see the "Not automated" notes in `docs/updates-and-notifications.md`. |
| `vaultwarden.md` | Vaultwarden (password manager) — **removed from the homelab (Oct 2026)**. Its Postgres database `vaultwarden` on the LXC (192.168.68.7) was left in place as a backup; drop it once you are sure the vault is exported. |
| `sops-argocd.md` | the original plan for SOPS + age + KSOPS — done. Current docs: `docs/secrets.md` (day-to-day) and `docs/secrets-architecture.md` (deep dive). |
