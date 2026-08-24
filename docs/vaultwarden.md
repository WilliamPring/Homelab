# Vaultwarden

Self-hosted Bitwarden-compatible password manager. Runs in k3s, but its **data lives in
an external Postgres LXC** (survives cluster rebuilds + backed up to Backblaze B2).

## At a glance
| | |
|---|---|
| **URL** | https://vault.williampring.ca |
| **Admin panel** | https://vault.williampring.ca/admin (disabled until you set a token) |
| **Namespace** | `apps` |
| **Chart** | `guerzon/vaultwarden` (https://guerzon.github.io/vaultwarden) |
| **Deployed by** | Argo CD (GitOps) — `gitops/apps/vaultwarden.yaml` + `gitops/vaultwarden/values.yaml` |
| **Database** | External Postgres @ `192.168.68.7:5432/vaultwarden` (LXC) |
| **Chart version** | `targetRevision: "*"` (always latest; safe because sync is MANUAL) |

## Architecture — what lives where
```
Argo CD (from git)   →  the Vaultwarden Deployment/Service/PVC + which DB URI to USE
NOT in git (secret)  →  vaultwarden-db  (the postgresql:// URI + password) — hand-managed
NOT in cluster       →  Postgres itself (external LXC) + your vault DATA
```
The Helm chart does **not** deploy a database — `database.type: postgresql` + `existingSecret`
tells it to use the external LXC. Your passwords never enter the cluster.

## The `vaultwarden-db` secret (required, out of git)
The chart references an existing secret holding the FULL connection URI. It must exist in
the `apps` namespace BEFORE Argo syncs Vaultwarden (or the pod starts but can't connect).
```bash
# check it exists:
sudo k3s kubectl get secret vaultwarden-db -n apps

# recreate it (e.g. after a cluster rebuild):
sudo k3s kubectl create secret generic vaultwarden-db -n apps \
  --from-literal=uri='postgresql://vaultwarden:<PASSWORD>@192.168.68.7:5432/vaultwarden'
```

---

## The admin panel

Vaultwarden has a web admin panel at **`/admin`** for managing users and server settings.
It is **disabled by default** — you must set an admin token to enable it.

### What it does
- Invite / manage / delete users
- Diagnostics (version, DB connectivity)
- Live server settings (signups, SMTP, org policies)
- **Disable signups** after you've created your account (do this!)

### Enabling it (GitOps-safe: hashed token, stored in a Secret, NOT in git)

**1. Generate a hashed (Argon2) admin token** — never store it plaintext:
```bash
sudo k3s kubectl exec -n apps deploy/vaultwarden -it -- /vaultwarden hash
# type a strong password → prints an Argon2 hash: $argon2id$v=19$m=...
```
Remember the **plaintext password** you typed — that's what you log into `/admin` with.
The **hash** is what gets stored.

**2. Store the hash in a Secret** (hand-managed, out of git, like vaultwarden-db):
```bash
sudo k3s kubectl create secret generic vaultwarden-admin -n apps \
  --from-literal=token='$argon2id$v=19$m=...<full hash>...'
```

**3. Reference it from the chart** in `gitops/vaultwarden/values.yaml`:
```yaml
adminToken:
  existingSecret: "vaultwarden-admin"
  existingSecretKey: "token"
```
> ⚠️ Verify the exact key names against the guerzon chart's `values.yaml` before committing
> — the `adminToken` schema is chart-specific.

**4. Commit + push, then Sync** the vaultwarden app in Argo.

**5. Log in** at https://vault.williampring.ca/admin with the **plaintext password** from step 1.

### Security notes
- Keep `/admin` behind Tailscale (not publicly exposed) even with a token.
- **Disable signups** in the admin panel (or `signupsAllowed: false` in values) once your
  account exists — otherwise anyone reaching the URL can register.
- The token secret stays out of git; if you rebuild the cluster, recreate it (step 2).

---

## Common operations

**Access the app:** https://vault.williampring.ca (Tailscale + DNS pointing there).
Local debug without the Ingress:
```bash
sudo k3s kubectl -n apps port-forward svc/vaultwarden 8080:80   # → http://localhost:8080
```

**Check pod / logs:**
```bash
sudo k3s kubectl get pods -n apps -l app.kubernetes.io/name=vaultwarden
sudo k3s kubectl logs  -n apps -l app.kubernetes.io/name=vaultwarden --tail=50
```

**Upgrade (because version is "*" / latest):**
1. Back up Postgres first — `pg_dump -U vaultwarden vaultwarden > ~/vw-$(date +%F).sql`
2. Argo shows the app **OutOfSync** when a newer chart exists.
3. Review the diff → **SYNC**. A chart bump can run a DB migration — the backup is your rollback.

> ⚠️ Keep sync **MANUAL** for Vaultwarden (no `automated:` block). With `targetRevision: "*"`,
> auto-sync would upgrade your vault unattended.

**Back up the database (external LXC @ 192.168.68.7):**
```bash
pg_dump -U vaultwarden vaultwarden > ~/vaultwarden-$(date +%F).sql
```
