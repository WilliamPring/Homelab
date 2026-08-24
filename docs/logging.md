# Logging (Loki + Alloy + Grafana)

Centralized logs for the whole cluster — every pod's output, searchable in Grafana. The
first pillar of observability (metrics come later; see the roadmap at the bottom).

## At a glance
| | |
|---|---|
| **URL** | https://grafana.williampring.ca |
| **Namespace** | `monitoring` |
| **Deployed by** | Argo CD (GitOps) — three separate apps, synced in order |
| **Store** | Loki (`grafana/loki` chart, SingleBinary/monolithic, filesystem) |
| **Shipper** | Alloy (`grafana/alloy` chart, DaemonSet) |
| **UI** | Grafana (`grafana/grafana` chart) |

## Architecture
```
every pod's logs
     │
     ▼
Alloy (DaemonSet, one per node)  ──push──►  Loki (store, :3100)  ◄──query──  Grafana (UI)
   discovers pods via k8s API                filesystem PVC,                  Explore → LogQL
   labels: namespace/pod/container/node/app  7-day retention                  grafana.williampring.ca
```
- **Loki** stores logs cheaply (indexes labels, not full text). No UI of its own.
- **Alloy** is the agent that collects + ships logs. Without it, Loki stays empty.
- **Grafana** is where you actually read/search logs (Loki datasource pre-wired).

## GitOps files
```
gitops/
├── apps/
│   ├── loki.yaml       Argo app — chart grafana/loki      (sync 1st)
│   ├── alloy.yaml      Argo app — chart grafana/alloy     (sync 2nd)
│   └── grafana.yaml    Argo app — chart grafana/grafana   (sync 3rd)
├── loki/values.yaml     SingleBinary, filesystem, caches off, scale-out zeroed
├── alloy/values.yaml    DaemonSet + River config (discover pods → push to loki:3100)
└── grafana/values.yaml  Loki datasource + Ingress + admin secret
```

## Deploy order (matters!)
Loki first (it's the target), then Alloy (ships to it), then Grafana (reads it):
```bash
sudo k3s kubectl apply -f gitops/apps/loki.yaml      # → SYNC, wait for loki-0 Running
sudo k3s kubectl apply -f gitops/apps/alloy.yaml     # → SYNC, wait for alloy DaemonSet
sudo k3s kubectl apply -f gitops/apps/grafana.yaml   # → SYNC
```

### Out-of-git prereqs (like other apps)
```bash
# Grafana admin creds (must exist before Grafana syncs):
sudo k3s kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin --from-literal=admin-password='YOURPASSWORD'

# DNS: grafana → A → <master Tailscale 100.x IP>  (grey cloud)
```

## Verify the pipeline
```bash
# Loki alive:
sudo k3s kubectl -n monitoring port-forward svc/loki 3100:3100
curl -s http://localhost:3100/ready ; echo                       # → "ready"

# Logs actually arriving (empty [] before Alloy, populated after):
curl -s "http://localhost:3100/loki/api/v1/labels" ; echo        # → namespace, pod, ...
```

## Using it
```
https://grafana.williampring.ca → log in → Explore → datasource "Loki"
```
LogQL queries to try:
```logql
{namespace="media"}                     # all Immich logs
{namespace="media"} |= "error"          # only lines containing "error"
{app="vaultwarden"}                     # by app label
{namespace="monitoring", container="loki"}   # Loki's own logs
```

## Gotchas we hit (so you don't again)
| Symptom | Cause / fix |
|---|---|
| `loki-0` Pending, "insufficient memory" | the chart's default **chunksCache memcached wants ~9.6 GB** → we set `chunksCache.enabled: false` (keep it off) |
| **Only `loki-memberlist` service exists**, no pod/StatefulSet | `deploymentMode` value the chart doesn't recognize → workload templates render nothing. Match the value to the chart version (see below) |
| `deploymentMode`: `SingleBinary` vs `Monolithic` | **version-dependent!** chart `7.3.0` uses `SingleBinary`; newer charts renamed it to `Monolithic`. Verify with `helm show values grafana/loki --version <v> \| grep -A8 deploymentMode` |
| Argo app error `failed to resolve revision` | `targetRevision: "*"` does NOT work for Helm **chart** sources — pin a concrete version (`helm show chart <repo>/<chart> \| grep '^version'`) |
| Loki `/labels` stays empty after Alloy | Alloy can't read pod logs — check `kubectl logs -n monitoring -l app.kubernetes.io/name=alloy \| grep -i forbidden`; may need `pods/log` RBAC |
| MinIO pod you didn't want | the Loki docs example bundles MinIO — we use `object_store: filesystem` instead (no MinIO) |

## Storage
```
Logs → Loki filesystem PVC (local-path, 10Gi, 7-day retention)
```
**Offsite later:** switch Loki to `object_store: s3` pointed at **Backblaze B2** (S3-compatible) — no MinIO needed. That's the upgrade path when you want durable/offsite logs.

## Roadmap (after logs)
```
✅ Phase 1  LOGS      Loki + Alloy + Grafana        ← this doc
⬜ Phase 2  METRICS   kube-prometheus-stack         ← CPU/RAM/OOM graphs (same Grafana)
⬜ Phase 3  ALERTING  Alertmanager → ntfy           ← phone push on crashes
```
Phase 2 is what graphs the Immich OOM/restart pressure. Grafana is shared across all phases.
