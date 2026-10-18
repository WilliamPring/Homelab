# Argo CD (GitOps)

Argo CD is what deploys the **apps** — it watches this repo's `kubernetes/` tree and syncs the
cluster to match. Ansible builds the infra; Argo owns the apps. (See `kubernetes/README.md` for
the per-app workflow.)

## At a glance
| | |
|---|---|
| **URL** | https://argocd.williampring.ca |
| **Namespace** | `argocd` |
| **Installed by** | `kubectl apply -k kubernetes/bootstrap/argocd/` (by hand — NOT Ansible, NOT self-managed). The directory is a **kustomization**: the upstream install manifest (fetched from GitHub, pinned to a tag) + your patches |
| **Sync mode** | Manual per app (`syncPolicy` has `CreateNamespace=true`, no `automated:`) |
| **Apps** | `kubernetes/bootstrap/apps.yaml` — ApplicationSet over `kubernetes/apps/<namespace>/<app>/` |
| **Own config** | `kubernetes/bootstrap/argocd/` — `kustomization.yaml` (pinned upstream `install.yaml` URL + the patches below), `config.yaml` (insecure mode), `ingress.yaml`, `argocd-cm-patch.yaml` (kustomize build flags), `repo-server-ksops-patch.yaml` (KSOPS + tool overrides), `argocd-notifications-cm.yaml` (→ Bark/ntfy) |

## Install / update (by hand, always the same command)
`kubernetes/bootstrap/argocd/` is a kustomization, so it MUST be applied with **`-k`** (not `-f`: that would
apply the patch files as broken half-objects and the kustomization.yaml as garbage). The
upstream install objects carry no namespace, hence **`-n argocd`**.
```bash
sudo k3s kubectl create namespace argocd                  # first time only
sudo k3s kubectl create secret generic sops-age -n argocd \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt    # first time only — the age key KSOPS decrypts with (docs/platform/secrets.md)
sudo k3s kubectl apply -k kubernetes/bootstrap/argocd/ -n argocd
sudo k3s kubectl -n argocd rollout status deploy/argocd-server
sudo k3s kubectl -n argocd rollout status deploy/argocd-repo-server
```
Re-run the `apply -k` line after ANY change in `kubernetes/bootstrap/argocd/` (Renovate bump of the install,
notification tweaks, …). Argo does not manage itself.

What the directory sets up:
- the first `resources:` entry → `https://raw.githubusercontent.com/argoproj/argo-cd/vX.Y.Z/manifests/install.yaml`, the
  upstream install pinned to a tag. Not vendored, so CRDs/RBAC/images always match. Renovate PRs the
  tag (label `argocd`); upgrading Argo = merge that PR, run the `apply -k` line once.
- `config.yaml` → `server.insecure: true` in `argocd-cmd-params-cm` (see below).
- `ingress.yaml` → `argocd.williampring.ca`, cert-manager TLS (`argocd-tls`), backend `argocd-server:80`.
- `argocd-cm-patch.yaml` → a JSON patch on the install's `argocd-cm`: `kustomize.buildOptions: --enable-alpha-plugins --enable-helm`.
  `--enable-alpha-plugins` lets kustomize run the KSOPS generator; `--enable-helm` lets it inflate `helmCharts:` (immich, ntfy, cert-manager).
  (`argocd-cm.yaml` in the same folder is the older whole-ConfigMap version, no longer in the kustomization.)
- `repo-server-ksops-patch.yaml` → two init containers copy tools into the repo-server, and mounts the `sops-age` key:
  **ksops + its bundled kustomize** (from `viaductoss/ksops`) and **Helm 3.17** (from `alpine/helm`), both mounted over
  Argo's own binaries. Why: Argo 3.5 ships Helm 4, and ksops' kustomize is older than Argo's; the mismatch broke
  `helmCharts` rendering, so the repo-server now runs a known-good kustomize + Helm 3 pair. A future Argo upgrade does
  NOT change what renders your apps — bump those two images deliberately.
- `argocd-notifications-cm.yaml` → pushes to Bark and ntfy (`docs/platform/updates-and-notifications.md`).
- **DNS:** `argocd → A → <master Tailscale 100.x IP>` (grey cloud).

## How Argo turns a directory into running objects
```
git push ──► repo-server clones main ──► kustomize build --enable-alpha-plugins --enable-helm kubernetes/apps/<ns>/<app>
                                             ├─ resources: *.yaml                      (raw manifests)
                                             ├─ helmCharts: → helm pull + helm template  (immich, ntfy, cert-manager)
                                             └─ generators: → ksops → sops -d (age key)  (secrets)
             ──► rendered manifests ──► application-controller diffs them against the cluster ──► OutOfSync / Synced
             ──► you click Sync ──► kubectl apply (server-side for cert-manager) ──► health checks ──► Healthy
```
- The render is **cached**. After fixing a render error (missing flag, bad chart), use **Hard Refresh**, not Refresh.
- `scripts/ci/validate.sh` runs the same `kustomize build` for every app (KSOPS generator stripped — CI has no key),
  so "CI green" means "Argo will render it".
- Argo polls GitHub every ~3 min. A GitHub webhook would make it instant; not set up (not needed).

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

## Registering an app (ApplicationSet)
`kubernetes/bootstrap/apps.yaml` is an **ApplicationSet**: every directory `kubernetes/apps/<namespace>/<app>/`
becomes an Application named `<app>` deploying into `<namespace>`. So:
```bash
# add kubernetes/apps/<namespace>/<app>/ → git push → wait ~3 min
sudo k3s kubectl -n argocd get applications          # <app> is listed, OutOfSync
# then: Argo UI → <app> → SYNC → SYNCHRONIZE   (manual — nothing deploys until you sync)
```
Bootstrap (once, after installing Argo): `sudo k3s kubectl apply -f kubernetes/bootstrap/apps.yaml`.
Delete a directory → its Application is removed, its deployed resources stay (no finalizer).
Per-app exceptions (cert-manager's ServerSideApply) live in the set's `templatePatch`.
Hand-edits to a generated Application are reverted by the controller — change the directory instead.

### Adoption check (done 2026-10-13; keep for a rebuild)
Hand-applied Applications with the same names the set generates are adopted in place:
```bash
sudo k3s kubectl apply -f kubernetes/bootstrap/apps.yaml
sleep 60; sudo k3s kubectl -n argocd get applications                 # still exactly 15, all Synced
sudo k3s kubectl -n argocd get application kavita -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'   # → ApplicationSet
sudo k3s kubectl -n argocd describe applicationset apps | tail -20   # no errors in Events
```
If an app shows an "already exists / not managed" error in those events instead of being adopted:
`kubectl -n argocd delete application <app>` (no finalizer → its pods stay) and the set recreates it
within a minute.
Full onboarding checklist: `docs/platform/adding-an-app.md`.

## Gotchas
| Symptom | Cause / fix |
|---|---|
| `ERR_TOO_MANY_REDIRECTS` on the domain | insecure mode not active — apply `kubernetes/bootstrap/argocd/config.yaml` + `rollout restart deploy/argocd-server`; test in **incognito** (browsers cache redirect loops) |
| App stuck `OutOfSync / Missing` | you registered it but haven't clicked **SYNC** (manual mode) |
| `failed to resolve revision` on a Helm app | chart `targetRevision` must be a concrete version (all charts are pinned now; Renovate bumps them) |
| `failed to load generator plugin ... ksops` | the repo-server lacks KSOPS → `kubernetes/bootstrap/argocd/` was applied with `-f` or never re-applied; run the `apply -k` above, then **Hard Refresh** the app (the error is cached) |
| `must specify --enable-helm` / chart apps fail, raw apps fine | `argocd-cm` lacks the flag OR the repo-server was not restarted after the apply (ConfigMap read at startup). Check: `kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.kustomize\.buildOptions}'`; pods' AGE must be recent |
| chart apps fail with a helm/kustomize version error | the tool overrides in `repo-server-ksops-patch.yaml` (kustomize from ksops, Helm 3.17) must both be mounted; `kubectl -n argocd exec deploy/argocd-repo-server -c argocd-repo-server -- sh -c 'kustomize version; helm version --short'` |
| Need the full error text (UI truncates) | `make diag HOST=sysadmin@192.168.68.93` → `debug/argocd-diag.txt` (read-only snapshot: conditions, versions, logs) |
| `Deployment "argocd-repo-server" is invalid` on apply | live repo-server was edited by hand and conflicts with the patch → `kubectl apply -k kubernetes/bootstrap/argocd/ -n argocd --server-side --force-conflicts` once |
| Helm-chart app won't pull (OCI) | Settings → Repositories → Connect repo (type Helm, Enable OCI) — e.g. the Immich chart |
| Namespace shows OutOfSync and won't clear | leftover tracking label from an app that once declared the ns — strip it (`kubectl label ns <ns> app.kubernetes.io/instance-`); NEVER Sync-with-Prune a shared namespace |

## Notes
- Argo CD is **not self-managed** — it's installed + configured by hand, on purpose, so it
  can't break its own bootstrap. Its config files live in `kubernetes/bootstrap/argocd/`.
- Applications are generated by the **ApplicationSet** (`kubernetes/bootstrap/apps.yaml`). The only
  hand-applied objects are Argo's own install and that one file.
- Secrets: `docs/platform/secrets.md`. Updates & phone notifications: `docs/platform/updates-and-notifications.md`.
- The repo-server's kustomize and Helm are **pinned copies** from the KSOPS patch, not Argo's bundled ones (see above).
- Everything is **manual sync** by design — Argo shows drift but waits for a click, so there
  are no surprise upgrades (important for Immich).
