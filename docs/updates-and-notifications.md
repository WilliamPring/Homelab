# Updates & notifications — how the homelab tells you what changed

Two systems, one phone:

```
upstream release ──► Renovate (Monday 9am, or any time for security)
                        │  PRs on GitHub ─── stateless patch/digest bumps → ONE grouped PR
                        │                └── everything else → its own PR
                        ▼  you read the changelog, you merge
                    main branch moved
                        │
                        ▼
                    Argo CD sees OutOfSync ──► ntfy: "<app>: update waiting"   ◄── you click Sync when ready
                        │
                        ▼  (after Sync)
                    ntfy: "deployed"  |  "SYNC FAILED"  |  "DEGRADED"
```

**Nothing merges or deploys by itself.** Renovate never automerges here — every change to `main`
is a PR you read and merge. Argo's sync policy is manual everywhere, so the cluster changes only
when you press Sync. The notifications exist so you *know* something is waiting, instead of
discovering it a month later.

---

## Renovate (`renovate.json`)

| Setting | Value | Why |
|---|---|---|
| Schedule | Monday before 9am (Vancouver) | one batch of PRs a week |
| `minimumReleaseAge` | 3 days | skip releases that get yanked/hot-fixed within days |
| Security (OSV) alerts | any time, label `security`, no release-age wait | CVE fixes don't wait for Monday |
| Dependency Dashboard | GitHub issue "🤖 Renovate Dependency Dashboard" | one place to see everything pending |

### What Renovate can see
Only **pinned** versions. Everything is now pinned:

| Where | How Renovate tracks it |
|---|---|
| `image:` tags in `gitops/**` Deployments | `kubernetes` manager |
| `targetRevision` of the three Helm charts (`immich`, `vaultwarden`, `ntfy`) | `argocd` manager |
| Immich **app** version in `gitops/immich/values.yaml` (`image.tag`) | custom regex manager → `ghcr.io/immich-app/immich-server` |
| SearXNG (date-stamped tags, no semver) | pinned to `latest@sha256:…` → **digest** updates |

If you ever add an app with `:latest` or a chart with `targetRevision: "*"`, Renovate is blind to
it. Pin it.

### How PRs are shaped (no automerge, by decision)
| Group | Behaviour | Label |
|---|---|---|
| homepage, searxng, degoog, komf, ntfy chart, busybox — **patch + digest** | **one grouped PR** "stateless patch updates" — a single thing to read on Monday | `low-risk` |
| the same apps — minor/major | own PR | |
| immich (chart, app, postgres), vaultwarden, romm, kavita, calibre | own PR — read the release notes, back up, then merge | `⚠️ db-migration` |
| anything in `gitops/argocd/**` | own PR — merge, then re-apply `gitops/argocd/` by hand | `argocd` |
| any major bump | own PR | `⚠️ major` |

Why not automerge: Argo sync is manual, so automerge would never have saved a deploy decision,
only a merge click — and it removes the one moment where you actually read what changed. The
grouped PR keeps review cheap instead.

### Why a Renovate PR might be missing
- Version is not pinned (see above).
- Release is younger than 3 days.
- The dashboard issue shows it under "Pending" / "Rate-limited" / "Errored" — open it.
- Chart lookup error for ntfy → the `overridePackageName` rule in `renovate.json` must still
  match the depName Renovate computes (`codeberg.org/wrenix/helm-charts/ntfy/ntfy`).

---

## Argo CD → ntfy (`gitops/argocd/argocd-notifications-cm.yaml`)

The notifications-controller ships with Argo; the ConfigMap patch tells it what to send.
Every Application is subscribed by default — no annotations to maintain.

| Event | Trigger | Priority | Means |
|---|---|---|---|
| `on-out-of-sync` | sync status OutOfSync, once per git revision | 3 | **an update is waiting for your click** |
| `on-deployed` | sync Succeeded + Healthy, once per synced revision | 3 | the Sync you clicked worked |
| `on-sync-failed` | operation phase Error/Failed | 5 🚨 | bad manifest, KSOPS decrypt, missing secret, image pull |
| `on-health-degraded` | health Degraded | 5 ⚠️ | crash-loop / failing probes |

Each notification's tap-target opens the app in Argo (`argocd.williampring.ca`).

### Setup
1. Push, then re-apply the Argo kustomization (`-k`, not `-f`: the directory has patches; `-n argocd`
   because the upstream install objects carry no namespace):
   ```bash
   sudo k3s kubectl apply -k gitops/argocd/ -n argocd
   sudo k3s kubectl -n argocd rollout restart deploy/argocd-notifications-controller
   sudo k3s kubectl -n argocd get cm argocd-notifications-cm -o jsonpath='{.data.subscriptions}'   # shows the 4 triggers
   ```
   (`docs/argocd.md` still says `apply -f gitops/argocd/` — that predates the kustomization + KSOPS patch.)
2. On your phone, ntfy app → **+** → server `https://ntfy.williampring.ca` → topic
   `homelab-argocd`.
3. Prove the path works end-to-end without waiting for a real event:
   ```bash
   # 1) can the cluster reach ntfy? (plain publish)
   sudo k3s kubectl -n argocd exec deploy/argocd-notifications-controller -- \
     wget -qO- --post-data='{"topic":"homelab-argocd","title":"test","message":"hello from the cluster"}' \
     http://ntfy.notifications.svc.cluster.local:80/
   # 2) render + send a real template for an app
   sudo k3s kubectl -n argocd exec deploy/argocd-notifications-controller -- \
     argocd-notifications template notify app-deployed kavita --recipient ntfy
   ```
4. Then merge any Renovate PR → within ~3 min your phone should say "<app>: update waiting".

### Adding a token later (when ntfy gets locked down)
```bash
# on the ntfy pod / host:
ntfy user add argocd && ntfy access argocd homelab-argocd wo && ntfy token add argocd
# put it in the controller's secret:
sudo k3s kubectl -n argocd patch secret argocd-notifications-secret -p '{"stringData":{"ntfy-token":"tk_..."}}'
```
and un-comment the `Authorization` header in the ConfigMap. (Better: move that secret to SOPS
like the others — `docs/secrets.md`.)

### Troubleshooting
| Symptom | Check |
|---|---|
| Nothing ever arrives | `kubectl -n argocd logs deploy/argocd-notifications-controller` — template parse errors show here on start |
| `failed to send ... connection refused` | ntfy Service name/namespace: `kubectl get svc -n notifications` |
| Arrives once, never again for the same app | that's `oncePer` working — the state didn't change |
| Too chatty on `on-deployed` | remove it from `subscriptions:` in the ConfigMap |
| Template error about `trunc` | Sprig funcs are built in; check the quote/brace balance in the JSON body |

---

## CI guard (`.github/workflows/validate.yaml` → `scripts/ci/validate.sh`)

Runs on every pull request (Renovate's too) and on pushes to `main`. It is a gate, not a
deploy — nothing touches the cluster. Same script runs locally:
```bash
./scripts/ci/validate.sh          # needs kubectl, helm, ruby, kubeconform on PATH
```

| # | Check | Catches |
|---|---|---|
| 1 | every `*.enc.yaml` has a `sops:` block, all values `ENC[…]`, no `REPLACE_ME` — **WARN-only for now** (`STRICT_SECRETS: "0"` in the workflow) | a plaintext secret template reaching `main` |
| 2 | every directory with a `kustomization.yaml` renders (KSOPS generator stripped) | bad patch targets, typos, missing resources — the Argo "manifest generation error" class |
| 3 | every plain manifest directory is valid YAML with k8s objects | broken indentation |
| 4 | every Argo Application with a chart source renders via `helm template` with its values | chart values-schema errors (immich enforces one), wrong chart version |
| 5 | kubeconform over everything rendered, with the CRD catalog for Argo / cert-manager | wrong field names that render fine but the API server rejects |

A second job validates `renovate.json` itself with Renovate's own config validator.

What it cannot do: decrypt anything (no age key in CI), or prove a secret's *value* is right.
It does not block merges unless you make it a required check in GitHub branch protection —
worth doing once it has been green for a while.

**Secrets check is warn-only today** because `komf-secret.enc.yaml` and `romm-secret.enc.yaml`
are still plaintext templates. Once you fill + `sops -e -i` them (`docs/secrets.md` §3), set
`STRICT_SECRETS: "1"` in the workflow so a plaintext secret can never merge again.

---

## Not automated (on purpose, for now)
- **k3s upgrades** — needs system-upgrade-controller; declined for now.
- **ntfy access control** — still open to anyone on the tailnet; also the `base-url` in
  `gitops/ntfy/values.yaml` sits under the wrong key (`config:` instead of `ntfy:`), so the
  server still thinks it is `ntfy.example.org`. Declined for now; one-line fix when you want it.
- **Metrics alerts (Alertmanager)** — the monitoring stack was removed. If it comes back, ntfy
  has a built-in Alertmanager template (`?template=alertmanager`).
