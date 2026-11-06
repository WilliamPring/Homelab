# Grafana stack — metrics, logs, and alerts when a pod misbehaves

`https://grafana.williampring.ca` — one UI for **what each app is using** (CPU, memory, restarts, over
time), **its logs** (including the run before it crashed), and **alerts to Bark** when a pod crash-loops,
gets OOMKilled, or stops being Ready.

| | |
|---|---|
| **URL** | `https://grafana.williampring.ca` (Tailscale only) |
| **Manifests** | `kubernetes/apps/monitoring/{kube-prometheus-stack,loki,alloy}/` — three Argo apps |
| **Charts** | `kube-prometheus-stack` (prometheus-community) · `loki` + `alloy` (Grafana Labs) — pinned in each `kustomization.yaml` |
| **Storage** | local-path on the worker: Prometheus 20Gi (15 days), Loki 10Gi (14 days), Grafana 2Gi, Alertmanager 1Gi — **all rebuildable, none backed up** |
| **Secret** | `kube-prometheus-stack-secret`: `admin-user`, `admin-password` (Grafana login) — built by `externalsecret.yaml` from OpenBao `homelab/grafana` |
| **Alerts** | Alertmanager → `bark-relay` → Bark (same phone, same `homelab` group as Gatus) |

---

## Why this exists next to Gatus

Gatus asks one question: *does the URL answer?* That misses a whole class of failures. Karakeep's
`/api/health` can return 200 while its Chrome sidecar crash-loops, while a worker is OOMKilled every
20 minutes, or while one pod in three isn't Ready. This stack watches **Kubernetes itself**:

| Question | Gatus | This stack |
|---|---|---|
| Is the app's URL up? | ✅ (pages you) | — |
| Is a container restarting / crash-looping / OOMKilled? | ❌ | ✅ (pages you) |
| What was Karakeep using last Tuesday before it died? | ❌ | ✅ (Grafana) |
| What did it log *before* the restart? | ❌ (`kubectl logs` only shows the current run) | ✅ (Loki, 14 days) |
| Is the alerting stack itself up? | ✅ (Gatus checks all six components) | ❌ (can't page about itself) |

Keep both. They watch each other.

---

## How it fits

```
              ┌────────────────────── kube-prometheus-stack ─────────────────────┐
kubelet/cAdvisor ─┐                                                              │
kube-state-metrics├──scrape──► Prometheus ──rules──► Alertmanager ──► bark-relay ─┼─► bark ─► APNs ─► iPhone
node-exporter ────┘              (15d)      (rules.yaml   (group, wait,  (reformat │
                                   │         + ~150        de-dupe)      the JSON) │
                                   │         defaults)                            │
                                   ▼                                              │
every pod's stdout ─► Alloy ─► Loki (14d) ─────────► Grafana ◄─── you            │
k8s events ─────────┘                                  ▲                          │
              └────────────────────────────────────────┼──────────────────────────┘
                                         grafana.williampring.ca (Traefik + cert-manager)
```

- **Prometheus** scrapes the kubelet's cAdvisor (per-container CPU/memory), kube-state-metrics (restarts,
  OOMKills, readiness, replicas) and node-exporter (per-node CPU/RAM/disk).
- **Alloy** (one pod) tails every container's logs **through the Kubernetes API**, plus cluster events
  (`OOMKilling`, `BackOff`, `Unhealthy`, `FailedMount`, …), and pushes them to **Loki**.
- **Grafana** reads both. Prometheus and Alertmanager datasources come from the chart; Loki is added in
  `kube-prometheus-stack/values.yaml`.
- **bark-relay** is a ~60-line stdlib Python service (`kube-prometheus-stack/bark-relay.py`). Alertmanager's
  webhook body can't be templated and Bark only accepts its own JSON, so something has to translate.

Everything stateful is pinned to the 32GB worker (`immich-node: "true"`). node-exporter is a DaemonSet
(both nodes).

---

## First-time setup

### 0. Before the first Sync: leftovers from the August attempt
The old stack was cleaned up (`../runbooks/cluster-cleanup.md` §1), but check for stray **PVCs**. A
leftover local-path PVC with the same name would be reused, and it may sit on the **master**. The new
pods are pinned to the worker, so they would stay Pending forever.
```bash
sudo k3s kubectl -n monitoring get pvc        # expect only gatus-data and bark-data
```
Anything named `prometheus-*`, `storage-loki-*`, `alertmanager-*` or `kube-prometheus-stack-grafana`: delete it.

### 1. DNS
Cloudflare → `grafana` → A → the master's Tailscale IP, **grey cloud**.

### 2. The secret (in OpenBao, `homelab/grafana`)
From any machine logged in to OpenBao (`bao login -method=userpass username=william`):
```bash
bao kv patch homelab/grafana admin-password="$(openssl rand -base64 24)"   # patch, not put — put replaces ALL keys
bao kv get -field=admin-password homelab/grafana                            # note it for the first login
sudo k3s kubectl -n monitoring annotate externalsecret kube-prometheus-stack-secret force-sync=$(date +%s) --overwrite
```
External Secrets copies it into `kube-prometheus-stack-secret` (within 1h, or right away with the annotate).
See [`../platform/openbao.md`](../platform/openbao.md).
⚠️ Grafana reads this only on its **first** start. After that the password lives in Grafana's database:
change it under *profile → Change password*. Editing the secret later does nothing.

### 3. Bark device key
`kube-prometheus-stack/bark-relay.yaml` carries the same `REPLACE_ME_DEVICE_KEY` placeholder as Gatus and
Argo notifications (testing stance, see `../platform/secrets.md`). Replace all three together.

### 4. Re-apply the ApplicationSet (once)
The Prometheus Operator's CRDs are too big for client-side apply, so `kube-prometheus-stack` gets
`ServerSideApply=true`, the same exception cert-manager has. That option lives in the ApplicationSet's
`templatePatch`, which is **not** reconciled from git:
```bash
sudo k3s kubectl apply -f kubernetes/bootstrap/apps.yaml
```

### 5. Push, then Sync in this order
1. **kube-prometheus-stack**: CRDs, operator, Prometheus, Alertmanager, Grafana, bark-relay. It takes a
   minute: cert-manager must issue the operator's webhook cert before the operator turns Ready.
2. **loki**
3. **alloy**: within a minute, logs appear in Grafana → *Dashboards → App logs*.

### 6. Prove the alert path end to end
Send a fake alert straight into Alertmanager and watch your phone:
```bash
sudo k3s kubectl -n monitoring run amtest --rm -i --restart=Never --image=curlimages/curl:8.23.0 -- \
  curl -s -XPOST http://kube-prometheus-stack-alertmanager:9093/api/v2/alerts -H 'Content-Type: application/json' -d \
  '[{"labels":{"alertname":"TestAlert","namespace":"apps","severity":"warning"},"annotations":{"summary":"Test from docs/apps/grafana.md"}}]'
```
About a minute later (`group_wait`) you should get **🔴 TestAlert**. Five minutes after that, the alert
expires and you get **🟢 TestAlert resolved**. Nothing arrives? See Troubleshooting.

---

## Using it

| You want | Go to |
|---|---|
| **what each app uses** | Dashboards → *Kubernetes / Compute Resources / Namespace (Pods)* → namespace `apps` or `media` |
| one pod's CPU/memory vs its limit | *Kubernetes / Compute Resources / Pod* |
| node CPU/RAM/disk | *Node Exporter / Nodes* |
| **an app's logs**, incl. before a restart | Dashboards → *App logs* → pick namespace + app (and a regex search) |
| why a pod died | *App logs* → the **Kubernetes events** panel (OOMKilling, BackOff, Unhealthy) |
| ad-hoc log search | Explore → Loki → `{namespace="apps", app="karakeep"} \|= "error"` |
| what's firing now / history | Alerting → *Alert groups* (the Bark notifications link here) |
| silence a noisy alert for a while | Alerting → Silences → New (choose the Alertmanager datasource) |

Log labels: `namespace`, `app` (this repo's `app:` label, or `app.kubernetes.io/name` for charts),
`pod`, `container`, `node`. Events have `job="kubernetes-events"`.

---

## What pages you

The chart's default Kubernetes rules, minus the ones that make no sense on k3s or on two nodes, plus
two homelab rules in `kube-prometheus-stack/rules.yaml`:

| Alert | Fires when | Severity → Bark level |
|---|---|---|
| `KubePodCrashLooping` | CrashLoopBackOff for 15 min | warning → active |
| `KubePodNotReady` | a pod not Ready for 15 min (e.g. a sidecar failing its probe) | warning → active |
| `KubeDeploymentReplicasMismatch` / `KubeStatefulSetReplicasMismatch` | fewer ready replicas than wanted, 15 min | warning → active |
| `KubeContainerWaiting` | stuck in ContainerCreating / CreateContainerConfigError for 1h | warning → active |
| `KubePersistentVolumeFillingUp` | a PVC is about to fill up | warning/critical |
| `NodeFilesystemSpaceFillingUp`, `NodeMemoryHighUtilization`, … | node trouble | warning/critical |
| **`ContainerOOMKilled`** (homelab) | restarted in the last 10 min, last reason OOMKilled | warning → active |
| **`ContainerRestarting`** (homelab) | ≥3 restarts in 30 min, even if it recovers | warning → active |

Routing, in `kube-prometheus-stack/values.yaml` → `alertmanager.config`:
- One push per **alertname per namespace**: five Karakeep pods crash-looping is one notification
  (`🔴 KubePodCrashLooping ×5`), not five.
- `critical` → `timeSensitive` (breaks through Focus). `warning` → `active`. Resolved → `passive` (silent).
- `info`/`none` severities (e.g. `CPUThrottlingHigh`) and the always-firing `Watchdog` → dropped. They're
  visible in Grafana, never pushed.
- Still broken? It re-pings every **12h**, not every 5 min.

Turned off on purpose: control-plane scraping and rules (k3s runs them in one process, so they would
only ever show "down"), and `KubeCPUOvercommit`/`KubeMemoryOvercommit` (with two nodes, losing the big one
is never survivable, and that's a known trade-off, not news).

**Adding a rule**: append to `rules.yaml` → push → Sync. The operator's webhook rejects invalid PromQL
at Sync time, so a typo fails loudly instead of being silently skipped.

---

## Upgrades

Renovate sees:
- the three **chart** versions (each `kustomization.yaml`)
- the **Grafana**, **Loki** and **Alloy** image tags in the values files. Those charts' default app
  versions lag behind releases, so they are pinned the way Immich's is.

Prometheus, Alertmanager, the operator, kube-state-metrics and node-exporter are **not** pinned
separately. They ride with the kube-prometheus-stack chart, because the operator and its CRDs are
released together with them. Read the chart's release notes on major bumps: CRD changes are the usual
breaking point, and ServerSideApply handles applying them.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `kube-prometheus-stack` Sync fails: `metadata.annotations: Too long` | the ApplicationSet wasn't re-applied, so ServerSideApply isn't on (setup step 4) |
| Prometheus / Loki / Grafana pod Pending | a leftover PVC bound on the master (setup step 0), or the worker is out of memory: `kubectl describe pod` |
| Operator not Ready, webhook errors at Sync | cert-manager hasn't issued `kube-prometheus-stack-admission` yet: `kubectl -n monitoring get certificate` |
| Grafana login refused | the password is set on **first** start only. Reset: `kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- grafana cli admin reset-admin-password '<new>'` (distroless image: if `grafana` isn't on PATH, try `/usr/share/grafana/bin/grafana`) |
| *App logs* dashboard empty | Alloy not synced/Ready, or Loki not Ready: `kubectl -n monitoring logs deploy/alloy` (look for push errors to `loki:3100`) |
| Test alert never reaches the phone | `kubectl -n monitoring logs deploy/bark-relay`: `pushed: …` means Bark got it (so check the device key); `push failed` gives the reason; nothing means Alertmanager never called, so check its logs |
| A firing alert you don't care about | silence it (Alerting → Silences) or, for good, add it to `defaultRules.disabled` in values.yaml |
| Prometheus target "down" in the Homepage widget | Grafana → Explore → Prometheus → `up == 0` names it |

## Quick reference

```bash
alias k='sudo k3s kubectl'
k -n monitoring get pods                                   # everything in the stack + gatus + bark
k -n monitoring logs deploy/bark-relay --tail=20           # did alerts reach Bark?
k -n monitoring logs deploy/alloy --tail=50                # is log shipping healthy?
k -n monitoring get prometheusrules                        # rule sets Prometheus loads
k -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090   # raw Prometheus UI (Status → Targets)
```
