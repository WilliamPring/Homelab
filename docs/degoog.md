# degoog — search aggregator

A privacy-focused search aggregator (github.com/degoog-org/degoog) with a plugin/extension
system, backed by Valkey (Redis) for caching. Runs alongside SearXNG so you can compare the
two metasearch approaches.

## At a glance
| | |
|---|---|
| **URL (domain)** | https://search.williampring.ca |
| **URL (raw)** | http://\<node-ip\>:30882 (NodePort) |
| **Namespace** | `apps` |
| **Deployed by** | Argo CD (GitOps) — `gitops/apps/degoog.yaml` → `gitops/degoog/` |
| **Image** | `ghcr.io/degoog-org/degoog:latest` |
| **Cache** | Valkey (`degoog-valkey:6379`, in-cluster) |
| **Storage** | 2Gi PVC (`degoog-data`) + 1Gi PVC (`degoog-valkey-data`), local-path |

## Architecture
```
browser
  ├─ https://search.williampring.ca   (Ingress + Traefik + LE cert, via Tailscale)
  └─ http://<node-ip>:30882           (NodePort, raw)
       │
       ▼
  degoog pod  ──► Valkey (degoog-valkey:6379)   ← cache
     │
     └─ /app/data  ──► PVC degoog-data (local-path)   ← settings/state
```

## Files (GitOps — one per resource)
```
gitops/degoog/
├── deployment.yaml       # degoog (initContainer fix-perms → chown /app/data; Recreate)
├── degoog-service.yaml   # NodePort 30882 → 4444
├── ingress.yaml          # search.williampring.ca → degoog:4444 (cert degoog-tls)
├── secrets.yaml          # DEGOOG_SETTINGS_PASSWORDS  ⚠️ see note
├── valkey.yaml           # Valkey Deployment
├── valkey-service.yaml   # degoog-valkey:6379 (ClusterIP)
└── pvc.yaml              # degoog-data (2Gi) + degoog-valkey-data (1Gi)
gitops/apps/degoog.yaml   # the Argo Application (manual sync, CreateNamespace=true)
```

Key wiring:
- degoog reaches Valkey via `DEGOOG_VALKEY_URL: redis://degoog-valkey:6379`.
- `DEGOOG_PUBLIC_INSTANCE: "false"` — not a public instance.
- `DEGOOG_SETTINGS_PASSWORDS` comes from the `degoog-secret` Secret.
- The Deployment listens on **4444**; the Service maps `4444 → NodePort 30882`; the Ingress
  routes `search.williampring.ca → degoog:4444`.

## Passwords & secrets

degoog has **one secret**: `degoog-secret` (key `DEGOOG_SETTINGS_PASSWORDS`) — the password
that protects the settings/extensions UI. The Deployment reads it via `secretKeyRef`.

```bash
# check it exists:
sudo k3s kubectl get secret degoog-secret -n apps

# view the value:
sudo k3s kubectl get secret degoog-secret -n apps -o jsonpath='{.data.DEGOOG_SETTINGS_PASSWORDS}' | base64 -d; echo

# (re)create it by hand — the GitOps-safe way (out of git):
sudo k3s kubectl create secret generic degoog-secret -n apps \
  --from-literal=DEGOOG_SETTINGS_PASSWORDS='<YOUR_PASSWORD>' \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
```

### ⚠️ The git-vs-secret decision
`secrets.yaml` currently ships with a placeholder `DEGOOG_SETTINGS_PASSWORDS: "YOUR-PASSWORD"`:
1. **Committing a Secret to git is the anti-pattern.** For a **solo tailnet** (degoog isn't
   public), the value matters little — but it's still plaintext in the repo. Options: put a
   real value in and accept it's in git, **or** delete `secrets.yaml` and create `degoog-secret`
   by hand (command above), **or** use sealed-secrets later.
2. **On sync**, review the Secret's DIFF — if git's `YOUR-PASSWORD` would overwrite a real
   live value, fix it first (or the syncing placeholder wipes your real password).

## Deploy / sync (GitOps)
```bash
# after git push:
sudo k3s kubectl apply -f gitops/apps/degoog.yaml
# Argo UI → degoog → review DIFF (esp. the Secret) → SYNC → SYNCHRONIZE
```
Since degoog was originally deployed by Ansible, Argo **adopts** the running resources on
first sync — the PVCs keep their data, no disruption. Manual sync = nothing happens until
you click Sync.

## Verify
```bash
sudo k3s kubectl get pods,svc,ingress,pvc -n apps -l app=degoog
sudo k3s kubectl get pods -n apps -l app=degoog-valkey
```

## Access
**With DNS:** `https://search.williampring.ca`
**Raw NodePort:** `http://<node-ip>:30882`
**Without DNS (port-forward):**
```bash
sudo k3s kubectl -n apps port-forward --address 0.0.0.0 svc/degoog 4444:4444
# → http://<master-ip>:4444
```

## Troubleshooting
| Symptom | Cause / fix |
|---|---|
| `search.williampring.ca` 502/503 | Ingress backend port must be **4444** (matches the Service), not 8080 |
| Pod CrashLoop, `/app/data` EACCES | the `fix-perms` initContainer chowns `/app/data` to 1000 — ensure it's present |
| Can't reach Valkey | `DEGOOG_VALKEY_URL` must be `redis://degoog-valkey:6379`; check the valkey pod is Running |
| Argo stuck OutOfSync on the Secret | git placeholder vs live value differ — reconcile (see the Secret note) |

## Ansible cleanup (pending)
degoog still has an old Ansible footprint (role + Ingress + site.yml entry) that should be
removed so it isn't double-owned:
```
delete ansible/roles/degoog/            remove degoog Ingress from tls_ingress/files/tls.yaml
remove `- degoog` from site.yml Play 4
```
(Deferred while the playbook isn't being run — but close it out to avoid Ansible re-applying
degoog and fighting Argo.)
