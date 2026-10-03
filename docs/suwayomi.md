# Suwayomi + Paperback — browse, subscribe, read and download manga (phone + computer)

**Suwayomi** runs the Mihon/Tachiyomi extension catalogue on your server: hundreds of online
sources, a library you "subscribe" series into, update checks, server-side downloads.
**Paperback** on the iPhone connects to that same server, so phone and computer share one
library. Everything Suwayomi downloads lands in Kavita's manga folder, so it is also in Kavita
(with Komf metadata) and readable offline through either app.

```
                    iPhone: Paperback  (Suwayomi extension)        computer: https://suwayomi.williampring.ca
                               │  browse sources · library · read · mark read · download to phone
                               ▼
                 suwayomi (media ns, 32GB worker)  ──► Mihon extensions (Keiyoushi repo) ──► online sources
                      │ downloads as CBZ
                      ▼
          NFS /data/library/manga/<Source>/<Series>/<Chapter>.cbz   ◄── also where you hand-copy manga
                      │
                      ▼
                 Kavita (Manga library) ──► Komf metadata ──► read in Kavita / Paperback (Kavya source)
```

| Argo app | Path | Deploys |
|---|---|---|
| `suwayomi` | `gitops/suwayomi` | Deployment, data PVC, NFS downloads claim, NodePort, Ingress |

Design decisions: Basic auth with hard-coded credentials for now (the Paperback extension speaks
Basic; Suwayomi's newer login mode does not work with it) · H2 database on local-path with daily built-in backups · downloads into
the **shared** Kavita manga folder · no FlareSolverr by default.

---

## First-time setup

### 1. Credentials (hard-coded, for now)
Edit `AUTH_USERNAME` / `AUTH_PASSWORD` in `gitops/suwayomi/deployment.yaml` before pushing.
These are the credentials for **both** the WebUI and Paperback.
⚠️ They end up in git history. Pick something you would not mind rotating; moving them into a
SOPS secret later is the four-file recipe in `docs/secrets.md` §5.

### 2. DNS + deploy
```
Cloudflare DNS:  suwayomi → A → <master's Tailscale IP>   (grey cloud / DNS only)
```
```bash
git push
sudo k3s kubectl apply -f gitops/apps/suwayomi.yaml     # Argo UI → suwayomi → review → SYNC
sudo k3s kubectl get pods -n media -l app=suwayomi -w    # first start ~1–2 min (downloads the WebUI)
sudo k3s kubectl logs -n media deploy/suwayomi --tail=30
```
Open https://suwayomi.williampring.ca → log in with the credentials from step 1.

### 3. Install sources (one-time, in the WebUI)
The Keiyoushi extension repository is preconfigured. **Browse → Extensions** → search the
sources you use (e.g. MangaDex, Weebcentral, Comick…) → **Install**. Only install what you
read; each extension is code from a third-party repo running on your server.

### 4. Settings worth setting (WebUI → Settings)
- **Library → Global update**: interval (e.g. every 12h) → new chapters appear for your subscriptions.
- **Downloads → Auto-download new chapters**: on, if you want the server to fetch every new
  chapter of a library series automatically (that is what fills Kavita without touching anything).
- **Downloads → Delete chapters after reading**: off (Kavita keeps them).

### 5. Paperback on the iPhone
1. Install Paperback (0.8.x) from https://paperback.moe.
2. On the phone open **https://tahouse.github.io/tachidesk-paperback-ext/** → *Add to Paperback*.
   (This is the maintained fork of the official Suwayomi extension; it was updated for the
   current server in Sept 2026. The upstream link is https://suwayomi.github.io/tachidesk-paperback-ext/.)
3. Paperback → Settings → External Sources → **Suwayomi / Tachidesk** → Source Settings:
   - Server URL: `https://suwayomi.williampring.ca`   (must be HTTPS on iOS 18+)
   - Authentication: **Enabled**, username + password from step 1
   - *Test Server* → OK
4. The source's homepage now shows your Suwayomi library by category, plus "updated". Browse
   the server's installed sources from the search, add to library, read, and use Paperback's
   own download for offline on the phone.

Tailscale must be ON on the phone (same as every other hostname).

Fallback client: **Aidoku 0.9+** has native Suwayomi support (library + tracking) if Paperback or
its extension stop being maintained.

### 6. Kavita side (already set up)
Nothing to do: `/data/library/manga` is Kavita's Manga library. After Suwayomi downloads
something, Kavita picks it up on its next scan (or Library → Scan). Komf matches the series.
Suwayomi's `<Source>/` folder level is read by Kavita as a publisher layer — harmless.

---

## How the pieces relate (what lives where)

| You want to… | Use | Notes |
|---|---|---|
| discover new series / browse a source | Paperback or WebUI | both hit the server's extensions |
| subscribe (get new chapters automatically) | add to **library** in either | library is on the server → shared |
| read online (nothing stored) | Paperback or WebUI | pages stream via the server |
| read offline on the phone | Paperback → download chapter | stored on the phone |
| keep the files forever / read in Kavita | WebUI → download (or auto-download) | CBZ → NFS → Kavita |
| per-page progress sync phone ↔ computer | Suwayomi tracks "read" per chapter | Paperback marks chapters read on the server |

---

## Maintenance

- **Upgrades**: Renovate PRs `ghcr.io/suwayomi/suwayomi-server:vX.Y.Z` (own PR each — the H2 DB
  migrates on start). The WebUI self-updates on the `stable` channel.
- **Backups**: Suwayomi writes a backup (library, categories, read state, settings) every day
  into its data volume, keeps 14. Restore: WebUI → Settings → Backup → Restore. The CBZs are on
  NFS and need no backup from Suwayomi.
- **Cloudflare-protected sources** (extension says "Cloudflare"/403): add a Byparr/FlareSolverr
  Deployment in `gitops/suwayomi/` (image `ghcr.io/thephaseless/byparr`, port 8191) and set
  `FLARESOLVERR_ENABLED=true`, `FLARESOLVERR_URL=http://suwayomi-byparr:8191`. It runs a full
  Chromium (~1 GB RAM), which is why it is off by default.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod `Pending` | worker not labelled `immich-node=true` or NFS mount failed (`kubectl describe pod`) |
| Login loop / 401 in WebUI | wrong creds, or `AUTH_MODE` changed in the UI to `ui_login` → the env resets it on restart |
| Paperback "Test Server" fails | not HTTPS, Tailscale off on the phone, cert not issued (`kubectl get certificate -n media suwayomi-tls`), or auth switch off |
| Paperback shows empty homepage | library empty on the server, or category rows disabled in the source's Homepage Settings |
| Source returns nothing / 403 | extension needs FlareSolverr (above) or the site changed — update the extension (Extensions tab) |
| Downloads not in Kavita | scan not run yet; or chapter not finished (Suwayomi zips at the end). `kubectl exec deploy/kavita -- ls /library/manga` |
| OOMKilled | raise `limits.memory` in the Deployment; the embedded Chromium is the hungry part |

### Handy checks
```bash
sudo k3s kubectl get pods -n media -l app=suwayomi -o wide
sudo k3s kubectl logs -n media deploy/suwayomi -f
sudo k3s kubectl exec -n media deploy/suwayomi -- ls -la /home/suwayomi/.local/share/Tachidesk /home/suwayomi/.local/share/Tachidesk/downloads
curl -u <user>:<pass> -s https://suwayomi.williampring.ca/api/graphql -H 'Content-Type: application/json' -d '{"query":"{ aboutServer { version } }"}'
```

## Quick reference
```
Computer:   https://suwayomi.williampring.ca      (LAN http: http://192.168.68.21:30456)
iPhone:     Paperback → extension https://tahouse.github.io/tachidesk-paperback-ext/ → Server URL above + creds
Downloads:  192.168.68.50:/data/library/manga/<Source>/<Series>/   → Kavita Manga library
Creds:      gitops/suwayomi/deployment.yaml (AUTH_USERNAME / AUTH_PASSWORD)
```
