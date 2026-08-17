# GitOps (Argo CD) — the slow, manual introduction

The plan: keep Ansible for **infra** (Tailscale, k3s, LXCs, cert-manager), and move the
**apps** to Argo CD **one at a time, by hand**. Nothing is automated. You add an app to
Argo only when you feel like it; everything else keeps working exactly as it does today.

```
ansible/  → builds the cluster + infra   (you run the playbook)
gitops/   → apps Argo manages from git    (Argo syncs; starts MANUAL)
```

## Folder layout
```
gitops/
├── apps/                 ← Argo "Application" files (you kubectl apply these by hand)
│   └── searxng.yaml
└── searxng/              ← the app manifests Argo watches — SPLIT ONE FILE PER KIND
    ├── configmap.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```
Add an app later = new `<app>/` folder (one file per resource) + new `apps/<app>.yaml`.

**Conventions (keep every app consistent):**
- **One file per resource, named by kind** (`deployment.yaml`, `service.yaml`, …). The
  filename tells you what's inside; Argo applies every `.yaml` in the folder regardless.
- **Group a tightly-bound sub-component** into one file (e.g. Valkey's Deployment+Service+PVC
  → `valkey.yaml`).
- **No `Namespace` resource in app folders** — shared namespaces (`apps`) aren't owned by
  one app. The Application creates it via `syncOptions: [CreateNamespace=true]` instead.
- **No numeric prefixes** (`01-…`) — Argo orders resources itself (sync waves).

---

## Step 0 — install Argo CD (once, by hand)
```bash
sudo k3s kubectl create namespace argocd
sudo k3s kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# wait for it to come up:
sudo k3s kubectl -n argocd rollout status deploy/argocd-server
```

### Get the UI
```bash
# admin password:
sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# open it (leave running in a terminal):
sudo k3s kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080   (user: admin, password from above)
```

---

## Step 1 — put SearXNG under Argo (this is what we set up)

**First: is your GitHub repo private?**
- **Public** → skip ahead, it just works.
- **Private** → add repo creds once (UI: Settings → Repositories → Connect repo using
  HTTPS, paste a GitHub Personal Access Token), OR via CLI `argocd repo add`.

**Then apply the Application (by hand, once):**
```bash
sudo k3s kubectl apply -f gitops/apps/searxng.yaml
```

**Watch it (nothing happens automatically — sync is MANUAL):**
```bash
sudo k3s kubectl -n argocd get applications
# STATUS will show  Synced/OutOfSync  +  Healthy/Missing
```
In the UI you'll see the `searxng` app as **OutOfSync**. Click into it → **Sync** →
**Synchronize**. Argo now applies `gitops/searxng/searxng.yaml`. Done — SearXNG is under
GitOps, and you drove every step.

**Reach SearXNG:** `http://<node-ip>:30880` (still NodePort, unchanged).

---

## The everyday loop (once you're comfortable)
```
edit gitops/searxng/searxng.yaml  →  git commit + push  →  Argo shows OutOfSync
                                   →  click Sync (or `argocd app sync searxng`)
```
When you trust it, flip `syncPolicy` to `automated` in `apps/searxng.yaml` (commented
example is in that file) and Argo syncs on every push, no clicking.

## ⚠️ One-owner rule
While SearXNG is managed by Argo, don't ALSO deploy it via the Ansible `searxng` role —
disable that role so two things aren't fighting over the same resources. Argo is the owner.

---

## Adding the next app (later, same recipe)
1. `gitops/<app>/…` — the manifests (or Helm values).
2. `gitops/apps/<app>.yaml` — copy `searxng.yaml`, change name + path.
3. `sudo k3s kubectl apply -f gitops/apps/<app>.yaml`, then Sync in the UI.

No app-of-apps, no automation, no Ansible. One app at a time.
