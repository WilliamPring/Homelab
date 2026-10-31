# Start here — how the whole thing works

A personal homelab: two Proxmox hosts → a two-node **k3s** cluster built by **Ansible** → every app deployed
from this repo by **Argo CD**. Photos (Immich), manga and books (Kavita, Suwayomi, Komf, Calibre-Web), games
(RomM), torrents behind a VPN (qBittorrent + Gluetun → Mullvad), search (SearXNG, degoog), bookmarks with archived
copies (Karakeep), budgeting (Actual), and the glue (cert-manager, Gatus, Bark, Homepage).

This page is the mental model. Each section ends with where to read more.

---

## 1. The layers, and who owns each one

```
┌─ Hardware ──────────────────────────────────────────────────────────────────────────────┐
│ Proxmox pve-a (.96) + pve-b (.89)                                                       │
│   ├─ VM  k3s master  192.168.68.93      ├─ LXC file server  .50   NFS /data (photos, manga, books, ROMs)
│   ├─ VM  k3s worker  192.168.68.63 (32GB — Immich, RomM, Suwayomi, qBittorrent pinned here)│
│   ├─ LXC Postgres   .7   (RomM; was Vaultwarden)   ├─ LXC Valkey/Redis .103 (Immich, degoog, RomM)
└──────────────────────────────────────────────────────────────────────────────────────────┘
          │  Ansible (ansible/)  — Tailscale, k3s, nfs-common, the few out-of-git secrets/labels
          ▼
┌─ Cluster (k3s) ─────────────────────────────────────────────────────────────────────────┐
│  Traefik (ingress, bundled)   cert-manager (Let's Encrypt via Cloudflare DNS-01)        │
│  Argo CD  ◄── kubernetes/bootstrap/   (applied by hand, twice, ever)                     │
│     └─ ApplicationSet ──► one Application per  kubernetes/apps/<namespace>/<app>/        │
│           media: immich · immich-prereqs · immich-public-proxy · kavita · komf · calibre · suwayomi · romm · qbittorrent
│           apps: searxng · degoog · homepage · karakeep · actual
│           monitoring: gatus · bark
│           cert-manager: cert-manager · cert-manager-issuer                               │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

| Layer | Lives in | Who changes it | How |
|---|---|---|---|
| nodes | `ansible/` | you | `ansible-playbook site.yml` |
| Argo CD itself + the ApplicationSet | `kubernetes/bootstrap/` | you, rarely | `kubectl apply -k … -n argocd` / `kubectl apply -f apps.yaml` |
| every app | `kubernetes/apps/<ns>/<app>/` | git push | Argo renders → **you click Sync** |
| versions | everywhere, pinned | Renovate PRs (Mondays) | you merge, then Sync |

**The one rule that explains most decisions:** *nothing merges or deploys by itself.* Renovate opens PRs,
Argo shows diffs, the phone tells you something is waiting — and a human clicks.
→ `platform/argocd.md`, `../ansible/README.md`, `../CLAUDE.md`

---

## 2. The life of a change

```
 you edit a manifest ──push──► GitHub ──► CI: render every app (kustomize+helm), kubeconform, yamllint
                                             │
                                  Argo polls main (~3 min) ──► renders the app ──► compares with the cluster
                                             │                                          │
                                             ▼                                          ▼
                                       "OutOfSync"  ──► Bark: "<app>: update waiting"
                                             │
                             you open Argo → read the diff → Sync ──► kubectl apply (by Argo)
                                             │
                                       pods roll ──► Bark: "<app>: deployed"  (or SYNC FAILED / DEGRADED)
```

- **Rendering** happens in Argo's *repo-server*: `kustomize build --enable-alpha-plugins --enable-helm`.
  That one command handles raw manifests, `helmCharts:` (immich, cert-manager) and the KSOPS
  generator that decrypts secrets. The same command is what `scripts/ci/validate.sh` runs locally.
- **"Hard Refresh"** in Argo re-renders ignoring its cache — needed after fixing a render error.
- **Argo's own config** (`bootstrap/argocd/`) is NOT synced by Argo. Change it → re-apply by hand.
→ `platform/argocd.md`, `platform/updates-and-notifications.md`, `scripts/ci/validate.sh`

## 3. The life of an upgrade

```
upstream releases vX.Y.Z ──► Renovate (Mon 9am; security any day; releases ≥3 days old)
   ──► PR: bumps the pinned image tag / chart version / tool version
          · stateless apps' patch bumps grouped into ONE PR     · db-migration apps labelled ⚠️
          · cert-manager one minor at a time                    · Argo CD = one URL tag
   ──► you read the changelog, merge ──► Argo OutOfSync ──► phone ──► Sync
```
Pins are what make this work: a `:latest` image or a `"*"` chart is invisible to Renovate.
→ `platform/updates-and-notifications.md`, `../renovate.json`

---

## 4. How a request reaches an app

```
                     phone/laptop ON TAILSCALE                        same-LAN device (Kindle, TV)
                              │                                                │
   Cloudflare DNS: <app>.williampring.ca → A → master's Tailscale 100.x IP     │  http://192.168.68.63:<NodePort>
                              │  (grey cloud / DNS-only: not public)           │
                              ▼                                                ▼
                   Traefik :443 (TLS from cert-manager)  ──────────────►  Service  ──►  Pod
                                                                  (NodePort = same Service, other door)
   OUT through a VPN: only qBittorrent's torrent traffic → Gluetun → Mullvad   (apps/qbittorrent.md)
   INTERNET (strangers): only  share.williampring.ca  → Cloudflare → Immich Public Proxy → Immich
```
- One Ingress per app, annotated `cert-manager.io/cluster-issuer: letsencrypt`; cert-manager proves domain
  ownership with a Cloudflare TXT record (DNS-01) so certs issue even though nothing is public.
- NodePorts (30xxx, table in the README) exist for LAN devices that can't run Tailscale.
- Bark is the exception: no Ingress, NPMplus fronts its NodePort.
→ `platform/tls.md`, the README **Addresses** table

## 5. Where data lives (and what is precious)

| Kind | Where | Precious? | Backed up? |
|---|---|---|---|
| photos, manga, books, ROMs, saves, downloads | NFS `192.168.68.50:/data/...` | **yes** | ⚠️ not automated yet |
| budget files (Actual), bookmarks + archived pages (Karakeep) | NFS `192.168.68.50:/data/{actual,karakeep}` | **yes** | ⚠️ not automated yet |
| Immich database | in-cluster Postgres (VectorChord image), **local-path** PVC on the worker | **yes** | ⚠️ not automated yet |
| RomM database | external Postgres LXC `.7` | yes | ⚠️ |
| Kavita/Komf/Calibre/Suwayomi/qBittorrent/Gatus/Bark state, Karakeep's search index | local-path PVCs | rebuildable (rescan/re-index) or cheap to lose | no, by design |
| Redis/Valkey data | external LXC `.103` | cache | no |

Rule of thumb in every `storage.yaml`: **NFS for anything you'd cry about, local-path for anything a rescan rebuilds.**
Backups are the biggest open item (see §9).
→ each app's doc has a *Storage* / *Backups* section

## 6. Secrets

```
you (age private key on the Arch box)  ──sops -e──►  <app>-secret.enc.yaml  (values are ENC[...], safe in git)
                                                              │
                                   Argo repo-server + KSOPS + the same age key (Secret `sops-age`)
                                                              ▼
                                                   a real Kubernetes Secret → the pod
```
A value is either `ENC[...]` in git or not in git. Today, while testing, two templates are placeholders and
Suwayomi's login is inline; the checks WARN until `STRICT_SECRETS=1`.
→ `platform/secrets.md` (day-to-day), `platform/secrets-architecture.md` (deep dive)

## 7. Notifications

Two channels, two meanings: **Argo** ("you did something": update waiting / deployed / failed) and
**Gatus** ("something broke": a probe failed 3× in a row / recovered). Both go to **Bark** (iOS push through
Apple — works even with Tailscale asleep). It is the only alert channel; ntfy was retired.
→ `apps/bark.md`, `apps/gatus.md`, `platform/updates-and-notifications.md`

## 8. Adding, changing, removing an app

- **Add**: a directory under `kubernetes/apps/<namespace>/` with the standard files → push → it appears in Argo.
  Full checklist with a copyable template: **`platform/adding-an-app.md`**.
- **Change**: edit the manifest → push → Sync.
- **Remove**: delete the directory → push → the Application disappears; its resources stay until you delete
  them (`runbooks/cluster-cleanup.md`).

## 9. Known gaps (so you don't think they're solved)

1. **Backups** — nothing automated for NFS data or the Immich database.
2. **Secrets strict mode** — parked while testing (§6).
3. **The Immich Ingress** still lives in Ansible's `tls_ingress` role (last non-Argo object).
4. **Bark is the only channel** — if Bark itself is down, nothing can page you. Watch the Gatus dashboard.

---

## Docs by purpose

**Apps** — one guide per app: setup, how it fits, troubleshooting
- [`apps/immich.md`](apps/immich.md) · [`apps/kavita.md`](apps/kavita.md) · [`apps/suwayomi.md`](apps/suwayomi.md) · [`apps/kindle.md`](apps/kindle.md)
- [`apps/romm.md`](apps/romm.md) · [`apps/qbittorrent.md`](apps/qbittorrent.md) · [`apps/degoog.md`](apps/degoog.md) · [`apps/gatus.md`](apps/gatus.md) · [`apps/bark.md`](apps/bark.md)
- [`apps/karakeep.md`](apps/karakeep.md) · [`apps/actual.md`](apps/actual.md)

**Platform** — the things apps rely on
- [`platform/argocd.md`](platform/argocd.md) — Argo CD: install, how it renders, the ApplicationSet, gotchas
- [`platform/adding-an-app.md`](platform/adding-an-app.md) — **onboarding a new app, step by step**
- [`platform/tls.md`](platform/tls.md) — cert-manager + Let's Encrypt (Cloudflare DNS-01)
- [`platform/secrets.md`](platform/secrets.md) · [`platform/secrets-architecture.md`](platform/secrets-architecture.md)
- [`platform/updates-and-notifications.md`](platform/updates-and-notifications.md) — Renovate, CI guard, Argo → phone
- [`platform/redis.md`](platform/redis.md) — the shared Valkey and per-app ACL users

**Runbooks** — do-this-when
- [`runbooks/rebuild-from-zero.md`](runbooks/rebuild-from-zero.md) — the whole stack from a blank cluster, in order
- [`runbooks/cheatsheet.md`](runbooks/cheatsheet.md) · [`runbooks/cluster-cleanup.md`](runbooks/cluster-cleanup.md)
- [`runbooks/proxmox-install.md`](runbooks/proxmox-install.md) · [`runbooks/couchdb-lxc-setup.md`](runbooks/couchdb-lxc-setup.md) · [`runbooks/tailscale-mullvad-exit-node.md`](runbooks/tailscale-mullvad-exit-node.md)

**Architecture** — the original thinking (partly historical): [`architecture/production-architecture.md`](architecture/production-architecture.md) · [`architecture/platform-decisions.md`](architecture/platform-decisions.md)

**Elsewhere**: [`../README.md`](../README.md) (addresses, ports) · [`../CLAUDE.md`](../CLAUDE.md) (conventions) ·
[`../kubernetes/README.md`](../kubernetes/README.md) (the tree) · [`../ansible/README.md`](../ansible/README.md) · [`../ansible/LEARN.md`](../ansible/LEARN.md) · [`archive/`](archive/README.md)
