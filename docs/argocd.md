# Argo CD (GitOps)

Argo CD is what deploys the **apps** — it watches this repo's `gitops/` folder and syncs the
cluster to match. Ansible builds the infra; Argo owns the apps. (See `gitops/README.md` for
the per-app workflow.)

## At a glance
| | |
|---|---|
| **URL** | https://argocd.williampring.ca |
| **Namespace** | `argocd` |
| **Installed by** | `kubectl apply -k gitops/argocd/` (by hand — NOT Ansible, NOT self-managed). The directory is a **kustomization**: the upstream install manifest (fetched from GitHub, pinned to a tag) + your patches |
| **Sync mode** | Manual per app (`syncPolicy` has `CreateNamespace=true`, no `automated:`) |
| **Own config** | `gitops/argocd/` — `kustomization.yaml` (points at the pinned upstream `install.yaml` URL, Renovate bumps the tag), `config.yaml` (insecure mode), `ingress.yaml`, `argocd-cm.yaml` (kustomize plugin flags for KSOPS), `repo-server-ksops-patch.yaml` (SOPS decryption), `argocd-notifications-cm.yaml` (→ ntfy) |

## Install / update (by hand, always the same command)
`gitops/argocd/` is a kustomization, so it MUST be applied with **`-k`** (not `-f`: that would
apply the patch files as broken half-objects and the kustomization.yaml as garbage). The
upstream install objects carry no namespace, hence **`-n argocd`**.
```bash
sudo k3s kubectl create namespace argocd                  # first time only
sudo k3s kubectl create secret generic sops-age -n argocd \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt    # first time only — the age key KSOPS decrypts with (docs/secrets.md)
sudo k3s kubectl apply -k gitops/argocd/ -n argocd
sudo k3s kubectl -n argocd rollout status deploy/argocd-server
sudo k3s kubectl -n argocd rollout status deploy/argocd-repo-server
```
Re-run the `apply -k` line after ANY change in `gitops/argocd/` (Renovate bump of the install,
notification tweaks, …). Argo does not manage itself.

What the directory sets up:
- the first `resources:` entry → `https://raw.githubusercontent.com/argoproj/argo-cd/vX.Y.Z/manifests/install.yaml`, the
  upstream install pinned to a tag. Not vendored, so CRDs/RBAC/images always match. Renovate PRs the
  tag (label `argocd`); upgrading Argo = merge that PR, run the `apply -k` line once.
- `config.yaml` → `server.insecure: true` in `argocd-cmd-params-cm` (see below).
- `ingress.yaml` → `argocd.williampring.ca`, cert-manager TLS (`argocd-tls`), backend `argocd-server:80`.
- `argocd-cm.yaml` → `kustomize.buildOptions: --enable-alpha-plugins --enable-exec` so KSOPS can run.
- `repo-server-ksops-patch.yaml` → installs ksops+kustomize into the repo-server and mounts the `sops-age` key.
- `argocd-notifications-cm.yaml` → pushes to ntfy (`docs/updates-and-notifications.md`).
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
| `failed to resolve revision` on a Helm app | chart `targetRevision` must be a concrete version (all charts are pinned now; Renovate bumps them) |
| `failed to load generator plugin ... ksops` | the repo-server lacks KSOPS → `gitops/argocd/` was applied with `-f` or never re-applied; run the `apply -k` above, then **Hard Refresh** the app (the error is cached) |
| `Deployment "argocd-repo-server" is invalid` on apply | live repo-server was edited by hand and conflicts with the patch → `kubectl apply -k gitops/argocd/ -n argocd --server-side --force-conflicts` once |
| Helm-chart app won't pull (OCI) | Settings → Repositories → Connect repo (type Helm, Enable OCI) — e.g. the Immich chart |
| Namespace shows OutOfSync and won't clear | leftover tracking label from an app that once declared the ns — strip it (`kubectl label ns <ns> app.kubernetes.io/instance-`); NEVER Sync-with-Prune a shared namespace |

## Notes
- Argo CD is **not self-managed** — it's installed + configured by hand, on purpose, so it
  can't break its own bootstrap. Its config files live in `gitops/argocd/`.
- Applications in `gitops/apps/` are also registered by hand today (`kubectl apply -f`). The
  planned next step is an **app-of-apps** root so a new app = a new file + push.
- Secrets: `docs/secrets.md`. Updates & phone notifications: `docs/updates-and-notifications.md`.
- Everything is **manual sync** by design — Argo shows drift but waits for a click, so there
  are no surprise upgrades (important for Vaultwarden/Immich).
