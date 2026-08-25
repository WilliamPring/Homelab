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
| **Vaultwarden** | Password manager (Bitwarden-compatible), data in external Postgres | `vault.williampring.ca` |
| **Immich** | Self-hosted photo/video backup (iPhone sync), vector Postgres + NFS library | `immich.williampring.ca` |
| **SearXNG** | Privacy metasearch engine | `private.williampring.ca` |
| **degoog** | Search aggregator (Valkey-backed) | `search.williampring.ca` |

All apps are reachable over **Tailscale** with **Let's Encrypt** certs (issued via Cloudflare
DNS-01, so no public exposure is required).

## Repo layout

```
ansible/          Infrastructure as code — the "make the cluster exist" layer
  site.yml          Tailscale → k3s → infra secrets → cert-manager/TLS
  roles/            tailscale, k3s_server, k3s_agent, certmanager, tls_ingress, immich(infra)
  group_vars/       cluster config + feature toggles

gitops/           Apps as code — Argo CD watches this
  apps/             one Argo Application per app (searxng, degoog, vaultwarden, immich[-prereqs])
  searxng/          raw manifests (one file per kind)
  degoog/           raw manifests + Valkey + PVCs
  vaultwarden/      Helm values (chart pulled from the guerzon repo)
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
Installs Tailscale + k3s on the nodes, cert-manager + the Let's Encrypt ClusterIssuer, and the
out-of-git secrets/labels the apps rely on. Ansible's job ends at "a working cluster."

**Apps (Argo CD)** — deployed from git, not the playbook:
```bash
# one-time: install Argo CD, then register an app
kubectl apply -f gitops/apps/<app>.yaml
# thereafter: edit a manifest → git push → Argo syncs it
```
See [`gitops/README.md`](gitops/README.md) for the full workflow.

## Design principles

- **One owner per thing.** Infra lives in Ansible; apps live in GitOps. Nothing is deployed twice.
- **Secrets + stateful data stay out of git.** DB passwords are k8s Secrets (hand-managed);
  the databases themselves run in LXCs and survive cluster rebuilds.
- **Manual sync by default.** Argo shows drift but waits for a click — no surprise upgrades.

## Docs

- [`docs/proxmox-install.md`](docs/proxmox-install.md) — Proxmox VE install walkthrough
- [`docs/argocd.md`](docs/argocd.md) — Argo CD / GitOps (install, expose, login)
- [`docs/vaultwarden.md`](docs/vaultwarden.md) · [`docs/immich.md`](docs/immich.md) · [`docs/degoog.md`](docs/degoog.md) — per-app guides
- [`docs/logging.md`](docs/logging.md) — Loki + Alloy + Grafana logging stack
- [`docs/sops-argocd.md`](docs/sops-argocd.md) — encrypt secrets into git (SOPS + age + KSOPS)
- [`docs/cheatsheet.md`](docs/cheatsheet.md) — everyday kubectl / Ansible commands
- [`ansible/LEARN.md`](ansible/LEARN.md) — Ansible concepts, learning notes

---

*A personal learning project — built to understand k3s, GitOps, and self-hosting hands-on.*
