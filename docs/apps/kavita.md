# Kavita — manga + books library

One reader for everything: **Kavita** serves manga/comics (CBZ/CBR) and ebooks (EPUB/PDF) with
reading progress, OPDS and a web reader. One helper feeds it good metadata:

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
```

| Argo app | Path | Deploys |
|---|---|---|
| `kavita` | `kubernetes/apps/media/kavita` | Kavita + NFS library PV/PVC + config PVC + Ingress |
| `calibre` | `kubernetes/apps/media/calibre` | CWA + the `calibre-books` / `calibre-ingest` NFS claims Kavita reuses |

Kavita keeps its state on a `local-path` PVC. Nothing there is irreplaceable: the files are on NFS,
and it rebuilds its DB by rescanning (reading progress is the one thing a rebuild loses).

> **Komf was removed (Nov 2026).** It looked manga up on MangaUpdates / AniList / MangaDex and wrote
> the metadata into Kavita. Without it, Kavita shows what the files and folder names say (plus any
> `ComicInfo.xml` inside a `.cbz`). Cluster leftovers: `docs/runbooks/cluster-cleanup.md` §8.

---

## Folder layout on the file server (192.168.68.50)

```
/data/library/manga/<Series Name>/<Series Name> v01.cbz     ← Manga library (Kavita) — hand-copied
/data/library/manga/<Source>/<Series>/<Chapter>.cbz            ← same library, written by Suwayomi (docs/apps/suwayomi.md)
/data/library/comics/<Series Name>/...                       ← Comic library (optional)
/data/books/<Author>/<Title>/<Title>.epub                    ← Book library (Calibre owns this)
/data/books-ingest/                                          ← drop new ebooks here → CWA imports
```

Rules Kavita enforces for manga: **one folder per series, files inside it, nothing loose at the
library root.** Name the folder how the series is commonly known in English; Kavita uses it as the series title.

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
| Manga | Manga | `/library/manga` (add `/library/manga/<Source>` as extra folders if Suwayomi's source folders show up as series — `docs/apps/suwayomi.md` §6) |
| Comics | Comic | `/library/comics` (optional) |
| Books | Book | `/books` |

Book type reads the EPUB's own metadata (title/author/series that CWA embedded), so the
Calibre `Author/Title` folder layout is fine.

---

## How metadata flows

```
MANGA:   Suwayomi download (or copy a folder) → /data/library/manga/  →  Kavita scan (folder name + ComicInfo.xml)
BOOKS:   drop epub   → /data/books-ingest/    →  CWA import + metadata  →  /data/books  →  Kavita scan (Book lib)
```


---

## Upgrading
- **Kavita**: bump `image:` in `kubernetes/apps/media/kavita/deployment.yaml`
  (`lscr.io/linuxserver/kavita:version-vX.Y.Z.W`). Kavita migrates its DB on start; it is on a
  local-path PVC, so take a worker snapshot first if the release notes mention a migration.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Series shows a wrong/odd title | rename the folder to the common English title, then Library → Scan |
| New manga doesn't appear | Kavita hasn't scanned yet (Library → Scan), or the folder breaks the one-folder-per-series rule |
| Books show as one-book "series" with odd titles | EPUB lacks embedded metadata → in CWA enable auto-metadata enforcement, or fix metadata in CWA and let it write back |
| Kavita can't see `/books` | `calibre-books` PVC must be Bound in `media` (the `calibre` Argo app owns it) |
| Pod Pending / NFS mount error | node needs `nfs-common`; file server must export `/data` rw to the LAN |

### Handy checks
```bash
sudo k3s kubectl get pods -n media -l 'app in (kavita,calibre)' -o wide
sudo k3s kubectl exec -n media deploy/kavita -- ls /library/manga /books | head
```

---

## Quick reference
```
Reader:       https://library.williampring.ca      (LAN: http://<node-ip>:30500)
Books admin:  https://books.williampring.ca        (CWA — ingest + metadata for ebooks)
Manga files:  192.168.68.50:/data/library/manga/<Series>/
Book drop:    192.168.68.50:/data/books-ingest/
```
