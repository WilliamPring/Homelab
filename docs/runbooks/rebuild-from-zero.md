# Rebuild from zero — the whole stack, in order

What you would type if the cluster were gone. Also the best single read for *how the layers depend on
each other*. Everything in **bold** is a thing that is NOT in git and must be recreated by hand.

```
0 Proxmox + VMs/LXCs   →  1 Ansible (nodes)  →  2 Argo CD  →  3 the age key  →  4 ApplicationSet
→  5 platform apps (cert-manager → issuer)  →  6 out-of-git secrets & folders  →  7 apps, in order  →  8 phone
```

## 0. Hosts
Proxmox on both boxes (`proxmox-install.md`). VMs: master `.93`, worker `.63` (Debian, SSH key for `sysadmin`).
LXCs that must exist with their data: **file server `.50`** (NFS export of `/data`), **Postgres `.7`**,
**Valkey `.103`**. These hold the precious data — restore them from backups first if they were lost.

## 1. Nodes — Ansible
```bash
cd ansible
cp vars/secrets.example.yaml vars/secrets.local.yaml && $EDITOR vars/secrets.local.yaml   # immich_db_password
ansible-playbook site.yml --ask-become-pass        # stops once for `tailscale up` on each node → re-run
```
Result: Tailscale on both nodes, k3s up, nfs-common installed, **`immich-db` Secret** + **`immich-node=true`
label** created, the Immich Ingress applied (still Ansible-owned).

## 2. Argo CD
```bash
sudo k3s kubectl create namespace argocd
sudo k3s kubectl apply -k kubernetes/bootstrap/argocd/ -n argocd
sudo k3s kubectl -n argocd rollout status deploy/argocd-server
```
`platform/argocd.md` for the password and the UI hostname (needs the `argocd` DNS record and, for TLS,
step 5 to have happened — port-forward works meanwhile).

## 3. The age key (before anything with a secret can sync)
```bash
sudo k3s kubectl create secret generic sops-age -n argocd --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
sudo k3s kubectl -n argocd rollout restart deploy/argocd-repo-server
```
**This key is the master key.** It lives on the Arch box, in your password manager, and offline. `platform/secrets.md`.

## 4. Register every app
```bash
sudo k3s kubectl apply -f kubernetes/bootstrap/apps.yaml
sudo k3s kubectl -n argocd get applications          # all listed, OutOfSync — nothing deployed yet
```

## 5. Platform first (others depend on it)
Sync in this order, waiting for Healthy each time:
1. `cert-manager` (CRDs + controller) → 2. **`cloudflare-api-token` Secret** in `cert-manager`
   (`platform/tls.md`) → 3. `cert-manager-issuer` → `kubectl get clusterissuer letsencrypt` READY.
4. `ntfy` / `bark` (so step 7 can page you) → 5. `gatus` (watches everything that follows).

## 6. Out-of-git things the apps reference (check they exist)
| Thing | Where | Recreate |
|---|---|---|
| NFS folders | file server `/data/{images,library,library/manga,books,books-ingest,roms,romm-assets}` owned 1000:1000 | `mkdir -p … && chown -R 1000:1000 …` |
| `immich-db` Secret, node label | step 1 | re-run Ansible |
| `cloudflare-api-token` | step 5 | by hand |
| Postgres roles/DBs | LXC `.7`: `romm` | `scripts/postgres-romm-setup.sh` |
| Valkey ACL users | LXC `.103`: `immich`, `romm`, (`degoog`) | `platform/redis.md` |
| DNS records | Cloudflare: one A per hostname → master Tailscale IP, grey cloud | by hand (README Addresses table) |
| Suwayomi login, Komf/RomM secrets | inline / templates — see `platform/secrets.md` known debt | fill → `sops -e -i` |

## 7. Apps, in dependency order
```
immich-prereqs (vector Postgres + NFS library)  →  immich  →  immich-public-proxy
kavita  →  komf (needs Kavita's API key)        calibre     suwayomi     romm (needs Postgres + Valkey users)
searxng · degoog · homepage                     (independent)
```
Each: Argo → Sync → pod Ready → certificate READY → open the hostname → the app's doc for first-run steps
(admin account, libraries, folders).

## 8. Phone
Bark app → add server → device key → into Gatus env + Argo context (`apps/bark.md`). Paperback/Aidoku →
Suwayomi + Kavita (`apps/suwayomi.md`). Kindle → `apps/kindle.md`.

## Verify the rebuild
```bash
sudo k3s kubectl get applications -n argocd                 # all Synced + Healthy
sudo k3s kubectl get certificate -A                         # all READY
open https://status.williampring.ca                          # Gatus: everything green
```
If something in this list surprised you, it belongs in git or in a doc — fix that before the next rebuild.
