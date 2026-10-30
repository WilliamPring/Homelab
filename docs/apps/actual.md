# Actual Budget

Envelope budgeting — you give every dollar a job at the start of the month, and the month tells you
when you've run out. Self-hosted, no bank connection required, no subscription.

`https://actual.williampring.ca` · LAN: `http://<node-LAN-IP>:30506` · `kubernetes/apps/apps/actual/`

---

## 1. The one thing to understand

**The app runs in your browser, not on the server.**

Actual is "local-first". The budgeting engine — the calculations, the rules, the whole UI — is
downloaded into your browser (or the desktop/mobile app) and runs there, against a copy of your budget
held locally. What we deployed here is only a **sync server**: it stores the budget file and shuttles
changes between your devices.

```
  your laptop browser  ─┐
  your phone app       ─┼──► actual sync server (this pod) ──► /data on NFS
  your desktop app     ─┘        stores + syncs the file
```

Three consequences worth knowing up front:

- **It is fast and tiny.** The server does almost nothing, which is why it asks for 128Mi of RAM.
- **It works offline.** Lose the server and your browser keeps working with its local copy; it syncs
  when the server comes back. Nothing is "down" in the usual sense.
- **`/data` is the only copy on the server.** There is no database to dump, no second replica. That
  directory *is* your financial history, which is why it lives on NFS and not on a local-path PVC.

---

## 2. What each file does

```
kubernetes/apps/apps/actual/
├── kustomization.yaml   lists the four below. No `generators:` — there is no secret here
├── deployment.yaml      one container, pinned image, probes, runs as uid 1000 for NFS
├── storage.yaml         the NFS PV/PVC for /data  (⚠️ read the prereq comment at the top)
├── service.yaml         ClusterIP + NodePort 30506
└── ingress.yaml         actual.williampring.ca + Let's Encrypt cert
```

**Why no secret file.** Most apps here have an `<app>-secret.enc.yaml`. Actual doesn't, because it has
no password in its configuration — you set the server password *in the browser* the first time you open
it, and it's stored hashed inside `/data`. Nothing sensitive ever goes near git.

---

## 3. First run

### 3.1 Create the NFS directory
On the file server (`192.168.68.50`), once:
```bash
mkdir -p /data/actual && chown -R 1000:1000 /data/actual && chmod -R 775 /data/actual
```
The uid matters: the container runs as 1000, and NFS checks the number, not the name. Skip this and the
pod starts but can't write, which shows up as Actual failing to create its database.

### 3.2 Add the DNS record
Cloudflare → `actual` → **A** → the master's Tailscale IP, **grey cloud** (DNS only).

### 3.3 Sync, then set the password
Push, then Sync in Argo. Open `https://actual.williampring.ca`. The first screen asks you to **create a
server password**. This is the password that protects the whole server — not a per-user login, since
Actual is single-tenant. Pick something real and put it in your password manager.

Then **Create a new budget** (or import, below) and you're running.

### 3.4 Optional: end-to-end encryption
Actual can encrypt the budget file so the *server* can't read it either. Settings → **Enable encryption**.
You get a second password that never leaves your devices.

Worth understanding the trade: with this on, `/data` on your NFS box becomes an opaque blob. That's
excellent if you ever sync through something you don't control — and a real risk here, because losing
that password means the backup is unrecoverable. Given the server is already Tailscale-only and the
disk is in your house, **I'd leave it off** unless you have a specific reason. If you turn it on, store
the key somewhere that isn't this cluster.

---

## 4. Migrating in

- **From the hosted Actual or another server:** Settings → Export in the old one, Import in the new one.
- **From YNAB4 / nYNAB:** Actual has a built-in importer on the "Create budget" screen.
- **From a bank:** no automatic feeds by default. Import OFX/QFX/CSV per account, or look at SimpleFIN
  (a paid bridge Actual supports) if manual import gets old.

---

## 5. Backups — read this one

Actual writes an automatic local backup inside `/data`, but that is on the same volume as the live file.
It protects you from *your own mistakes*, not from losing the disk.

Two things to do:

1. **Export periodically.** Settings → **Export data** gives you a single `.zip` you can keep anywhere.
   It is small. Do it after any big month-end cleanup.
2. **Back up `/data/actual` properly** once the cluster has real backups. This is on the known-gaps list
   in [`../index.md`](../index.md) §9 — and this app is a good argument for moving it up the list, since
   a budget is one of the few things here you genuinely cannot reconstruct.

---

## 6. Day-to-day

- **Phone/desktop apps** exist for iOS, Android, macOS, Windows and Linux. Point them at
  `https://actual.williampring.ca` and the server password. They need Tailscale on the device, like
  everything else here.
- **Upgrades:** Renovate opens a PR when a new `actualbudget/actual-server` tag ships. Actual releases
  roughly monthly and versions by date (`26.10.0` = October 2026). Read the release notes — the budget
  file format does change occasionally, and the app will migrate it on first load.
- **Rollback caution:** once a newer version migrates your budget file, an older server may refuse it.
  If you ever roll back, roll back to the version you came from, and keep an export from before.

---

## 7. Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| Pod `ContainerCreating`, mount errors | `/data/actual` doesn't exist on the NFS box | §3.1 |
| Pod Running but Actual errors on first load | the directory exists but isn't owned by `1000:1000` | `ls -ln /data/actual` on the file server |
| Browser says "server is not running" | DNS record missing, or Tailscale off on the device | `nslookup actual.williampring.ca` → should be the `100.x` address |
| Forgot the server password | it's hashed inside `/data` | stop the pod, move `/data/actual/account.sqlite` aside, restart → first-run screen again. **You keep your budget**, you just re-pair devices |
| Sync conflicts between devices | two devices edited offline | Actual resolves most automatically; check Settings → Repair if a budget looks wrong |

---

## 8. Quick reference

```bash
sudo k3s kubectl get pods -n apps -l app=actual
sudo k3s kubectl logs -n apps deploy/actual --tail=50
sudo k3s kubectl rollout restart deploy/actual -n apps
ls -ln /data/actual                      # on 192.168.68.50 — must be owned by 1000:1000
```

| Setting | Where | Value | Why |
|---|---|---|---|
| image | `deployment.yaml` | `actualbudget/actual-server:26.10.0` | pinned; date-based versioning |
| `/data` | `storage.yaml` | NFS `192.168.68.50:/data/actual` | precious, not rebuildable |
| NodePort | `service.yaml` | `30506` | mnemonic: Actual's own port 5006 |
| server password | set in browser | — | hashed inside `/data`, never in git |

Docs: <https://actualbudget.org/docs/>
