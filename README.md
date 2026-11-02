# Homelab

A self-hosted **k3s** cluster running on **Proxmox**, provisioned with **Ansible** (infra)
and deployed with **Argo CD / GitOps** (apps). A learning-focused homelab that actually runs
real services — photo backup, books and manga, a budget, bookmarks and private search — behind
Tailscale with real HTTPS.

```
Ansible  →  builds the cluster + infrastructure   (you run the playbook)
Argo CD  →  deploys the apps from this git repo    (declarative; shows the diff, you click Sync)
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

| Namespace | App | What | Hostname (`*.williampring.ca`) |
|---|---|---|---|
| `media` | **Immich** + Immich Public Proxy | photo/video backup with iPhone sync; public share links | `immich` · `public-immich` |
| | **Kavita** + **Komf** | manga, comics and ebooks; Komf fills in the metadata | `library` · `komf` |
| | **Calibre-Web-Automated** | ebook library, auto-import, send to Kindle | `books` |
| | **Suwayomi** | manga sources and downloads | `suwayomi` |
| | **RomM** | ROM library, play in the browser | `roms` |
| | **qBittorrent** + Gluetun | torrents, through Mullvad | `qbittorrent` |
| `apps` | **SearXNG** · **degoog** | private metasearch · search aggregator | `private` · `search` |
| | **Karakeep** | bookmarks with archived copies | `karakeep` |
| | **Actual** | envelope budgeting | `actual` |
| | **Ghostfolio** | portfolio tracking | `portfolio` |
| | **Homepage** | the dashboard | `home` |
| `monitoring` | **Gatus** · **Bark** | uptime checks · iOS push alerts | `status` · `bark` |
| `cert-manager` | **cert-manager** | Let's Encrypt certificates (Cloudflare DNS-01) | — |

Everything is reachable over **Tailscale** with **Let's Encrypt** certs (issued via Cloudflare DNS-01, so
nothing has to be public). The deliberate exceptions reach the internet: `public-immich` (Immich share links), and
`deploy` (Argo CD) + `bark` through a Cloudflare tunnel → NPMplus. One guide per app in `docs/apps/`.

## Repo layout

```
ansible/          Infrastructure as code — the "make the cluster exist" layer
  site.yml          Tailscale → k3s → Immich infra (secret + node label) → the last Ansible-owned Ingress (Immich)
  roles/            tailscale, k3s_server, k3s_agent, immich (infra only), tls_ingress
  group_vars/       cluster config + feature toggles

kubernetes/       Apps as code — Argo CD watches this
  bootstrap/        Argo CD's own install + the ApplicationSet (applied by hand)
  apps/<ns>/<app>/  one directory per app = one Argo Application (kustomize; Helm charts via helmCharts:)
  templates/app/    the copyable skeleton for a new app
  README.md         the tree + which apps live in which namespace

docs/             Start at docs/index.md — apps/, platform/, runbooks/, learn/, architecture/
scripts/          ci/ (validate, conventions, render-diff), secrets.sh (the SOPS helper), LXC setup scripts
```

## How it works

**Infrastructure (Ansible)** — from an Arch control node:
```bash
cd ansible
ansible-playbook site.yml --ask-become-pass
```
Installs Tailscale + k3s on the nodes, the one Ingress not yet in GitOps (Immich), and the
out-of-git secrets/labels the apps rely on. Ansible's job ends at "a working cluster."

**Apps (Argo CD)** — deployed from git, not the playbook:
```bash
# one-time: install Argo CD + the ApplicationSet (docs/runbooks/rebuild-from-zero.md)
git push   # the ApplicationSet (kubernetes/bootstrap/apps.yaml) registers any new app directory
# thereafter: edit a manifest → git push → Argo shows OutOfSync → you review the diff and click Sync
```
New to it? Onboard a throwaway app with the guided lab: [`docs/learn/onboarding-an-app.md`](docs/learn/onboarding-an-app.md).

## Addresses (LAN)

| What | IP | Notes |
|---|---|---|
| k3s master — `k3s-master-01` | `192.168.68.63` | Argo/Traefik entry; any NodePort also answers here |
| k3s worker (32GB) — `k3s-worker-01` | `192.168.68.62` | Immich, RomM, Suwayomi, qBittorrent are pinned here |
| file server (NFS `/data`) | `192.168.68.50` | photos, manga, books, ROMs, downloads |
| Postgres LXC | `192.168.68.7` | RomM, Ghostfolio (and formerly Vaultwarden) |
| Valkey / Redis | `192.168.68.103` | Immich, degoog, RomM (Ghostfolio runs its own — see its doc) |

LAN NodePorts (plain http, same WiFi — e.g. for the Kindle): Kavita `:30500` · Calibre-Web `:30083` ·
Suwayomi `:30456` · RomM `:30808` · Immich `:30041` · Immich share proxy `:30042` · SearXNG `:30880` · Gatus `:30881` · degoog `:30882` · Bark `:30889` (fronted by NPMplus) · qBittorrent `:30080` · Karakeep `:30300` · Actual `:30506` · Argo CD `:30443`. Hostnames (`*.williampring.ca`) resolve to the
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
- **Secrets live in git only as ciphertext.** SOPS + age encrypts the values; KSOPS decrypts them inside
  Argo. The few bootstrap secrets (the age key, `immich-db`, the Cloudflare token) are created by hand.
- **Stateful data stays out of the cluster.** NFS and the Postgres/Valkey LXCs survive a cluster rebuild.
- **Manual sync by default.** Argo shows drift but waits for a click — no surprise upgrades.

## Docs

Start at **[`docs/index.md`](docs/index.md)**. Grouped by purpose:

- `docs/learn/` — **[onboard an app: a guided lab](docs/learn/onboarding-an-app.md)** (start here to learn the workflow)
- `docs/apps/` — one guide per app (Immich, Kavita + Komf + Calibre, Suwayomi, Kindle, RomM, qBittorrent + Gluetun, Karakeep, Actual, Ghostfolio, SearXNG, degoog, Homepage, Gatus, Bark)
- `docs/platform/` — **adding an app (onboarding checklist)**, Argo CD, TLS/cert-manager, secrets (day-to-day + deep dive), updates & notifications, CI, Valkey
- `docs/runbooks/` — **rebuild from zero**, deploying Ghostfolio (a full worked example), cheatsheet, cluster cleanup, Proxmox install, LXC how-tos
- `docs/architecture/` — the plan docs (partly historical) and the learning roadmap
- `docs/archive/` — removed/superseded setups
- [`ansible/README.md`](ansible/README.md) / [`ansible/LEARN.md`](ansible/LEARN.md) — node provisioning + the Ansible teaching guide
- [`kubernetes/README.md`](kubernetes/README.md) — the app tree and how to add an app · [`CLAUDE.md`](CLAUDE.md) — conventions

---

*A personal learning project — built to understand k3s, GitOps, and self-hosting hands-on.*
