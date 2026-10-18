# Homelab

A self-hosted **k3s** cluster running on **Proxmox**, provisioned with **Ansible** (infra)
and deployed with **Argo CD / GitOps** (apps). A learning-focused homelab that actually runs
real services — a password manager, photo backup, and privacy search — behind Tailscale with
real HTTPS.

```
Ansible  →  builds the cluster + infrastructure   (you run the playbook)
Argo CD  →  deploys the apps from this git repo    (declarative, self-healing)
```

## Stack

| Layer | Tech |
|---|---|
| Virtualization | Proxmox VE (2 hosts: 32 GB i7 + 16 GB) |
| Cluster | k3s (server + agent VMs) |
| Networking | Tailscale (mesh VPN), LAN `192.168.68.0/24` |
| Ingress / TLS | Traefik (bundled) + cert-manager + Let's Encrypt (Cloudflare DNS-01) |
| GitOps | Argo CD |
| Provisioning | Ansible |
| Data (external to cluster) | Postgres LXC · NFS file-server LXC |

## Apps

| App | What | URL |
|---|---|---|
| **Immich** | Self-hosted photo/video backup (iPhone sync), vector Postgres + NFS library | `immich.williampring.ca` |
| **SearXNG** | Privacy metasearch engine | `private.williampring.ca` |
| **degoog** | Search aggregator (Valkey-backed) | `search.williampring.ca` |

All apps are reachable over **Tailscale** with **Let's Encrypt** certs (issued via Cloudflare
DNS-01, so no public exposure is required).

## Repo layout

```
ansible/          Infrastructure as code — the "make the cluster exist" layer
  site.yml          Tailscale → k3s → infra secrets → the two legacy Ingresses
  roles/            tailscale, k3s_server, k3s_agent, certmanager, tls_ingress, immich(infra)
  group_vars/       cluster config + feature toggles

kubernetes/       Apps as code — Argo CD watches this (bootstrap/ + apps/<namespace>/<app>/)
  apps/             one Argo Application per app (searxng, degoog, immich[-prereqs], kavita, komf, romm, …)
  searxng/          raw manifests (one file per kind)
  degoog/           raw manifests + Valkey + PVCs
  immich/           Helm values + prereqs/ (vector Postgres + NFS library)
  README.md         the GitOps workflow + how to onboard a new app

docs/             Reference guides (Proxmox install, per-app docs, cheatsheet, architecture)
scripts/          Standalone setup scripts (e.g. the Postgres LXC)
```

## How it works

**Infrastructure (Ansible)** — from an Arch control node:
```bash
cd ansible
ansible-playbook site.yml --ask-become-pass
```
Installs Tailscale + k3s on the nodes, the two Ingresses not yet in gitops, and the
out-of-git secrets/labels the apps rely on. Ansible's job ends at "a working cluster."

**Apps (Argo CD)** — deployed from git, not the playbook:
```bash
# one-time: install Argo CD, then register an app
git push   # the ApplicationSet (kubernetes/bootstrap/apps.yaml) registers the new directory as an app
# thereafter: edit a manifest → git push → Argo syncs it
```
See [`kubernetes/README.md`](kubernetes/README.md) for the full workflow.

## Addresses (LAN)

| What | IP | Notes |
|---|---|---|
| k3s master | `192.168.68.93` | Argo/Traefik entry; any NodePort also answers here |
| k3s worker (32GB) | `192.168.68.63` | Immich, RomM, Suwayomi are pinned here |
| file server (NFS `/data`) | `192.168.68.50` | photos, manga, books, ROMs |
| Postgres LXC | `192.168.68.7` | RomM (and formerly Vaultwarden) |
| Valkey / Redis | `192.168.68.103` | Immich, degoog, RomM |

LAN NodePorts (plain http, same WiFi — e.g. for the Kindle): Kavita `:30500` · Calibre-Web `:30083` ·
Suwayomi `:30456` · RomM `:30808` · Immich `:30041` · Immich share proxy `:30042` · SearXNG `:30880` · Gatus `:30881` · degoog `:30882` · Bark `:30889` (fronted by NPMplus). Hostnames (`*.williampring.ca`) resolve to the
master's **Tailscale** IP and need Tailscale on the device.

## Working in this repo
```bash
make            # list commands
make lint       # yamllint
make validate   # render every app + kubeconform (what CI runs)
make hooks      # install pre-commit (cheap checks on commit, full validate on push)
```
Conventions for humans and AI tools: [`CLAUDE.md`](CLAUDE.md). Editor settings: `.editorconfig`.

## Design principles

- **One owner per thing.** Infra lives in Ansible; apps live in GitOps. Nothing is deployed twice.
- **Secrets + stateful data stay out of git.** DB passwords are k8s Secrets (hand-managed);
  the databases themselves run in LXCs and survive cluster rebuilds.
- **Manual sync by default.** Argo shows drift but waits for a click — no surprise upgrades.

## Docs

Start at **[`docs/index.md`](docs/index.md)**. Grouped by purpose:

- `docs/apps/` — one guide per app (Immich, Kavita + Komf + Calibre, Suwayomi, Kindle, RomM, degoog, Gatus)
- `docs/platform/` — **adding an app (onboarding checklist)**, Argo CD, TLS/cert-manager, secrets (day-to-day + deep dive), updates & notifications, Valkey
- `docs/runbooks/` — **rebuild from zero**, cheatsheet, cluster cleanup, Proxmox install, LXC how-tos
- `docs/architecture/` — the plan docs (partly historical)
- `docs/archive/` — removed/superseded setups
- [`ansible/README.md`](ansible/README.md) / [`ansible/LEARN.md`](ansible/LEARN.md) — node provisioning + the Ansible teaching guide
- [`kubernetes/README.md`](kubernetes/README.md) — the app tree and how to add an app · [`CLAUDE.md`](CLAUDE.md) — conventions

---

*A personal learning project — built to understand k3s, GitOps, and self-hosting hands-on.*
