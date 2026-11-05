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
                    Argo CD sees OutOfSync ──► Bark: "<app>: update waiting"   ◄── you click Sync when ready
                        │
                        ▼  (after Sync)
                    Bark: "deployed"  |  "SYNC FAILED"  |  "DEGRADED"
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
| `image:` tags in `kubernetes/**` Deployments | `kubernetes` manager |
| `targetRevision` of the Helm charts (`immich`, `cert-manager`) | `argocd` manager — cert-manager gets one PR per minor (`step-by-minor`), merge in order |
| Immich **app** version in `kubernetes/apps/media/immich/values.yaml` (`image.tag`) | custom regex manager → `ghcr.io/immich-app/immich-server` |
| SearXNG (date-stamped tags, no semver) | pinned to `latest@sha256:…` → **digest** updates |

If you ever add an app with `:latest` or a chart with `targetRevision: "*"`, Renovate is blind to
it. Pin it.

### How PRs are shaped (no automerge, by decision)
| Group | Behaviour | Label |
|---|---|---|
| homepage, searxng, degoog, komf, busybox — **patch + digest** | **one grouped PR** "stateless patch updates" — a single thing to read on Monday | `low-risk` |
| the same apps — minor/major | own PR | |
| immich (chart, app, postgres), romm, kavita, calibre | own PR — read the release notes, back up, then merge | `⚠️ db-migration` |
| anything in `kubernetes/bootstrap/argocd/**` | own PR — merge, then re-apply `kubernetes/bootstrap/argocd/` by hand | `argocd` |
| any major bump | own PR | `⚠️ major` |

Why not automerge: Argo sync is manual, so automerge would never have saved a deploy decision,
only a merge click — and it removes the one moment where you actually read what changed. The
grouped PR keeps review cheap instead.

### Why a Renovate PR might be missing
- Version is not pinned (see above).
- Release is younger than 3 days.
- The dashboard issue shows it under "Pending" / "Rate-limited" / "Errored" — open it.

---

## Argo CD → Bark (`kubernetes/bootstrap/argocd/argocd-notifications-cm.yaml`)

The notifications-controller ships with Argo; the ConfigMap patch tells it what to send.
Every Application is subscribed by default — no annotations to maintain.

| Event | Trigger | Bark level | Means |
|---|---|---|---|
| `on-out-of-sync` | sync status OutOfSync, once per git revision | 3 | **an update is waiting for your click** |
| `on-deployed` | sync Succeeded + Healthy, once per synced revision | 3 | the Sync you clicked worked |
| `on-sync-failed` | operation phase Error/Failed | 5 🚨 | bad manifest, KSOPS decrypt, missing secret, image pull |
| `on-health-degraded` | health Degraded | 5 ⚠️ | crash-loop / failing probes |

Each notification's tap-target opens the app in Argo (`https://deploy.williampring.ca`, set as
`argocdUrl` in `argocd-notifications-cm.yaml`). It is the public hostname on purpose: a phone on
cellular cannot reach a `192.168.68.x` NodePort, so a LAN address there would make every alert
you tap from outside the house go nowhere. Gatus watches that hostname (`edge` group) — if the
front door breaks, the tap-targets break with it.

### Setup
1. Push, then re-apply the Argo kustomization (`-k`, not `-f`: the directory has patches; `-n argocd`
   because the upstream install objects carry no namespace):
   ```bash
   sudo k3s kubectl apply -k kubernetes/bootstrap/argocd/ -n argocd
   sudo k3s kubectl -n argocd rollout restart deploy/argocd-notifications-controller
   sudo k3s kubectl -n argocd get cm argocd-notifications-cm -o jsonpath='{.data.subscriptions}'   # shows the 4 triggers
   ```
   (`docs/platform/argocd.md` still says `apply -f kubernetes/bootstrap/argocd/` — that predates the kustomization + KSOPS patch.)
2. On your phone, make sure the Bark app is registered against this server and that
   `barkDeviceKey` in the ConfigMap matches its device key (`docs/apps/bark.md` §3).
3. Prove the path works end-to-end without waiting for a real event:
   ```bash
   # 1) can the cluster reach Bark? (direct push)
   sudo k3s kubectl -n argocd exec deploy/argocd-notifications-controller -- \
     wget -qO- --post-data='{"device_key":"<KEY>","title":"test","body":"hello from the cluster"}' \
     --header='Content-Type: application/json' \
     http://bark.monitoring.svc.cluster.local:8080/push
   # 2) render + send a real template for an app
   sudo k3s kubectl -n argocd exec deploy/argocd-notifications-controller -- \
     argocd-notifications template notify app-deployed kavita --recipient bark
   ```
4. Then merge any Renovate PR → within ~3 min your phone should say "<app>: update waiting".

### Troubleshooting
| Symptom | Check |
|---|---|
| Nothing ever arrives | `kubectl -n argocd logs deploy/argocd-notifications-controller` — template parse errors show here on start |
| `failed to send ... connection refused` | Bark Service name/namespace: `kubectl get svc -n monitoring bark` |
| Arrives once, never again for the same app | that's `oncePer` working — the state didn't change |
| Too chatty on `on-deployed` | remove it from `subscriptions:` in the ConfigMap |
| Template error about `trunc` | Sprig funcs are built in; check the quote/brace balance in the JSON body |

---

## CI guard

Every PR (Renovate's too) and every push to `main` runs the gate: manifests render and
schema-check, this repo's own conventions hold, yamllint passes, `renovate.json` parses — plus a
`render-diff` comment showing what the change does to the *cluster* rather than to the files.

Locally it is one command:
```bash
make check          # lint + validate + conventions
```

**Full details, including the conventions check and why `main` is not yet protected:
[`ci.md`](ci.md).**

**Secrets check is warn-only today** because the komf / romm / qbittorrent templates are still
plaintext. Once you fill + `sops -e -i` them (`docs/platform/secrets.md` §3), set
`STRICT_SECRETS: "1"` in the workflow so a plaintext secret can never merge again.

---

## Uptime alerts (Gatus → Bark)
Argo's pushes tell you about *deploys*; **Gatus** (`docs/apps/gatus.md`) tells you about *outages*:
every app's in-cluster URL, every public hostname (incl. cert expiry), the Postgres/Valkey/NFS
boxes and the Cloudflare DNS records, on a 1–5 min cycle. Both senders push to **Bark**, which
groups them: `argocd` = you did something; `homelab` = something broke.

**Oct 2026: Bark is the only channel.** ntfy was retired — its iOS app had to *fetch* from the
Tailscale-only server, so pushes were lost whenever Tailscale slept. Bark goes through Apple's APNs
instead. See `docs/apps/bark.md`, including the one gap this leaves: nothing can page you about
Bark itself being down.

---

## Proxmox → Bark (the layer below the cluster)

Argo and Gatus both run *inside* k3s, so neither can tell you the cluster itself is gone — the
night the master VM died, nothing pushed, because everything that could push died with it.
Proxmox sits underneath and is the only thing positioned to report that class of failure.

Proxmox VE has a built-in notification system with a **webhook** target type, so it talks to Bark
directly — no extra software on the host.

### What Proxmox will and won't tell you

Its built-in events are a fixed list:

| Event | `fields.type` | Severity |
|---|---|---|
| Backup failed | `vzdump` | error |
| Backup succeeded | `vzdump` | info |
| Cluster node fenced | `fencing` | error |
| Storage replication job failed | `replication` | error |
| System updates available | `package-updates` | info |
| Mail for root (smartd, mdadm, cron…) | `system-mail` | unknown |

⚠️ **"A VM stopped" is not on that list.** Proxmox does not emit a notification when a guest dies,
so this configuration alone would *not* have caught the master going down. That needs the cron
check at the end of this section. Set up the webhook first — it's the foundation both parts use.

### 1. Create two targets (Datacenter → Notifications → Add → Webhook)

Two targets, not one, for the same reason Argo has two levels: a failed backup should feel
different from "updates available".

| Field | `bark-proxmox` | `bark-proxmox-urgent` |
|---|---|---|
| Method | `POST` | `POST` |
| URL | `http://192.168.68.62:30889/push` | same |
| Header | `Content-Type` = `application/json` | same |
| Secret | name `device_key`, value = your Bark key | same |

Body (the only difference is `level`):

```json
{
  "device_key": "{{ secrets.device_key }}",
  "title": "Proxmox: {{ escape title }}",
  "body": "{{ escape message }}",
  "level": "active",
  "group": "proxmox"
}
```

…and `"level": "timeSensitive"` in the urgent one.

Templating is Handlebars. `{{ escape … }}` is required on anything free-form — Proxmox messages
contain newlines and quotes, and an unescaped backup log breaks the JSON so Bark rejects the whole
push. Available: `title`, `message`, `severity`, `timestamp`, `fields.<name>`, `secrets.<name>`;
helpers `escape`, `url-encode`, `json`.

**The device key belongs in `Secret`, not pasted into the body.** Proxmox stores secrets in a
root-only file and masks them in the UI and API; the body is world-readable config. This is the one
place the key gets better handling than it does in this repo (still inline — see `docs/apps/bark.md`).

### 2. Route them (Notifications → Matchers → Add)

| Matcher | Rule | Target |
|---|---|---|
| `bark-urgent` | Match Severity: `warning`, `error` | `bark-proxmox-urgent` |
| `bark-normal` | Match Severity: `info`, `notice` | `bark-proxmox` |

Leave the shipped `default-matcher` (→ `mail-to-root`) alone at first, so you keep the old path
while you confirm pushes arrive. Disable it once you trust Bark. Each target fires at most once per
notification even when several matchers select it.

### 3. Test

```bash
# On the Proxmox host — the test button in the GUI does the same thing
pvesh create /cluster/notifications/endpoints/webhook/bark-proxmox/test
```
Phone buzzes. If it doesn't, `journalctl -u pvescheduler -n 50` on the host shows the HTTP result.

### ⚠️ Bark lives in the cluster

The circular bit: Bark is a pod in k3s, so Proxmox can only reach it while k3s is serving. If the
**master** dies, a push from Proxmox still works *provided the Bark pod is on a worker* — kube-proxy
and the running pod survive the control plane. If Bark happened to be scheduled on the master, it
dies too and you get nothing.

Worth pinning it so that is not left to chance:
```yaml
# kubernetes/apps/monitoring/bark/deployment.yaml → under spec.template.spec
nodeSelector:
  immich-node: "true"      # the worker, so Bark outlives a master failure
```

### 4. The master-down check (what the webhook can't do)

A cron on the Proxmox host, since nothing inside the cluster can report the cluster being gone:

```bash
# /usr/local/bin/check-k3s-master.sh   (chmod +x; crontab: */5 * * * *)
#!/bin/bash
KEY=$(cat /root/.bark-key)             # chmod 600
STAMP=/run/k3s-master-alerted
if ping -c2 -W3 192.168.68.63 >/dev/null 2>&1; then
  [ -f "$STAMP" ] && rm -f "$STAMP"    # recovered — reset so the next outage alerts
  exit 0
fi
[ -f "$STAMP" ] && exit 0              # already alerted; don't repeat every 5 min
touch "$STAMP"
curl -s -X POST http://192.168.68.62:30889/push -H 'Content-Type: application/json' \
  -d "{\"device_key\":\"$KEY\",\"title\":\"k3s master DOWN\",\"body\":\"192.168.68.63 not responding to ping from Proxmox.\",\"level\":\"timeSensitive\",\"group\":\"homelab\"}"
```

The stamp file is the whole point — without it a weekend outage sends ~576 notifications and you
learn to ignore the group. Same idea as Argo's `oncePer`.

---

## Not automated (on purpose, for now)
- **k3s upgrades** — needs system-upgrade-controller; declined for now.
- **A second alert channel** — Bark cannot report its own outage, so that one endpoint is
  dashboard-only. An external check (Healthchecks.io / Uptime Robot hitting `/ping`) would close
  the gap. Declined for now; the Gatus dashboard covers it in practice.
- ~~**Metrics/history (Prometheus + Grafana)**~~ — back since Nov 2026, to answer "what is each
  app using, and why did it die?" Alertmanager is a third sender into Bark: `apps/grafana.md`.
