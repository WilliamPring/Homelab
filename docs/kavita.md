# Kavita — manga + books library (with Komf for metadata)

One reader for everything: **Kavita** serves manga/comics (CBZ/CBR) and ebooks (EPUB/PDF) with
reading progress, OPDS and a web reader. Two helpers feed it good metadata:

- **Komf** — looks up every manga series on MangaUpdates / AniList / MangaDex and writes title,
  summary, authors, genres, tags, status and cover into Kavita.
- **Calibre-Web-Automated (CWA)** — you already run it. It ingests ebooks, fetches their
  metadata and embeds it into the EPUB. Kavita reads the Calibre library read-only.

---

## Architecture

```
                 https://library.williampring.ca            https://books.williampring.ca
                            │                                          │
                            ▼                                          ▼
                    kavita (media ns)                          calibre (CWA, media ns)
                    ├─ /library  ← NFS /data/library         ├─ /calibre-library ← NFS /data/books
                    │     └─ manga/<Series>/*.cbz            └─ /cwa-book-ingest ← NFS /data/books-ingest
                    └─ /books    ← NFS /data/books (RO)  ◄──── same folder, CWA writes, Kavita reads
                            ▲
                            │ Kavita API (key in SOPS secret)
                    komf (media ns)  https://komf.williampring.ca  (its own web UI)
                    └─ MangaUpdates · AniList · MangaDex
```

| Argo app | Path | Deploys |
|---|---|---|
| `kavita` | `gitops/kavita` | Kavita + NFS library PV/PVC + config PVC + Ingress |
| `komf` | `gitops/komf` | Komf + seed ConfigMap + config PVC + Ingress + KSOPS secret |
| `calibre` | `gitops/calibre` | CWA + the `calibre-books` / `calibre-ingest` NFS claims Kavita reuses |

Both Kavita and Komf keep their state on `local-path` PVCs. Neither holds anything
irreplaceable: the files are on NFS, and both rebuild their DBs by rescanning / rematching.

---

## Folder layout on the file server (192.168.68.50)

```
/data/library/manga/<Series Name>/<Series Name> v01.cbz     ← Manga library (Kavita + Komf)
/data/library/comics/<Series Name>/...                       ← Comic library (optional)
/data/books/<Author>/<Title>/<Title>.epub                    ← Book library (Calibre owns this)
/data/books-ingest/                                          ← drop new ebooks here → CWA imports
```

Rules Kavita enforces for manga: **one folder per series, files inside it, nothing loose at the
library root.** Name the folder how the series is commonly known in English; Komf matches on it.

```bash
# on the file server, once:
mkdir -p /data/library/manga /data/library/comics
chown -R 1000:1000 /data/library && chmod -R 775 /data/library
```

---

## First-time setup

### 1. Kavita libraries
Web UI → **Server Settings → Libraries → Add Library**:

| Name | Type | Folder |
|---|---|---|
| Manga | Manga | `/library/manga` |
| Comics | Comic | `/library/comics` (optional) |
| Books | Book | `/books` |

Book type reads the EPUB's own metadata (title/author/series that CWA embedded), so the
Calibre `Author/Title` folder layout is fine.

### 2. Komf: give it Kavita's API key (SOPS)
Komf talks to Kavita as **your user**, using your API key.

```
Kavita → avatar (top-right) → Settings → "3rd Party Clients" → API Key   (copy it)
```
Then on the Arch box (it has the age key):
```bash
# paste the key into the template, then encrypt in place
$EDITOR gitops/komf/komf-secret.enc.yaml            # replace REPLACE_ME_WITH_KAVITA_API_KEY
sops --encrypt --in-place gitops/komf/komf-secret.enc.yaml
git add gitops/komf gitops/apps/komf.yaml && git commit -m "feat: komf" && git push
```
Check the file before pushing: `stringData.KAVITA_API_KEY` must read `ENC[AES256_GCM,...]`.

### 3. DNS + deploy
```
Cloudflare DNS:  komf → A → <master's Tailscale IP>   (grey cloud / DNS only — Komf has NO login)
```
```bash
sudo k3s kubectl apply -f gitops/apps/komf.yaml      # Argo UI → komf → review → SYNC
sudo k3s kubectl get pods -n media -l app=komf        # Running (init container seeds config first)
sudo k3s kubectl logs -n media deploy/komf | tail     # "Started" + kavita event listener connected
curl -s https://komf.williampring.ca/api/kavita/metadata/providers   # → JSON list of enabled providers
```

### 4. Komf's web UI (and the optional extension)
Open **https://komf.williampring.ca**. Komf 2.x has its own UI:

- **Kavita → Libraries → Match library** — one-shot match of every series (do this once).
- **Search / Identify** — pick the right match by hand when it guessed wrong.
- **Settings** — providers, update rules, library-specific overrides. Saved to the live
  `application.yml` on Komf's PVC.
- **Jobs** — what it matched, what failed.

Optional: the **komf** browser extension for
[Chrome](https://chromewebstore.google.com/detail/komf/bhppjldobkpocplgfcimljjhdjgbpdnh) /
[Firefox](https://addons.mozilla.org/en-US/firefox/addon/komf/) puts the same Identify / Match
buttons inside the Kavita page. Set its **Komf URL** to `https://komf.williampring.ca`.

From then on the **event listener** matches new series automatically as Kavita scans them.

---

## How metadata flows

```
MANGA:   copy folder → /data/library/manga/  →  Kavita scan  →  Komf event  →  lookup  →  API write → Kavita
BOOKS:   drop epub   → /data/books-ingest/    →  CWA import + metadata  →  /data/books  →  Kavita scan (Book lib)
```

- Komf's `updateModes: [API]` writes into Kavita's DB only. Add `COMIC_INFO` in
  `gitops/komf/configmap.yaml` if you also want `ComicInfo.xml` written into the `.cbz` files
  (portable metadata, but Komf then needs the NFS mounted read-write — not wired today).
- `lockCovers: true` stops Kavita's scanner from overwriting Komf's chosen series cover.
- Komf's config is **seeded once** from the ConfigMap. Edits in git after the first start do
  NOT apply until you delete `/config/application.yml` on the PVC (or the PVC) and restart.

---

## Upgrading
- **Kavita**: bump `image:` in `gitops/kavita/deployment.yaml`
  (`lscr.io/linuxserver/kavita:version-vX.Y.Z.W`). Kavita migrates its DB on start; it is on a
  local-path PVC, so take a worker snapshot first if the release notes mention a migration.
- **Komf**: bump `sndxr/komf:X.Y.Z` in `gitops/komf/deployment.yaml`. Read the release notes —
  2.0.0 dropped several providers and moved BookWalker to an offline DB.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Komf pod `Init:Error` / CrashLoop, log says `failed to decrypt` or secret missing | `komf-secret.enc.yaml` not encrypted, or Argo can't decrypt → redo step 2; check `kubectl get secret komf-secret -n media` |
| Komf log `401` / `Unauthorized` from Kavita | wrong/rotated API key → update with `sops gitops/komf/komf-secret.enc.yaml`, push, sync, `rollout restart deploy/komf -n media` |
| komf.williampring.ca unreachable | DNS record missing, `komf-tls` not issued (`kubectl get certificate -n media`), or Tailscale off |
| Series matched to the wrong thing | Komf UI (or extension) → Identify → pick the right one. Rename the folder to the common English title to help future matches |
| Nothing happens when new manga is added | `eventListener.enabled` false in the LIVE config on the PVC, or Kavita hasn't scanned yet (Library → Scan) |
| Books show as one-book "series" with odd titles | EPUB lacks embedded metadata → in CWA enable auto-metadata enforcement, or fix metadata in CWA and let it write back |
| Kavita can't see `/books` | `calibre-books` PVC must be Bound in `media` (the `calibre` Argo app owns it) |
| Pod Pending / NFS mount error | node needs `nfs-common`; file server must export `/data` rw to the LAN |

### Handy checks
```bash
sudo k3s kubectl get pods -n media -l 'app in (kavita,komf,calibre)' -o wide
sudo k3s kubectl logs -n media deploy/komf -f
sudo k3s kubectl exec -n media deploy/komf -- cat /config/application.yml   # the LIVE config
sudo k3s kubectl exec -n media deploy/kavita -- ls /library/manga /books | head
```

---

## Quick reference
```
Reader:       https://library.williampring.ca      (LAN: http://<node-ip>:30500)
Books admin:  https://books.williampring.ca        (CWA — ingest + metadata for ebooks)
Komf UI:      https://komf.williampring.ca         (match / identify / settings — no login!)
Manga files:  192.168.68.50:/data/library/manga/<Series>/
Book drop:    192.168.68.50:/data/books-ingest/
API key:      Kavita → avatar → Settings → 3rd Party Clients
```
