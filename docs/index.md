# Start here

A personal homelab: Proxmox hosts → a k3s cluster (1 master + 1 worker) built by **Ansible**, with every app
deployed from this repo by **Argo CD**. Photos (Immich), manga + books (Kavita, Suwayomi, Komf, Calibre-Web),
games (RomM), search (SearXNG, degoog), and the glue (cert-manager, ntfy, Gatus, Homepage).

## The map

| Directory | What | Who touches it |
|---|---|---|
| `ansible/` | the nodes: Tailscale, k3s, the few out-of-git secrets/labels | you, `ansible-playbook site.yml` |
| `kubernetes/bootstrap/` | Argo CD itself + the `Application` pointers | you, `kubectl apply`, rarely |
| `kubernetes/apps/<namespace>/<app>/` | every app's manifests | git push → Argo → **you click Sync** |
| `docs/` | this | |
| `scripts/ci/` | the validation CI runs (and you can run) | `make validate` |

Conventions in one page: [`../CLAUDE.md`](../CLAUDE.md). Layout details: [`../kubernetes/README.md`](../kubernetes/README.md).

## The daily loop
```
edit a manifest → git push → CI green (render + schema + lint) → Argo shows OutOfSync
   → phone: "<app>: update waiting" (ntfy) → review the diff in Argo → Sync → phone: "deployed"
```
Renovate opens the version-bump PRs on Mondays (security fixes any day). **Nothing merges or deploys
by itself.** Details: [`platform/updates-and-notifications.md`](platform/updates-and-notifications.md).

## Docs by purpose

**Apps** — one guide per app: setup, how it fits, troubleshooting
- [`apps/immich.md`](apps/immich.md) — photos (+ public share proxy)
- [`apps/kavita.md`](apps/kavita.md) — manga/books reader, Komf metadata, Calibre-Web books
- [`apps/suwayomi.md`](apps/suwayomi.md) — online manga sources, Paperback on iPhone
- [`apps/kindle.md`](apps/kindle.md) — KOReader on the Kindle (OPDS, sync, Suwayomi plugin)
- [`apps/romm.md`](apps/romm.md) — ROM library + browser play
- [`apps/degoog.md`](apps/degoog.md) — search
- [`apps/gatus.md`](apps/gatus.md) — uptime checks → ntfy

**Platform** — the things apps rely on
- [`platform/argocd.md`](platform/argocd.md) — Argo CD: install, apply, register apps, gotchas
- [`platform/tls.md`](platform/tls.md) — cert-manager + Let's Encrypt (Cloudflare DNS-01)
- [`platform/secrets.md`](platform/secrets.md) — SOPS day-to-day · [`platform/secrets-architecture.md`](platform/secrets-architecture.md) — the deep dive
- [`platform/updates-and-notifications.md`](platform/updates-and-notifications.md) — Renovate, CI guard, Argo → ntfy
- [`platform/redis.md`](platform/redis.md) — the shared Valkey and per-app ACL users

**Runbooks** — do-this-when
- [`runbooks/cheatsheet.md`](runbooks/cheatsheet.md) — everyday kubectl / Ansible
- [`runbooks/cluster-cleanup.md`](runbooks/cluster-cleanup.md) — delete the orphans left by removed apps
- [`runbooks/proxmox-install.md`](runbooks/proxmox-install.md) · [`runbooks/couchdb-lxc-setup.md`](runbooks/couchdb-lxc-setup.md) · [`runbooks/tailscale-mullvad-exit-node.md`](runbooks/tailscale-mullvad-exit-node.md)

**Architecture** — the thinking (some of it predates the current build; read as history + direction)
- [`architecture/production-architecture.md`](architecture/production-architecture.md) · [`architecture/platform-decisions.md`](architecture/platform-decisions.md)

**Archive** — removed or superseded: [`archive/`](archive/README.md)

## Addresses
LAN IPs, NodePorts and hostnames: the **Addresses** table in the [README](../README.md).

## If you are new to the tools
`ansible/LEARN.md` teaches Ansible on this repo; `platform/secrets-architecture.md` teaches the SOPS/KSOPS
chain; `platform/argocd.md` explains why sync is manual and what "insecure mode" is.
