# Argo CD (GitOps)

Argo CD is what deploys the **apps** — it watches this repo's `gitops/` folder and syncs the
cluster to match. Ansible builds the infra; Argo owns the apps. (See `gitops/README.md` for
the per-app workflow.)

## At a glance
| | |
|---|---|
| **URL** | https://argocd.williampring.ca |
| **Namespace** | `argocd` |
| **Installed by** | plain `kubectl apply` of the upstream manifest (by hand — NOT Ansible, NOT self-managed) |
| **Sync mode** | Manual per app (`syncPolicy` has `CreateNamespace=true`, no `automated:`) |
| **Own config** | `gitops/argocd/` (config.yaml + ingress.yaml) — applied by hand |

## Install (one time, by hand)
```bash
sudo k3s kubectl create namespace argocd
sudo k3s kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
sudo k3s kubectl -n argocd rollout status deploy/argocd-server
```

## Expose the UI at argocd.williampring.ca
Argo's own config lives in `gitops/argocd/` — apply the whole folder at once:
```bash
sudo k3s kubectl apply -f gitops/argocd/                       # config.yaml + ingress.yaml
sudo k3s kubectl rollout restart deploy/argocd-server -n argocd
```
- `config.yaml` → sets `server.insecure: true` in `argocd-cmd-params-cm`.
- `ingress.yaml` → `argocd.williampring.ca`, cert-manager TLS (`argocd-tls`), backend `argocd-server:80`.
- **DNS:** `argocd → A → <master Tailscale 100.x IP>` (grey cloud).

### ⚠️ Why insecure mode is required
argocd-server serves HTTPS + force-redirects HTTP→HTTPS by default. Behind Traefik (which
terminates TLS), that causes **`ERR_TOO_MANY_REDIRECTS`**. Insecure mode makes argocd-server
serve plain HTTP so Traefik owns the TLS:
```
browser ──HTTPS──► Traefik (terminates argocd-tls) ──HTTP──► argocd-server:80
```
This is why the Ingress backend is port **80**, not 443.

## Access
```
https://argocd.williampring.ca        (Tailscale on)          — HTTPS via Ingress
http://<master-ip>:8080               port-forward (below)    — HTTP, insecure mode
```
Port-forward fallback (note `:80`, and http — server is insecure):
```bash
sudo k3s kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:80
```

## Login
```bash
# initial admin password (auto-deleted once you change it):
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```
User: `admin`. To set your **own** password (so you stop fetching the random one):
```bash
PW='your-password'
sudo k3s kubectl -n argocd patch secret argocd-secret -p \
  "{\"stringData\":{\"admin.password\":\"$(htpasswd -bnBC 10 '' \"$PW\" | tr -d ':\n')\",\"admin.passwordMtime\":\"$(date +%FT%TZ)\"}}"
# (needs htpasswd — Arch: sudo pacman -S apache. Or: argocd account update-password)
```
Argo only stores a **bcrypt hash** — there's no plaintext password to put in a committed yaml.

## Registering an app
```bash
sudo k3s kubectl apply -f gitops/apps/<app>.yaml     # registers the Application
# then: Argo UI → <app> → SYNC → SYNCHRONIZE   (manual — nothing deploys until you sync)
```
See `gitops/README.md` for the full add-an-app recipe.

## Gotchas
| Symptom | Cause / fix |
|---|---|
| `ERR_TOO_MANY_REDIRECTS` on the domain | insecure mode not active — apply `gitops/argocd/config.yaml` + `rollout restart deploy/argocd-server`; test in **incognito** (browsers cache redirect loops) |
| App stuck `OutOfSync / Missing` | you registered it but haven't clicked **SYNC** (manual mode) |
| `failed to resolve revision` on a Helm app | `targetRevision: "*"` doesn't work for Helm **chart** sources — pin a concrete version |
| Helm-chart app won't pull (OCI) | Settings → Repositories → Connect repo (type Helm, Enable OCI) — e.g. the Immich chart |
| Namespace shows OutOfSync and won't clear | leftover tracking label from an app that once declared the ns — strip it (`kubectl label ns <ns> app.kubernetes.io/instance-`); NEVER Sync-with-Prune a shared namespace |

## Notes
- Argo CD is **not self-managed** (no app-of-apps) — it's installed + configured by hand, on
  purpose, so it can't break its own bootstrap. Its config files live in `gitops/argocd/`.
- Everything is **manual sync** by design — Argo shows drift but waits for a click, so there
  are no surprise upgrades (important for Vaultwarden/Immich).
