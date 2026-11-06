# Wealthfolio — portfolio tracker (on trial)

`https://wealthfolio.williampring.ca` — a local-first portfolio tracker, running **next to Ghostfolio** to
compare the two on the same transactions. Pick a winner, then remove the other.

| | |
|---|---|
| **URL** | `https://wealthfolio.williampring.ca` (Tailscale only, no NodePort) |
| **Manifests** | `kubernetes/apps/apps/wealthfolio/` |
| **Namespace** | `apps` |
| **Image** | `wealthfolio/wealthfolio` (pinned; Renovate PRs carry the `⚠️ db-migration` label) |
| **Storage** | one SQLite file on a **local-path** PVC — **not backed up** (see below) |
| **Secret** | `wealthfolio-secret`: `WF_SECRET_KEY`, `WF_AUTH_PASSWORD_HASH` — from OpenBao `homelab/wealthfolio` via `externalsecret.yaml` |

---

## How it fits

```
browser ──TLS──▶ Traefik ──▶ wealthfolio :8088 (web UI + API, one Rust binary)
                                  │
                                  ├─ /data/wealthfolio.db   local-path PVC (SQLite, WAL mode)
                                  └─ Yahoo Finance          quotes, fetched by the server
```

No Postgres, no Redis, no background job queue. Compared with Ghostfolio, there is much less that can
leave returns stuck at 0.

⚠️ **Why local-path and not NFS.** Wealthfolio opens SQLite in **WAL mode**, and SQLite documents that WAL
does not work over a network filesystem. Actual keeps its SQLite on NFS; this app cannot. The cost: the
database lives on one node's disk, which is **not backed up and does not survive a rebuild**. That's fine for a
trial (re-import the broker CSV). It is not fine for your real records: see [Backups](#backups).

---

## First-time setup

### 1. DNS
Cloudflare → `wealthfolio` → A → the master's Tailscale IP, **grey cloud**.

### 2. The secret (in OpenBao, `homelab/wealthfolio`)
Both values are required: the server refuses to listen on `0.0.0.0` without a password. They live in OpenBao,
not git; `externalsecret.yaml` copies them into `wealthfolio-secret` ([`../platform/openbao.md`](../platform/openbao.md) §6).
**Create the entry before the first Sync**, or the ExternalSecret has nothing to read and the pod can't start.

**a. The key** (OpenBao web UI, `https://192.168.68.91:8200`, log in as `william`):
**Tools** → **Random** → *Number of bytes* **32**, *Output format* **base64** → **Generate** → copy. That's
`WF_SECRET_KEY` (44 characters). Not 48: the app rejects other lengths.

**b. The password hash** (OpenBao has no Argon2, so make it on your own machine — the OpenBao LXC's console
is fine; never an online generator):
```bash
apt install -y argon2                                   # once (Arch: pacman -S argon2)
read -rs -p "Wealthfolio password: " PW; echo
printf '%s' "$PW" | argon2 "$(openssl rand -hex 8)" -id -e; unset PW
```
Copy the line it prints; it starts with `$argon2id$`.

**c. The entry** (web UI): **Secrets Engines** → `homelab/` → **Create secret** → path `wealthfolio` →
| Key | Value |
|---|---|
| `WF_SECRET_KEY` | the base64 value from a |
| `WF_AUTH_PASSWORD_HASH` | the `$argon2id$…` line from b |

→ **Save**. Key names exactly as above (they must match `externalsecret.yaml`).

<details><summary>Same thing in the CLI</summary>

```bash
read -rs -p "Wealthfolio password: " PW; echo
HASH=$(printf '%s' "$PW" | argon2 "$(openssl rand -hex 8)" -id -e); unset PW
bao kv put homelab/wealthfolio \
  WF_SECRET_KEY="$(bao write -field=random_bytes sys/tools/random/32 format=base64)" \
  WF_AUTH_PASSWORD_HASH="$HASH"; unset HASH
```
`put` writes the whole entry (both keys at once). To change ONE value later use `kv patch` — a `put` with
one key would delete the other.
</details>

**Changing a value later:** the entry → **Create new version** → edit → **Save**, then
`sudo k3s kubectl -n apps annotate externalsecret wealthfolio-secret force-sync=$(date +%s) --overwrite`
and `sudo k3s kubectl -n apps rollout restart deploy/wealthfolio`.

ℹ️ Upstream's docs tell you to write `$$argon2id$$…`. That doubling is for **Docker Compose** only. In a
Kubernetes Secret the hash goes in exactly as `argon2` prints it.

⚠️ `WF_SECRET_KEY` both signs logins and encrypts stored secrets (API keys for data providers). Changing it
logs you out and makes those stored secrets unreadable.

### 3. Push, Sync, log in
Push → Argo shows `wealthfolio` OutOfSync → read the diff → **Sync** with **Prune** ticked (the old
KSOPS-made Secret, if any, is replaced by the ExternalSecret's). Check:
```bash
sudo k3s kubectl -n apps get externalsecret wealthfolio-secret   # SecretSynced, READY True
```
Then open the URL and log in with the password you hashed.

### 4. Set it up for Canadian accounts
1. **Settings → General → Base currency: CAD.** Unlike Ghostfolio this is a setting in the app, not an env
   var.
2. **One account per account type:** TFSA, RRSP, FHSA, non-registered, each with its own currency (a
   USD account for US-listed holdings if your broker keeps one).
3. **Import activities** from your broker's CSV (Activities → Import), one account at a time.
4. **Symbols need the Yahoo suffix:** `XEQT.TO`, `VFV.TO`, `RY.TO`. A bare `RY` is the US listing in USD.
5. **Contribution limits** (Settings) track TFSA and RRSP room.

---

## Comparing it with Ghostfolio

Import the **same** CSV into both, then compare each against your broker statement, not against each
other:

| Check | Where |
|---|---|
| total value per account matches the statement | both dashboards |
| return % on one holding you can work out by hand | the holding's page in each app |
| dividends counted | income view in Wealthfolio, Activities in Ghostfolio |

The app whose numbers match the statement wins. Remove the other one with
[`../platform/adding-an-app.md`](../platform/adding-an-app.md) §8.

---

## Backups

Nothing backs this up yet. Before it holds records you care about, either:

- **Export from the app** regularly (Settings → Exports) to a folder that gets backed up, or
- **Copy the database file while the app is stopped.** A live copy of a WAL database can be
  inconsistent. On the node that holds the volume:
  ```bash
  sudo k3s kubectl -n apps scale deploy/wealthfolio --replicas=0
  sudo k3s kubectl get pv "$(sudo k3s kubectl -n apps get pvc wealthfolio-data -o jsonpath='{.spec.volumeName}')" \
    -o jsonpath='{.spec.hostPath.path}{.spec.local.path}{"\n"}'     # the folder on that node's disk
  # copy wealthfolio.db (and any -wal / -shm files) from that folder to NFS, then:
  sudo k3s kubectl -n apps scale deploy/wealthfolio --replicas=1
  ```

If Wealthfolio wins the trial, automate this (a nightly CronJob that writes a consistent copy to NFS) as part
of the backup work in [`../index.md`](../index.md) §9.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod CrashLoops right after the first Sync | a value in `homelab/wealthfolio` is still `REPLACE_ME`, or `WF_SECRET_KEY` isn't 32 bytes → `sudo k3s kubectl -n apps logs deploy/wealthfolio` |
| Login page loads, but logging in does nothing | `WF_CORS_ALLOW_ORIGINS` doesn't match the URL in the address bar exactly (`https://`, no trailing slash) |
| Password rejected | the hash was mangled on its way into the secret (a shell ate the `$` parts): `bao kv get -field=WF_AUTH_PASSWORD_HASH homelab/wealthfolio` must start with `$argon2id$` |
| A holding has no price | wrong symbol: needs `.TO` for the TSX, `.V` for the TSXV |
| Data gone after a node rebuild | expected: local-path is not backed up (see above) |

## Quick reference

```bash
sudo k3s kubectl -n apps get pods -l app=wealthfolio
sudo k3s kubectl -n apps logs deploy/wealthfolio --tail=50
sudo k3s kubectl -n apps rollout restart deploy/wealthfolio
```
