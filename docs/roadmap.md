# Homelab Self-Hosting Roadmap

The plan for what we're building, in what order, and why. This is a living planning
doc — nothing here is built until a phase is approved. Companion to the Ansible
setup (`ansible/`) and the cluster docs (`docs/architecture.md`).

> Rule for building: **one phase per session, approve each before starting.**
> Go slow — the point is to learn each concept, not to rush to a finished stack.

---

## Hardware & topology

| Node | Spec | Arch | Role |
|------|------|------|------|
| **HP 800 G5 Mini** | i5-9500T (6c), 16 GB RAM, real SSD, Intel UHD 630 (QuickSync) | amd64 | **Workhorse** — control plane + heavy apps + the data disk |
| **3× Rock 4B+** | 4c, **2 GB RAM**, **32 GB SD** each | arm64 | **Light workers** — small, mostly-stateless, always-on services |

This is a **mixed-architecture** cluster (amd64 master + arm64 workers). k3s handles
it; we use multi-arch images (all our picks publish them) and pin arch/weight-sensitive
apps to the HP.

**The core rule:** heavy + stateful + database + storage → **HP**. Light + stateless
→ **Rocks**. **Never** put databases or heavy writes on the Rock SD cards (slow, wear out).

---

## Architecture principles

### Three layers (only the middle one lives in k3s)
```
Layer 3 — CLIENT / SaaS   → your Arch laptop & Cloudflare      (NOT in k3s)
            k9s, kubectl, helm  |  Cloudflare Access policies
Layer 2 — WORKLOADS       → the apps                            (IN k3s)
            Immich, Jellyfin, Kavita, Vaultwarden, …
Layer 1 — HOST / CLUSTER  → node OS + k3s itself                (BELOW k3s, via Ansible)
            unattended-upgrades, smartmontools, etcd snapshots
```
- **Ansible** owns Layer 1 (the machines). **k3s** owns Layer 2 (the workloads).
  Later, **Argo CD** could own *how* Layer 2 is deployed (GitOps).

### Two access planes
- **Private (Tailscale):** you reach *everything* over the tailnet. Default.
- **Public (Cloudflare Tunnel):** only a *few* chosen services, gated by **Cloudflare
  Access**. Outbound-only tunnel — no open ports, no home IP exposed.
- **Default-deny:** a service is Tailscale-only unless there's a real reason to publish
  it, and if published it's behind Access unless meant to be truly open.

### Storage
- Bulk/stateful data lives on the **HP's SSD** via `local-path`, with stateful pods
  **pinned to the HP** (`nodeSelector`). This keeps storage simple — no NFS/Longhorn
  needed to start. Disk size (not RAM) is the long-term ceiling as photos/media grow.

### Namespaces — group by FUNCTION (decided)
Namespaces are organized by *function*, matching the existing `vpn`/`media`/`monitoring`
convention, the subdomain scheme, and the wildcard-cert domains — a clean 1:1:1:
**namespace = subdomain function = wildcard cert**.

Why not one-namespace-per-app: Traefik requires the TLS Secret in the **same namespace**
as the IngressRoute (see `debugging-runbook.md`), and certs are wildcard-per-function
(`*.media`, `*.monitoring`). Grouping means one wildcard cert per namespace serves all
its apps — per-app namespaces would force replicating that cert everywhere.

| Namespace | Wildcard cert | Holds |
|-----------|---------------|-------|
| `media` | `*.media` | Jellyfin, Jellyseerr, Kavita, Calibre-Web, Audiobookshelf, Immich |
| `vpn` | (reuses media) | qBittorrent, *arr — **only apps that must egress via Mullvad** |
| `monitoring` | `*.monitoring` | Uptime Kuma, Beszel |
| `network` | `*.net` / none | Pi-hole, cloudflared (Pi-hole leaves k3s later) |
| `apps` | `*.apps` | Vaultwarden, Paperless, FreshRSS, Wallabag, Gitea, code-server |
| `kube-system` | — | Traefik, cert-manager |

- **`vpn` ≠ generic media** — it's specifically for Mullvad-routed apps. **Jellyfin goes in
  `media`, NOT `vpn`** (a media server through a VPN would be slow and pointless).
- **Trade-off:** can't nuke an app via `delete ns`. Mitigate by labeling every resource
  `app: <name>` → `kubectl delete all -l app=jellyfin -n media`.
- **Pi-hole** currently sits in its own `pihole` namespace (inconsistent). It's migrating
  out of k3s to standalone-on-worker anyway, so we leave it until that migration.

---

## Service catalog (resource + difficulty + placement)

**RAM:** 🟢 <150 MB · 🟡 150–500 MB · 🟠 0.5–1.5 GB · 🔴 1.5 GB+
**Setup:** ⭐ easy · ⭐⭐ medium (config/DB) · ⭐⭐⭐ hard (multi-container/DB/secrets)

| Tool | Purpose | RAM | Setup | Node |
|------|---------|-----|-------|------|
| Pi-hole ✅ | DNS ad-block | 🟢 | ⭐ | Rock |
| Uptime Kuma | uptime + alerts | 🟢 | ⭐ | Rock |
| ntfy | push to iPhone | 🟢 | ⭐ | Rock |
| Beszel | host metrics | 🟢 | ⭐ | hub Rock, agents all |
| Vaultwarden | passwords | 🟢 | ⭐ | Rock |
| Homepage | dashboard | 🟢 | ⭐⭐ | Rock |
| Kavita | manga + ebooks (iPad) | 🟡 | ⭐ | HP |
| Calibre-Web | ebooks for **Kindle** | 🟡 | ⭐⭐ | HP |
| Jellyseerr | media request UI | 🟡 | ⭐⭐ | Rock/HP |
| FreshRSS | RSS reader | 🟡 | ⭐⭐ | Rock |
| Audiobookshelf | audiobooks/podcasts | 🟡 | ⭐ | HP |
| Jellyfin | media server | 🟡→🟠 | ⭐⭐ | HP (QuickSync) |
| Gitea/Forgejo | git + CI | 🟡→🟠 | ⭐⭐ | HP |
| code-server | VS Code in browser | 🟡→🟠 | ⭐⭐ | HP |
| Paperless-ngx | doc archive + OCR | 🟠 | ⭐⭐⭐ | HP |
| Immich | iPhone photo backup | 🔴 | ⭐⭐⭐ | HP |
| Backups (restic) | back up data | 🟢 idle | ⭐⭐ | HP CronJob |
| cloudflared | public access | 🟢 | ⭐⭐ | Rock/HP |
| Argo CD | GitOps delivery | 🟠 | ⭐⭐⭐ | HP |

**Budget verdict:** HP idles ~6–7 GB with the heavy set → fits 16 GB with headroom.
The risk is *simultaneous* spikes (Jellyfin transcode + Immich ML + Paperless OCR +
Gitea CI). Set resource `limits` so nothing starves the rest.

---

## Reading setup (decided)

You read **manga** and **ebooks**, on an **iPad** and a **Kindle**. Kindle is a walled
garden (no OPDS, no CBZ, bad for manga), so no single server serves both well:

- **Kavita** → manga + ebooks on the **iPad** (Panels app / Safari web reader, OPDS).
- **Calibre-Web** → ebooks for the **Kindle** (built-in *Send to Kindle* + format
  conversion — the workflow Kavita lacks).

Two light apps, same deployment pattern learned twice. *(If the Kindle turns out to be
rare and the iPad is your main reader, drop Calibre-Web and run Kavita alone.)*

---

## iOS client map (all-Apple fleet)

| Service | iOS client |
|---------|-----------|
| Immich | Official app (background auto-backup) |
| Jellyfin | **Infuse** (direct-play — perfect for the HP) / Swiftfin |
| Kavita | **Panels** (manga) / Safari |
| Calibre-Web | Kindle via Send-to-Kindle |
| Vaultwarden | Official Bitwarden app |
| ntfy | Official app |
| Everything else | Safari (web dashboards) |

---

## Current focus — Path A: Vaultwarden + Jellyfin (learn-now)

Chosen approach for the two "install now" picks: **Path A — deploy now, cheaply, to
learn**, on the current VM test cluster, before the HP or the TLS/cert foundation exist.

- **Exposure:** **NodePort** for now (no TLS yet), same style as Pi-hole. Proper
  `IngressRoute` + HTTPS comes later as the "ingress/TLS foundation" step.
- **Vaultwarden** → `apps` namespace, deployed to **learn the pattern**. Data is
  **throwaway** — do NOT store real passwords until backups (Phase 7) + the HP exist.
- **Jellyfin** → `media` namespace. Manifest scaffolded to learn the mechanics, but it's
  an **empty shell** until the HP (QuickSync + media disk) is in place.
- Each app becomes an Ansible role like `pihole` (copy manifest → apply), resources
  labeled `app: <name>`, into its function namespace.

Readiness caveats being accepted knowingly: no HP yet, no cert-manager/wildcard certs on
the test cluster, worker not yet joined. This is deliberate learning scaffolding that
re-deploys cleanly to the real cluster later (it's all IaC).

## Phased build order

### Phase 0 — Foundations & fleet
- Fix the **worker join** (currently broken — unblocks RAM).
- Put a **real SSD in the HP**; set up `local-path` storage; pin stateful apps to HP.
- Node hygiene: **unattended-upgrades** (all), **smartmontools** (HP disk health).
- Install **k9s** on the Arch laptop.
- **Learn:** k8s storage (PV/PVC/StorageClass), node roles, the fleet CLI.

### Phase 1 — Uptime Kuma (+ ntfy)
- First real app: Deployment + PVC + Service + IngressRoute; push alerts to iPhone.
- **Learn:** the full "app on k3s" loop at low stakes; alerting.

### Phase 2 — Beszel
- Hub + agents. Note: k3s is containerd, so the Docker-socket container stats won't
  work — host metrics do; we adjust the existing manifest.
- **Learn:** DaemonSet, hostNetwork.

### Phase 3 — Reading: Kavita + Calibre-Web
- Manga/ebooks (iPad) + Kindle ebook workflow. Read-only library mount + config PVC.
- **Learn:** media mounts, OPDS, Send-to-Kindle; repeat the deploy pattern.

### Phase 4 — Vaultwarden
- Passwords. Sensitive → **Tailscale-only, never public.**
- **Learn:** secrets, keeping sensitive apps private.

### Phase 5 — Jellyfin
- Media server with **QuickSync** hardware transcode (iGPU `/dev/dri` passthrough),
  large media volume, resource limits.
- **Learn:** device passthrough, big volumes, limits.

### Phase 6 — Jellyseerr
- Request front-end wired to Jellyfin + *arr.
- **Learn:** app-to-app integration (depends on Phase 5 + the *arr stack).

### Phase 7 — Backups (restic) — *before Immich*
- CronJob backing up PVCs/config to a second disk/offsite. **Restore-test it.**
- **Learn:** CronJob, restic, backup discipline (photos are irreplaceable).

### Phase 8 — Immich (flagship)
- Server + ML + Postgres + Redis; iPhone auto-backup over Tailscale.
- **Learn:** multi-container app + database + secrets. The hardest phase.

### Phase 9 — Cloudflare Tunnel + Access
- `cloudflared` in-cluster → Traefik; publish a *couple* of services (e.g. Jellyseerr
  for family); gate with one Access policy.
- **Learn:** outbound tunnels, public/private planes, Zero-Trust auth.

### À la carte (any time, one at a time)
Homepage · FreshRSS · Wallabag · Audiobookshelf · Paperless-ngx · Gitea/Forgejo ·
code-server · IT-Tools · a private registry (Zot) · Renovate.

### Phase 10 — Graduation: GitOps (Argo CD)
- Move app *delivery* from "Ansible applies manifests" to "cluster syncs from Git."
- **Learn:** declarative continuous delivery, drift detection, one-click rollback.
- Do this *after* hand-deploying several apps, so GitOps solves a problem you've felt.

---

## Open questions (to finalize the plan)

1. **HP disk:** what SSD/size is going in? Photos + media → hundreds of GB. Determines
   whether local-path-on-SSD is enough or we plan external/NAS storage.
2. **Public exposure:** which services (if any) should be reachable from the internet?
   (Instinct: maybe Jellyseerr/Jellyfin for family + a personal site; everything else
   Tailscale-only.)
3. **GitOps:** commit to Argo CD as the graduation phase? (Recommended.)
4. **Monitoring depth:** stay light (Uptime Kuma + Beszel), or add Prometheus/Grafana
   as a later phase? (Recommended: stay light for now.)
