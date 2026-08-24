# Immich — self-hosted photos (iPhone sync)

Self-hosted photo/video backup for your iPhone. This is the goal the homelab was built
for: your camera roll syncs to your own server, photos stored on your file server.

---

## Architecture (how it fits your setup)
```
iPhone / browser
   │
   ├─ LOCAL:   http://<node-ip>:30041            (NodePort, plain http — no CF/cert)
   └─ REMOTE:  https://immich.williampring.ca     (Ingress + Tailscale + LE cert)
        │
        ▼
   immich-server  (k3s pod, pinned to the 32GB worker)
        ├─ Postgres (VECTOR image, local disk on worker) ← metadata + face/search embeddings
        ├─ Valkey (Redis)                                ← job queue
        └─ machine-learning pod                          ← CLIP / face detection
        │
        ▼
   Photo library → NFS: 192.168.68.50:/data/images       ← the actual photos
```
- **Postgres** is a *special* image (`ghcr.io/immich-app/postgres:…-vectorchord…`) — Immich needs the vector extension; vanilla Postgres won't work. It stays on **local disk** (never NFS).
- **Library** (the photos) lives on the **NFS file server** (`192.168.68.50:/data/images`).
- Everything is **pinned to the 32GB worker** (label `immich-node=true`).

---

## Deployment (Ansible)
| Piece | File |
|-------|------|
| Prereqs (vector Postgres + library NFS PV + DB secret + worker label) | `roles/immich/` |
| Helm chart values (DB env, valkey, nodeSelector) | `helm-values/immich.yaml` |
| Helm release (gated) | `vars/helm_releases.yml` |
| Toggle | `group_vars/all.yml` → `immich_enabled: true` |
| DB password (gitignored) | `vars/secrets.local.yaml` → `immich_db_password` |
| Ingress (remote access) | `roles/tls_ingress/files/tls.yaml` |

Deploy: set `immich_db_password` in `vars/secrets.local.yaml`, then `ansible-playbook site.yml`.

---

## Accessing Immich

### 1. LOCAL — NodePort (simplest, NO Cloudflare / DNS / cert) ⭐
Immich works over plain **http** on any node's IP. If the service isn't a NodePort yet:
```bash
sudo k3s kubectl patch svc immich-server -n media -p \
'{"spec":{"type":"NodePort","ports":[{"name":"http","port":2283,"targetPort":2283,"nodePort":30041}]}}'
sudo k3s kubectl get svc immich-server -n media    # TYPE=NodePort, 2283:30041
```
Then, on the **same LAN**:
```
http://192.168.68.21:30041      (worker — where Immich runs)
http://192.168.68.10:30041      (master — also works; k8s routes it)
```
- Browser: create the admin account here on first run.
- iPhone app (same WiFi): Server URL = `http://192.168.68.21:30041`.
- ⚠️ NodePort set via `patch` reverts on the next `helm upgrade` — to make it permanent, bake it into the chart values or a standalone Service.

### 2. LOCAL — hostname with the real cert, NO Cloudflare (/etc/hosts)
Reach it by hostname on the LAN (real HTTPS) without any Cloudflare DNS. Traefik on the
node's `:443` routes by hostname:
```bash
# /etc/hosts on your Mac/Arch:
192.168.68.10   immich.williampring.ca      # any node's LAN IP
```
```
https://immich.williampring.ca   🔒
```
Requires the `immich` Ingress deployed + `immich-tls` cert issued (`kubectl get certificate -n media`).
On the iPhone you'd need a matching per-device DNS entry (or use the NodePort URL instead).

### 3. REMOTE — domain + Cloudflare + Tailscale (works anywhere, incl. cellular)
```
Cloudflare DNS:  immich → A → <MASTER's Tailscale 100.x IP>   (grey cloud / DNS only)
Device:          Tailscale ON
Browse:          https://immich.williampring.ca
iPhone app:      Server URL https://immich.williampring.ca
```
- Use the **master's** Tailscale IP (consistent with vault/search — Traefik routes by hostname, so one IP serves all).
- Needs `immich-tls` issued (cert-manager via Cloudflare DNS-01).

---

## First run + accounts
- **Create the admin account in the BROWSER** (web UI) — the setup screen only appears there.
- The **mobile app is login-only** (no "create" button) — you log in with the web-created account.
- Then in the app: **Settings → Backup → enable**.

### Admin CLI (on the server)
```bash
# reset the admin password (prints a new one):
sudo k3s kubectl exec -n media deploy/immich-server -- immich-admin reset-admin-password
# list users (find the admin email):
sudo k3s kubectl exec -n media deploy/immich-server -- immich-admin list-users
```

---

## Storage
```
Library (photos) → NFS 192.168.68.50:/data/images   (RWX)
Postgres (DB)    → local disk on the worker          (NEVER on NFS)
```
- The file server must **export** `/data/images` (`rw, no_root_squash`) and it must be **writable** by Immich:
  ```bash
  # on the file server, if Immich can't create its folders (encoded-video etc.):
  chmod -R 777 /data/images
  ```
- **Migration to the DAS later:** mount the DAS at `/data/images` on the file server → no k8s change.

---

## Troubleshooting (issues hit during setup)
| Symptom | Cause / fix |
|---------|-------------|
| `getaddrinfo ENOTFOUND database` | DB env in the wrong place → must be under `controllers.main.containers.main.env` in the values (not top-level `env:`) |
| `failed to create <UPLOAD_LOCATION>/encoded-video` | NFS write perms → `chmod -R 777 /data/images` + `no_root_squash` |
| Helm: `nodePort 30041 already allocated` | a single NodePort leaks onto the ML service — don't set it in `service.main`; use a scoped patch/standalone Service |
| Can't hit it locally (ClusterIP) | no node port → add a NodePort (method 1) or use the Ingress |
| "site cannot be reached" on the domain | DNS not resolving (no CF record) or Tailscale off — `dig +short immich.williampring.ca` |
| App: "wrong username", no create option | create the admin in the **web UI** first; the app only logs in |
| Pod Pending | worker not labeled — `kubectl get node <worker> --show-labels` should have `immich-node=true` |

### Handy checks
```bash
sudo k3s kubectl get pods -n media -o wide     # all Running, on the worker?
sudo k3s kubectl get pv,pvc -n media           # immich-library PVC → Bound
sudo k3s kubectl logs -n media -l app.kubernetes.io/name=immich-server -f
```

---

## Quick reference
```
Local (no CF):   http://192.168.68.21:30041           (NodePort, plain http, same LAN)
Local (cert):    /etc/hosts → node LAN IP → https://immich.williampring.ca
Remote:          https://immich.williampring.ca       (Cloudflare + Tailscale)
Admin reset:     kubectl exec … immich-admin reset-admin-password
Photos land in:  192.168.68.50:/data/images
```
