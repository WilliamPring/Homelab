# Argo CD (GitOps)

Argo CD is what deploys the **apps** — it watches this repo's `kubernetes/` tree and syncs the
cluster to match. Ansible builds the infra; Argo owns the apps. (See `kubernetes/README.md` for
the per-app workflow.)

## At a glance
| | |
|---|---|
| **URL** | `https://deploy.williampring.ca` (NPMplus + Cloudflare tunnel). Fallback: `http://192.168.68.63:30443` — **LAN only, plain HTTP** |
| **Namespace** | `argocd` |
| **Installed by** | `kubectl apply -k kubernetes/bootstrap/argocd/` (by hand — NOT Ansible, NOT self-managed). The directory is a **kustomization**: the upstream install manifest (fetched from GitHub, pinned to a tag) + your patches |
| **Sync mode** | Manual per app (`syncPolicy` has `CreateNamespace=true`, no `automated:`) |
| **Apps** | `kubernetes/bootstrap/apps.yaml` — ApplicationSet over `kubernetes/apps/<namespace>/<app>/` |
| **Own config** | `kubernetes/bootstrap/argocd/` — `kustomization.yaml` (pinned upstream `install.yaml` URL + the patches below), `config.yaml` (insecure mode), `ingress.yaml`, `argocd-cm-patch.yaml` (kustomize build flags), `repo-server-ksops-patch.yaml` (KSOPS + tool overrides), `argocd-notifications-cm.yaml` (→ Bark) |

## Install / update (by hand, always the same command)
`kubernetes/bootstrap/argocd/` is a kustomization, so it MUST be applied with **`-k`** (not `-f`: that would
apply the patch files as broken half-objects and the kustomization.yaml as garbage). The
upstream install objects carry no namespace, hence **`-n argocd`**.
```bash
sudo k3s kubectl create namespace argocd                  # first time only
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
- `argocd-server-nodeport-patch.yaml` → a JSON-6902 patch making the `argocd-server` Service a
  NodePort on **30443**. ⚠️ Must be JSON-6902: a strategic-merge patch applies `type: NodePort`
  but **silently drops `nodePort`**, giving you a random port and a Service that looks right.
  ⚠️ It also carries no `namespace:` — the upstream manifest's resources have none, so a
  namespaced patch matches nothing.
  (There is no `ingress.yaml` any more — see Access.)
- `argocd-cm-patch.yaml` → a JSON patch on the install's `argocd-cm`: `kustomize.buildOptions: --enable-helm`,
  which lets kustomize inflate `helmCharts:` (immich, cert-manager, external-secrets, the monitoring three).
  (`argocd-cm.yaml` in the same folder is the older whole-ConfigMap version, no longer in the kustomization.)
- **There is no repo-server patch.** Until Nov 2026 one mounted KSOPS, KSOPS's bundled kustomize and a matching
  Helm 3 over Argo's own binaries — the tool overrides existed only because KSOPS's kustomize was older than
  Argo's and would not drive the Helm that Argo ships. Retiring SOPS retired all of it, so the repo-server now
  runs the kustomize + Helm pair from the Argo image, which upstream tests together. Nothing to pin, and an
  Argo bump no longer risks a tool mismatch.
- `argocd-notifications-cm.yaml` → pushes to Bark (`docs/platform/updates-and-notifications.md`).
- **DNS:** `argocd → A → <master Tailscale 100.x IP>` (grey cloud).

## How Argo turns a directory into running objects
```
git push ──► repo-server clones main ──► kustomize build --enable-helm kubernetes/apps/<ns>/<app>
                                             ├─ resources: *.yaml                      (raw manifests)
                                             └─ helmCharts: → helm pull + helm template  (immich, cert-manager)
     (secrets are NOT rendered here: an ExternalSecret is just another manifest, and ESO fills it
      in-cluster afterwards — the repo-server never sees a secret value)
             ──► rendered manifests ──► application-controller diffs them against the cluster ──► OutOfSync / Synced
             ──► you click Sync ──► kubectl apply (server-side for cert-manager) ──► health checks ──► Healthy
```
- The render is **cached**. After fixing a render error (missing flag, bad chart), use **Hard Refresh**, not Refresh.
- `scripts/ci/validate.sh` runs the same `kustomize build` for every app — byte-for-byte the same since
  KSOPS went, so "CI green" means "Argo will render it".
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
https://deploy.williampring.ca        anywhere                — NPMplus + Cloudflare tunnel
http://192.168.68.63:30443            same LAN                — HTTP, NodePort  (FALLBACK)
http://<master-ip>:8080               port-forward (below)    — HTTP, insecure mode
```

**Two doors, on purpose — and the second is not optional.**

`deploy.williampring.ca` is the everyday one. ⚠️ It is **not** an Ingress: there is no Ingress
and no cert-manager certificate for Argo in this repo. NPMplus owns that hostname (via a
Cloudflare tunnel, with NPMplus's own certbot cert) exactly as it does for Bark. So the chain is
Cloudflare → tunnel → NPMplus → `http://<node>:30443`.

⚠️ **The tunnel's Service URL must be `http://`, not `https://`.** Argo runs in insecure mode;
pointing the tunnel at https, or losing `server.insecure`, produces ERR_TOO_MANY_REDIRECTS.
That exact loop cost a night in Nov 2026 — see the header of `config.yaml`.

The NodePort stays because that whole chain is the thing Argo is often needed to repair.
`argocd.williampring.ca` was removed for the same reason: it depended on a Cloudflare record →
the master's Tailscale IP → Traefik → a Let's Encrypt cert issued over Cloudflare DNS-01. When
Argo is the tool you need *in order to fix* a broken edge, depending on the edge is backwards.

⚠️ **Plain HTTP.** `server.insecure: true` (needed so Traefik could terminate TLS) means this
port is unencrypted — the Argo password and session token cross the LAN in the clear. Acceptable
on a home network; do not use it from one you do not control.

⚠️ **Not reachable over Tailscale.** A LAN IP needs you on the LAN. Off-network, use the
port-forward below over SSH, or put the hostname back.
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

**You never write an Application file, and you never `kubectl apply` a new app.** That is the single
thing to take away from this section. Adding an app is `mkdir` + `git push`.

### How a directory becomes an Application

`kubernetes/bootstrap/apps.yaml` is an **ApplicationSet** — an object whose job is to *generate other
objects*. Its generator is a **git directory generator**: it clones this repo and globs
`kubernetes/apps/*/*`. Every directory that matches produces one Application, with the name and the
destination namespace read straight out of the path:

```
kubernetes/apps/ apps  / karakeep /   →   Application "karakeep"  →  namespace "apps"
kubernetes/apps/ media / qbittorrent/ →   Application "qbittorrent" → namespace "media"
                 └──┬─┘   └────┬────┘
            segment 2 = namespace   basename = app name
```

So the directory *is* the registration. There is nothing else to create, which is why the layout rule
in `CLAUDE.md` ("directory name = Argo app name; parent = its namespace") is load-bearing rather than
just tidy — renaming a directory renames the app and orphans the old one.

### The loop, end to end

```
you: mkdir kubernetes/apps/<ns>/<app>/ + manifests
  └─► git push                                    ← the generator reads the REPO, not your disk.
        └─► ApplicationSet controller re-scans (~3 min poll)
              └─► Application "<app>" appears, OutOfSync / Missing
                    └─► you click SYNC                ← manual, always. Nothing deploys by itself.
                          └─► kubectl apply → health checks → Healthy
```

⚠️ **The push is the trigger.** Committing locally does nothing; the generator never sees your working
tree. "I added the directory and nothing showed up" is almost always an unpushed commit.

### Don't want to wait out the 3-minute poll?

Argo polls GitHub on a timer (no webhook here — see above). To make the set re-scan immediately:

```bash
sudo k3s kubectl annotate applicationset apps -n argocd \
  argocd.argoproj.io/application-set-refresh=true --overwrite
sudo k3s kubectl -n argocd get applications          # <app> is listed, OutOfSync
```

Then: Argo UI → `<app>` → **SYNC** → SYNCHRONIZE.

### If the app doesn't appear

| Check | Command |
|---|---|
| Is the commit actually on `main`? | `git log origin/main --oneline -1` |
| Does the path match the glob `kubernetes/apps/*/*`? | exactly two levels — `kubernetes/apps/<ns>/<app>/`, no deeper |
| Did the generator error? | `sudo k3s kubectl -n argocd describe applicationset apps \| tail -20` |

A directory one level too deep or too shallow is silently ignored — the glob simply doesn't match it,
and nothing logs a complaint. That is also why `kubernetes/templates/app/` is invisible to the set.

### The rest of the contract
- **Bootstrap (once, after installing Argo):** `sudo k3s kubectl apply -f kubernetes/bootstrap/apps.yaml`.
  This is the *only* Application-level object ever applied by hand.
- **Deleting a directory** removes its Application but **leaves the deployed resources running** (the
  generated apps carry no finalizer). Clean those up yourself if you want them gone.
- **Per-app exceptions** live in the set's `templatePatch` — today only cert-manager, which needs
  `ServerSideApply` because its CRDs blow past the client-side annotation size limit.
- **Hand-edits to a generated Application are reverted** by the controller, usually within seconds.
  Change the directory (or the `templatePatch`), never the live object.

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
| `must specify --enable-helm` / chart apps fail, raw apps fine | `argocd-cm` lacks the flag OR the repo-server was not restarted after the apply (ConfigMap read at startup). Check: `kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.kustomize\.buildOptions}'`; pods' AGE must be recent |
| chart apps fail with a helm/kustomize version error | should not happen since the KSOPS tool overrides went (Nov 2026) — the repo-server uses the Argo image's own pair. If it does, something re-introduced a repo-server patch: `kubectl -n argocd exec deploy/argocd-repo-server -c argocd-repo-server -- sh -c 'kustomize version; helm version --short'` |
| Need the full error text (UI truncates) | `make diag HOST=sysadmin@192.168.68.63` → `debug/argocd-diag.txt` (read-only snapshot: conditions, versions, logs) |
| `Deployment "argocd-repo-server" is invalid` on apply | live repo-server was edited by hand and conflicts with the patch → `kubectl apply -k kubernetes/bootstrap/argocd/ -n argocd --server-side --force-conflicts` once |
| Helm-chart app won't pull (OCI) | Settings → Repositories → Connect repo (type Helm, Enable OCI) — e.g. the Immich chart |
| Namespace shows OutOfSync and won't clear | leftover tracking label from an app that once declared the ns — strip it (`kubectl label ns <ns> app.kubernetes.io/instance-`); NEVER Sync-with-Prune a shared namespace |

## Notes
- Argo CD is **not self-managed** — it's installed + configured by hand, on purpose, so it
  can't break its own bootstrap. Its config files live in `kubernetes/bootstrap/argocd/`.
- Applications are generated by the **ApplicationSet** (`kubernetes/bootstrap/apps.yaml`). The only
  hand-applied objects are Argo's own install and that one file.
- Secrets: `docs/platform/openbao.md`. Updates & phone notifications: `docs/platform/updates-and-notifications.md`.
- The repo-server uses the kustomize and Helm **bundled in the Argo image** — the KSOPS-era overrides went in Nov 2026.
- Everything is **manual sync** by design — Argo shows drift but waits for a click, so there
  are no surprise upgrades (important for Immich).
