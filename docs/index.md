# Start here — how the whole thing works

A personal homelab: two Proxmox hosts → a two-node **k3s** cluster built by **Ansible** → every app deployed
from this repo by **Argo CD**. Photos (Immich), manga and books (Kavita, Suwayomi, Calibre-Web),
torrents behind a VPN (qBittorrent + Gluetun → Mullvad), search (SearXNG, degoog), bookmarks with archived
copies (Karakeep), budgeting (Actual), portfolio tracking (Wealthfolio), and the glue (cert-manager, Gatus, Bark, Homepage, and Grafana with Prometheus + Loki).

New here? Learn the workflow hands-on first: **[`learn/onboarding-an-app.md`](learn/onboarding-an-app.md)**.

This page is the mental model. Each section ends with where to read more.

---

## 1. The layers, and who owns each one

```
┌─ Hardware ──────────────────────────────────────────────────────────────────────────────┐
│ Proxmox pve-a (.96) + pve-b (.89)                                                       │
│   ├─ VM  k3s-master-01 192.168.68.63      ├─ LXC file server  .50   NFS /data (photos, manga, books, ROMs)
│   ├─ VM  k3s-worker-01 192.168.68.62 (32GB — Immich, Suwayomi, qBittorrent pinned here)      │
│   ├─ LXC Postgres   .7   (old DBs, backups only)   ├─ LXC Valkey/Redis .103 (Immich, degoog)
└──────────────────────────────────────────────────────────────────────────────────────────┘
          │  Ansible (ansible/)  — Tailscale, k3s, nfs-common, the few out-of-git secrets/labels
          ▼
┌─ Cluster (k3s) ─────────────────────────────────────────────────────────────────────────┐
│  Traefik (ingress, bundled)   cert-manager (Let's Encrypt via Cloudflare DNS-01)        │
│  Argo CD  ◄── kubernetes/bootstrap/   (applied by hand, twice, ever)                     │
│     └─ ApplicationSet ──► one Application per  kubernetes/apps/<namespace>/<app>/        │
│           media: immich · immich-prereqs · immich-public-proxy · kavita · calibre · suwayomi · qbittorrent
│           apps: searxng · degoog · homepage · karakeep · actual · wealthfolio
│           monitoring: gatus · bark · kube-prometheus-stack · loki · alloy
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
   Cloudflare DNS: <app>.williampring.ca → A → master's Tailscale 100.x IP     │  http://192.168.68.62:<NodePort>
                              │  (grey cloud / DNS-only: not public)           │
                              ▼                                                ▼
                   Traefik :443 (TLS from cert-manager)  ──────────────►  Service  ──►  Pod
                                                                  (NodePort = same Service, other door)
   OUT through a VPN: only qBittorrent's torrent traffic → Gluetun → Mullvad   (apps/qbittorrent.md)
   INTERNET (strangers):  public-immich.williampring.ca → Cloudflare → Immich Public Proxy → Immich
                          deploy.williampring.ca        → Cloudflare tunnel → NPMplus → Argo CD's NodePort
                          bark.williampring.ca          → Cloudflare tunnel → NPMplus → Bark's NodePort
```
- One Ingress per app, annotated `cert-manager.io/cluster-issuer: letsencrypt`; cert-manager proves domain
  ownership with a Cloudflare TXT record (DNS-01) so certs issue even for hostnames that aren't public.
- NodePorts (30xxx, table in the README) exist for LAN devices that can't run Tailscale.
- Argo CD and Bark are the exceptions: no Ingress — NPMplus fronts their NodePorts, with its own certificate.
→ `platform/tls.md`, the README **Addresses** table

## 5. Where data lives (and what is precious)

| Kind | Where | Precious? | Backed up? |
|---|---|---|---|
| photos, manga, books, ROMs, saves, downloads | NFS `192.168.68.50:/data/...` | **yes** | ⚠️ not automated yet |
| budget files (Actual), bookmarks + archived pages (Karakeep) | NFS `192.168.68.50:/data/{actual,karakeep}` | **yes** | ⚠️ not automated yet |
| Immich database | in-cluster Postgres (VectorChord image), **local-path** PVC on the worker | **yes** | ⚠️ not automated yet |
| Kavita/Calibre/Suwayomi/qBittorrent/Gatus/Bark state, Karakeep's search index, metrics (Prometheus) + logs (Loki) | local-path PVCs | rebuildable (rescan/re-index) or cheap to lose | no, by design |
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
A value is either `ENC[...]` in git or not in git. Today, while testing: one template is a placeholder
(qbittorrent), and Suwayomi's login and the Bark
device key (placeholders) are inline. The checks WARN until `STRICT_SECRETS=1` — the full list is the known-debt
section of `platform/secrets.md`.
→ `platform/secrets.md` (day-to-day), `platform/secrets-architecture.md` (deep dive)

## 7. Notifications

Three senders, three meanings: **Argo** ("you did something": update waiting / deployed / failed),
**Gatus** ("something broke": a probe failed 3× in a row / recovered) and **Alertmanager** ("a pod is
misbehaving": crash-looping, OOMKilled, not Ready, a disk filling up). All go to **Bark** (iOS push through
Apple — works even with Tailscale asleep). It is the only alert channel; ntfy was retired.
→ `apps/bark.md`, `apps/gatus.md`, `apps/grafana.md`, `platform/updates-and-notifications.md`

## 8. Adding, changing, removing an app

- **Add**: a directory under `kubernetes/apps/<namespace>/` with the standard files → push → it appears in Argo.
  Full checklist with a copyable template: **`platform/adding-an-app.md`**. First time? Do the guided lab in
  **`learn/onboarding-an-app.md`** — it walks a throwaway app through every layer and back out.
- **Change**: edit the manifest → push → Sync.
- **Remove**: delete the directory → push → the Application disappears; its resources stay until you delete
  them (`runbooks/cluster-cleanup.md`).

## 9. Known gaps (so you don't think they're solved)

1. **Backups** — nothing automated for NFS data or the Immich database.
2. **Secrets strict mode** — parked while testing (§6).
3. **The Immich Ingress** still lives in Ansible's `tls_ingress` role (last non-Argo object).
4. **Bark is the only channel** — if Bark itself is down, nothing can page you. Watch the Gatus dashboard.
5. **Argo CD is reachable from the internet** (`deploy.williampring.ca`) with only its own login in front of it.
   A Cloudflare Access policy on that hostname (free; email code or GitHub login) would put a second door first.
6. **k3s isn't pinned** — Ansible installs the `stable` channel (`ansible/group_vars/all.yml`), so a rebuild or a
   new node gets whatever version is current that day.

---

## Docs by purpose

**Learn** — understand it by doing it
- [`learn/onboarding-an-app.md`](learn/onboarding-an-app.md) — **onboard a throwaway app through every layer, then remove it** (start here)
- [`../ansible/LEARN.md`](../ansible/LEARN.md) — Ansible, with this repo as the textbook
- [`architecture/production-architecture.md`](architecture/production-architecture.md) — how this compares to production, and the roadmap of what to learn next

**Apps** — one guide per app: setup, how it fits, troubleshooting
- [`apps/immich.md`](apps/immich.md) · [`apps/kavita.md`](apps/kavita.md) · [`apps/suwayomi.md`](apps/suwayomi.md) · [`apps/kindle.md`](apps/kindle.md)
- [`apps/qbittorrent.md`](apps/qbittorrent.md) · [`apps/searxng.md`](apps/searxng.md) · [`apps/degoog.md`](apps/degoog.md)
- [`apps/karakeep.md`](apps/karakeep.md) · [`apps/actual.md`](apps/actual.md) · [`apps/wealthfolio.md`](apps/wealthfolio.md) · [`apps/homepage.md`](apps/homepage.md)
- [`apps/gatus.md`](apps/gatus.md) · [`apps/bark.md`](apps/bark.md) · [`apps/grafana.md`](apps/grafana.md) (Prometheus, Loki, Alloy, Alertmanager)

**Platform** — the things apps rely on
- [`platform/argocd.md`](platform/argocd.md) — Argo CD: install, how it renders, the ApplicationSet, gotchas
- [`platform/adding-an-app.md`](platform/adding-an-app.md) — **onboarding a new app, step by step**
- [`platform/tls.md`](platform/tls.md) — cert-manager + Let's Encrypt (Cloudflare DNS-01)
- [`platform/secrets.md`](platform/secrets.md) · [`platform/secrets-architecture.md`](platform/secrets-architecture.md)
- [`platform/openbao.md`](platform/openbao.md) — **replacing SOPS, app by app (Grafana + Wealthfolio done)**: OpenBao on Proxmox + External Secrets Operator, every step explained
- [`platform/updates-and-notifications.md`](platform/updates-and-notifications.md) — Renovate, Argo → phone, Proxmox → phone
- [`platform/ci.md`](platform/ci.md) — the GitHub Actions gate, the conventions check, the PR render-diff
- [`platform/redis.md`](platform/redis.md) — the shared Valkey and per-app ACL users

**Runbooks** — do-this-when
- [`runbooks/rebuild-from-zero.md`](runbooks/rebuild-from-zero.md) — the whole stack from a blank cluster, in order
- [`archive/deploy-ghostfolio.md`](archive/deploy-ghostfolio.md) — **step-by-step walkthrough of an app that needs a DB, secrets and DNS** (Ghostfolio itself was removed; the pattern still holds)
- [`runbooks/cheatsheet.md`](runbooks/cheatsheet.md) · [`runbooks/cluster-cleanup.md`](runbooks/cluster-cleanup.md)
- [`runbooks/proxmox-install.md`](runbooks/proxmox-install.md) · [`runbooks/couchdb-lxc-setup.md`](runbooks/couchdb-lxc-setup.md) · [`runbooks/tailscale-mullvad-exit-node.md`](runbooks/tailscale-mullvad-exit-node.md)

**Architecture** — the original thinking (partly historical): [`architecture/production-architecture.md`](architecture/production-architecture.md) · [`architecture/platform-decisions.md`](architecture/platform-decisions.md)

**Elsewhere**: [`../README.md`](../README.md) (addresses, ports) · [`../CLAUDE.md`](../CLAUDE.md) (conventions) ·
[`../kubernetes/README.md`](../kubernetes/README.md) (the tree) · [`../ansible/README.md`](../ansible/README.md) · [`../ansible/LEARN.md`](../ansible/LEARN.md) · [`archive/`](archive/README.md)
