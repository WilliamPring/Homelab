# Adding an app — the onboarding checklist

How every app in `kubernetes/apps/` was added. Follow it top to bottom; each step says *why* it exists.
Reference app to copy from: **`kubernetes/apps/media/komf/`** (raw manifests + a SOPS secret + a doc).
A blank skeleton lives in **`kubernetes/templates/app/`**.

```
decide ──► write the directory ──► validate locally ──► push ──► Argo registers it ──► DNS ──► Sync ──► verify ──► wire-ups
```

---

## 0. Decide four things first

| Question | Options | Why it matters |
|---|---|---|
| **Namespace** | `media` (content), `apps` (tools), `monitoring`, `notifications`, `cert-manager` | the directory path *is* the namespace: `kubernetes/apps/<namespace>/<app>/` |
| **State** | NFS (precious: files you can't recreate) · local-path (rebuildable: caches, indexes, thumbnails) · external DB (Postgres LXC `.7`, Valkey `.103`) | NFS survives a cluster rebuild, local-path does not, external DBs survive everything |
| **Who reaches it** | Tailscale devices (Ingress + hostname) · LAN devices (NodePort too) · the internet (**no** — only the Immich share proxy is public) | decides `ingress.yaml` and whether `service.yaml` gets a `nodePort` |
| **Secrets** | none · SOPS-encrypted (`<app>-secret.enc.yaml`) · (while testing: inline, flagged in `secrets.md` debt) | decides whether `kustomization.yaml` has a `generators:` block |

Pick a **hostname**: `<app>.williampring.ca` (existing ones: library, books, roms, suwayomi, komf, status,
search, private, home, immich, argocd, ntfy, qbittorrent, karakeep, actual). Pick a **NodePort** if LAN access is wanted: a free `30xxx`
from the README's Addresses table.

## 1. Create the directory

```
kubernetes/apps/<namespace>/<app>/
├── kustomization.yaml     ← REQUIRED. Lists the files; `generators:` only if there is a secret.
├── deployment.yaml        ← pinned image, env, probes, resources, volumeMounts, nodeSelector if heavy
├── service.yaml           ← ClusterIP (+ nodePort when LAN access is wanted)
├── ingress.yaml           ← Traefik + cert-manager annotation (omit only if something else fronts it, e.g. Bark/NPMplus)
├── storage.yaml           ← PV/PVC for NFS, PVC for local-path (omit if stateless)
├── configmap.yaml         ← app config files, if any
├── <app>-secret.enc.yaml  ← SOPS-encrypted Secret (if any)       ─┐ see platform/secrets.md §5
└── <app>-secret.sops.yaml ← the KSOPS generator pointing at it    ─┘
```
Start from the skeleton: `cp -r kubernetes/templates/app kubernetes/apps/<namespace>/<app>` and replace every
`example` and `EXAMPLE`. Or copy a similar real app.

**Helm chart instead of raw manifests?** The directory is still a kustomization:
```yaml
helmCharts:
  - name: <chart>
    repo: https://charts.example.org      # or oci://registry/path  (chart name NOT in the path)
    version: 1.2.3                        # pinned → Renovate's kustomize manager bumps it
    releaseName: <app>                    # = app name, so object names stay predictable
    namespace: <namespace>
    valuesFile: values.yaml
```
(see `kubernetes/apps/media/immich/`). Argo renders it with `--enable-helm`; the CI script does the same.

## 2. The conventions inside the files (and why)

| In | Rule | Why |
|---|---|---|
| `deployment.yaml` | `image: repo/name:X.Y.Z` — **never `latest`** | Renovate can only bump a number; `latest` also makes rollbacks impossible |
| | `resources.requests` + `limits.memory` | one runaway app can't starve Immich on the shared worker |
| | readiness + liveness probes | Argo health and Gatus both rely on the pod being honestly Ready |
| | `nodeSelector: immich-node: "true"` for heavy apps | the 32GB worker is where the RAM is; the master is small |
| | run as uid 1000 (`securityContext` or the image's PUID/PGID) when it writes to NFS | every folder under `/data` is owned 1000:1000 |
| | `strategy: Recreate` when it has an RWO volume | a RollingUpdate would try to mount the same local-path volume twice |
| `service.yaml` | `type: NodePort` only if LAN devices need it; pick a free port | NodePorts are cluster-wide; collisions make Argo sync fail ("already allocated") |
| `ingress.yaml` | `ingressClassName: traefik`, `cert-manager.io/cluster-issuer: letsencrypt`, `tls.secretName: <app>-tls` | one pattern → one place to debug TLS (`platform/tls.md`) |
| `storage.yaml` | NFS: static `PersistentVolume` (`Retain`) + `PersistentVolumeClaim` with `volumeName`, `storageClassName: ""` | binding by name = predictable; Retain = deleting the claim never deletes files |
| | local-path PVC: `storageClassName: local-path`, RWO | node disk, fast, disposable |
| secrets | `<app>-secret.enc.yaml` encrypted with `sops -e -i`; referenced via `secretKeyRef` | a value is either `ENC[...]` in git or not in git |
| everywhere | a header comment: what the app is, where data lives, what to do before syncing | the next reader is you in six months |

## 3. Validate locally — before pushing

```bash
make validate          # renders every app exactly like Argo will (kustomize + helm + KSOPS stripped) + kubeconform
make lint              # yamllint
make render APP=kubernetes/apps/<namespace>/<app>     # eyeball the rendered objects
```
CI runs the same on the PR/push. Green here = Argo will render it.

## 4. Push → Argo registers it

The ApplicationSet (`kubernetes/bootstrap/apps.yaml`) watches `kubernetes/apps/*/*`. Within ~3 minutes:
```bash
sudo k3s kubectl -n argocd get applications | grep <app>        # listed, OutOfSync, Missing
```
No `kubectl apply` of anything. The **push** is what triggers it — the generator reads the repo, not your
working tree — so an unpushed commit is the usual reason an app never shows up. To skip the poll:
```bash
sudo k3s kubectl annotate applicationset apps -n argocd \
  argocd.argoproj.io/application-set-refresh=true --overwrite
```
If the app needs a sync option the default lacks (e.g. `ServerSideApply` for huge CRDs), add a case to
`templatePatch` in `bootstrap/apps.yaml`. Details + "it didn't appear" checks: [`argocd.md`](argocd.md).

## 5. Things outside the cluster (do before Sync)

- **DNS**: Cloudflare → `<app>` → A → the master's Tailscale IP, **grey cloud** (DNS-only). Public = never,
  except through the Cloudflare tunnel pattern the Immich share proxy uses.
- **File server** (if NFS): `mkdir -p /data/<folder> && chown -R 1000:1000 /data/<folder> && chmod -R 775 /data/<folder>`
  on `192.168.68.50`. The export of `/data` already covers subfolders.
- **Database** (if any): a role + database on the Postgres LXC (`scripts/postgres-romm-setup.sh` is the
  template), a dedicated ACL user on Valkey (`platform/redis.md`). Passwords → the app's SOPS secret.
- **Secrets**: fill the template, `sops -e -i`, verify with `sops -d … >/dev/null` (`platform/secrets.md` §3).

## 6. Sync and verify

Argo UI → `<app>` → read the diff (it is the whole app the first time) → **Sync**, nothing ticked.
```bash
sudo k3s kubectl get pods -n <namespace> -l app=<app> -w          # Running, Ready
sudo k3s kubectl get certificate -n <namespace> <app>-tls           # READY True (1–2 min)
sudo k3s kubectl logs -n <namespace> deploy/<app> --tail=50
curl -sI https://<app>.williampring.ca | head -1                    # from a Tailscale device
```
Your phone gets "<app>: deployed" (Argo → Bark/ntfy).

## 7. Wire it into the rest (same push or the next)

| Wire-up | Where | Why |
|---|---|---|
| **Homepage tile** | `kubernetes/apps/apps/homepage/configmap.yaml` → `services.yaml` block; icon names from the dashboard-icons set | the front door lists everything |
| **Gatus check** | `kubernetes/apps/monitoring/gatus/configmap.yaml` → an `apps` endpoint (in-cluster Service URL) and an `edge` endpoint (the hostname, with cert-expiry) | you find out it is down before you need it |
| **Doc** | `docs/apps/<app>.md` — architecture, first-time setup, day-to-day, troubleshooting, quick reference (copy the shape of `apps/romm.md`) | the setup steps you'll forget |
| **README** | add the NodePort to the Addresses table if you added one; add the doc to `docs/index.md` | one place for ports and hostnames |
| **Renovate** | nothing — if the image/chart is pinned it is already tracked. Stateless app? add it to the `stateless patch updates` group in `renovate.json`. Runs migrations? add it to the `db-migration` rule | PRs arrive with the right label and grouping |

## 8. Removing an app

1. Delete the directory → push → the Application disappears from Argo (its resources stay).
2. Delete the live resources: `kubectl delete all,ingress,pvc,secret -n <ns> -l app=<app>` (check the label
   first), the TLS secret/certificate, the DNS record, the Homepage tile, the Gatus endpoints, the doc →
   `docs/archive/` if worth keeping.
3. Precious data on NFS / external DBs is yours to delete separately — nothing in step 1–2 touches it.
→ `runbooks/cluster-cleanup.md` is the pattern.

---

## Worked example: how Komf was added (the smallest complete app)
1. Decided: namespace `media`, state = local-path (its DB is a cache), reached over Tailscale only, one secret
   (Kavita API key).
2. Wrote `kubernetes/apps/media/komf/`: `deployment.yaml` (pinned `sndxr/komf`, seed-config init container,
   probes, 1Gi limit), `pvc.yaml`, `configmap.yaml` (its `application.yml`), `service.yaml` (ClusterIP),
   `ingress.yaml` (`komf.williampring.ca`), `komf-secret.enc.yaml` + `komf-secret.sops.yaml`,
   `kustomization.yaml` with `generators:`.
3. `make validate` green → push → appeared in Argo as `komf` in `media`.
4. DNS record `komf` → Tailscale IP. Secret filled + encrypted (still a placeholder today — see secrets debt).
5. Sync → pod Ready → cert issued → opened the UI.
6. Wired: Gatus endpoint `Komf`, doc section in `apps/kavita.md`, no Homepage tile (no UI of its own).
