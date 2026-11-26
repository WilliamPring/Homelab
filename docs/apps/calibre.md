# Calibre — ebook library

`https://books.williampring.ca` — [Calibre-Web-Automated](https://github.com/crocodilestick/Calibre-Web-Automated)
(CWA): Calibre-Web plus an ingest watcher. Drop an ebook in a folder and it is converted, tagged and
added to the library on its own. Read in a browser, over OPDS, or send to a Kindle.

| | |
|---|---|
| **URL** | `https://books.williampring.ca` (Tailscale). LAN/Kindle: `http://<node-LAN-IP>:30083` |
| **Manifests** | `kubernetes/apps/media/calibre/` |
| **Namespace** | `media` |
| **Image** | `crocodilestick/calibre-web-automated` (pinned; **merge Renovate PRs by hand** — CWA migrates `app.db` on boot) |
| **Storage** | `/data/books` + `/data/books-ingest` on NFS (192.168.68.50); `/config` on local-path |
| **Secret** | none — auth is CWA's own user database in `app.db` |
| **Sync** | manual (see below) |

---

## How it fits

```
browser / Kindle ──▶ Traefik (books.williampring.ca)  ─┐
Kindle browser   ──▶ NodePort 30083                   ─┴─▶ calibre :8083
                                                             │
                 /calibre-library ── NFS /data/books         │  books + metadata.db
                 /cwa-book-ingest ── NFS /data/books-ingest  │  drop zone, auto-imported
                 /config          ── local-path PVC          │  app.db: users, settings
```

**Two SQLite databases, deliberately split.** `metadata.db` is Calibre's own and must sit with the
books, so it is on NFS. `app.db` is CWA's (users, sessions, settings) and is written constantly —
SQLite locking over NFS is unreliable, so it stays on a local-path PVC. The consequence is that
`/config` **lives on one node's disk and is not backed up**: losing that node loses your users and
settings, but not a single book.

NodePort 30083 exists because the Kindle's browser will not follow the Tailscale name. It is in the
README's NodePort table — do not reuse the port.

---

## First-time setup

### 1. On the file server (Alpine LXC, 192.168.68.50)
```bash
mkdir -p /data/books /data/books-ingest
chown -R 1000:1000 /data/books /data/books-ingest     # matches PUID/PGID 1000 in the Deployment
```
Whatever node Calibre schedules onto needs `nfs-common`.

### 2. DNS
Cloudflare → `books` → A → the master's Tailscale IP, **grey cloud**.

### 3. Push and Sync
Argo shows `calibre` OutOfSync → read the diff → **Sync**. First boot takes a minute while CWA runs
its setup scripts (hence `initialDelaySeconds: 30` on the readiness probe).

### 4. Log in and change the password
Default credentials are `admin` / `admin123`. **Change them immediately** — the app is reachable on
the Tailnet the moment it starts.

---

## Adding books

Copy files into `/data/books-ingest` on the file server (or any share that maps to it). CWA picks
them up within seconds, converts to EPUB if needed, writes them into `/data/books` and **deletes the
original from the ingest folder** — an empty ingest folder means it worked.

Anything still sitting there failed to import: `kubectl -n media logs deploy/calibre` says why
(usually a DRM-protected file, which CWA will not touch).

## Kindle

Settings → Email → configure an SMTP sender, then **Send to Kindle** on any book. The Kindle's
`@kindle.com` address must have your sender whitelisted in Amazon's *Approved Personal Document
E-mail List* or the mail is dropped silently.

---

## Backups

The books on NFS are the thing that matters, and they inherit whatever protects `/data` on the file
server. `/config` (`app.db`) is not backed up — see the backup work in [`../index.md`](../index.md) §9.
`metadata.db` sits on NFS with the books, so a restore brings the library back intact.

## Why sync stays manual

CWA migrates `app.db` in place on boot, and a migration is not reversible by rolling the image back.
It is excluded from the auto-sync allow-list for that reason — see
[`../platform/argocd.md`](../platform/argocd.md#sync-mode-manual-except-four-apps).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod stuck `ContainerCreating` | NFS mount failing — the node lacks `nfs-common`, or `/data/books` doesn't exist on 192.168.68.50 → `kubectl -n media describe pod -l app=calibre` |
| Permission errors in the log | `/data/books*` isn't owned by `1000:1000` on the file server |
| Books land in ingest and stay there | import failed (DRM, corrupt file) → `kubectl -n media logs deploy/calibre` |
| Library empty after a pod move | expected if `/config` was lost with the node — re-point CWA at `/calibre-library` in Settings; the books themselves are on NFS |
| `Send to Kindle` silently does nothing | sender address not on Amazon's approved list |

## Quick reference

```bash
sudo k3s kubectl -n media get pods -l app=calibre
sudo k3s kubectl -n media logs deploy/calibre --tail=50
sudo k3s kubectl -n media rollout restart deploy/calibre
```
