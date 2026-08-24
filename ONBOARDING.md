# START HERE — How to Read This Project

New here (or future-you coming back cold)? This is the map. It tells you **where to look
to understand what's going on**, in what order to read, and the conventions that make the
patterns click.

---

## What this project is (30 seconds)
An **Ansible-automated k3s homelab**. You run **one command** from your laptop and it:
1. SSHes into the machines and installs **Tailscale + k3s**,
2. deploys your **apps** as containers,
3. sets up **file sharing** and (optionally) **HTTPS ingress**.

Everything is **code** — the repo *is* the homelab.

## The 30-second mental model
```
YOUR LAPTOP (Ansible)  ──SSH──►  MACHINES (Debian: Tailscale + k3s)  ──runs──►  APPS (k3s pods)
   Layer 3                          Layer 1                                       Layer 2
```
Ansible manages the machines (Layer 1). k3s runs the apps (Layer 2). Your laptop drives it (Layer 3).

---

## 🗺️ Where to look for X  (the map)

| I want to understand… | Open this file |
|-----------------------|----------------|
| **Which machines/nodes exist** | `ansible/inventory.ini` |
| **What runs, and in what order** | `ansible/site.yml` ← the playbook (7 "plays", top to bottom) |
| **The on/off switches + settings** | `ansible/group_vars/all.yml` (toggles like `immich_enabled`) |
| **Which apps are deployed via Helm** | `ansible/vars/helm_releases.yml` (a data list) |
| **Which apps get HTTPS hostnames** | `ansible/vars/routes.yml` |
| **How a *Helm* app is configured** | `ansible/helm-values/<app>.yaml` |
| **How a *manifest* app is configured** | `ansible/roles/<app>/files/<app>.yaml` |
| **What a role actually does (steps)** | `ansible/roles/<app>/tasks/main.yml` |
| **How to run the whole thing** | `ansible/README.md` |
| **Ansible concepts (learning)** | `ansible/LEARN.md` |
| **The overall plan / what's next** | `docs/roadmap.md` |
| **How networking / TLS / ingress works** | `docs/gateway-api-plan.md` |
| **How a pro/prod setup would differ** | `docs/production-architecture.md` |
| **Useful commands (kubectl, ansible…)** | `docs/cheatsheet.md` |
| **Should we use Proxmox? (parked decision)** | `docs/proxmox-consideration.md` |

---

## 📖 Read it in this order (first time)
1. **`ansible/inventory.ini`** — *what are the machines?*
2. **`ansible/site.yml`** — *what happens when I run it?* (skim the play names top to bottom)
3. **`ansible/group_vars/all.yml`** — *what's turned on, what are the settings?*
4. Pick one app and follow it end-to-end:
   - a **manifest** app → `roles/pihole/tasks/main.yml` + `roles/pihole/files/pihole.yaml`
   - a **Helm** app → `vars/helm_releases.yml` (the entry) + `helm-values/jellyfin.yaml` (its config)
5. **`docs/roadmap.md`** — *where is this all going?*

---

## 🔎 To trace "what happens when I run `ansible-playbook site.yml`"
Read **`site.yml`** top to bottom. It's 7 plays, each = "run these roles on these machines":
```
Play 1  Tailscale     → all nodes
Play 2  k3s server    → master
Play 3  k3s agents    → workers
Play 4  manifest apps → Pi-hole, qBittorrent, Immich-prereqs
Play 5  Helm apps     → Jellyfin, Vaultwarden, Immich   (loops over vars/helm_releases.yml)
Play 6  Samba         → the host file share
Play 7  TLS ingress   → cert-manager + Gateway API + HTTPRoutes
```
A play names its **roles**; each role's steps live in `roles/<name>/tasks/main.yml`.

---

## 🧩 The conventions (so the patterns make sense)
- **Each app = a role** in `roles/`.
- **Small app** → hand-written manifest in `roles/<app>/files/*.yaml`, applied with `kubectl apply`.
- **Charted app** → a Helm chart: an entry in `vars/helm_releases.yml` + a `helm-values/<app>.yaml`.
  Adding one = a data line + a values file, **no playbook edits**.
- **Toggles** in `group_vars/all.yml` turn features on/off (`<thing>_enabled: true/false`).
  Many heavy things are **staged OFF**, waiting for real hardware (the HP).
- **Namespaces group apps by function**: `media`, `apps`, `network`, `vpn`, `gateway`, `kube-system`.
- **Config lives in data, not the playbook**: machines→`inventory.ini`, settings→`group_vars`,
  Helm apps→`vars/helm_releases.yml`, routes→`vars/routes.yml`, per-app config→`helm-values/`.

---

## ✅ Status at a glance (see `docs/roadmap.md` for detail)
- **Running:** k3s, Pi-hole, Jellyfin, Vaultwarden, Samba
- **Staged (off, waiting for the HP):** Immich, qBittorrent, cert-manager + Gateway API (TLS)
- **Planned / parked:** Seafile, monitoring, backups, storage roles, Proxmox

---

## The one-line summary
**`site.yml` is the table of contents; `roles/` is the how; `vars/` + `helm-values/` + `group_vars/`
are the what; `docs/` is the why.** Start at `site.yml`, follow a role, read a doc.
