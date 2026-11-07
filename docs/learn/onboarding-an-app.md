# Onboard an app — a guided lab

Learn how an app gets from a directory in this repo to a URL on your phone by doing it once, slowly, with a
throwaway app. Every step says what to run, what you should see, and what just happened.

| Use | When |
|---|---|
| **this guide** | learning it — once, start to finish (about 45 minutes) |
| [`platform/adding-an-app.md`](../platform/adding-an-app.md) | every real app after that — the checklist |
| [`archive/deploy-ghostfolio.md`](../archive/deploy-ghostfolio.md) | a real app with a database, secrets and DNS, end to end |

---

## 0. Before you start

**Tools on your laptop** (macOS shown; Arch has the same packages):
```bash
brew install kubectl helm kubeconform yamllint pre-commit sops age
make hooks          # once per clone: cheap checks on commit, the full render on push
```
`make validate` needs `kubectl`, `helm`, `kubeconform` and `ruby`; `make lint` needs `yamllint`.

> ⚠️ If `make conventions` dies with `invalid multibyte character`, your shell has no UTF-8 locale and Ruby
> can't read the script's `—` characters. `export LANG=en_US.UTF-8` and run it again.

**Access:** SSH to the master (`ssh sysadmin@192.168.68.63`, then `sudo k3s kubectl …`), the Argo UI
(`https://deploy.williampring.ca`, or `http://192.168.68.63:30443` on the LAN), the Cloudflare dashboard for
`williampring.ca`, and Tailscale on the device you test from.

---

## 1. The mental model

An app lives in **four places**. Onboarding is making each one true, in this order:

```
 1  git       kubernetes/apps/<namespace>/<app>/      you write it                  (this repo)
 2  Argo      an Application called <app>              the ApplicationSet makes it   (after you push)
 3  cluster   Deployment · Service · Ingress · PVC …   Argo applies it               (when you click Sync)
 4  outside   DNS record · NFS folder · DB user ·      you, by hand                  (before Sync)
              Homepage tile · Gatus check · doc
```

A request then takes this path. Every arrow is something that has to be right:

```
phone (on Tailscale) ──DNS──► <app>.williampring.ca = the master's Tailscale IP
   ──► Traefik (k3s's built-in ingress controller): matches the Ingress host, serves the cert-manager cert
   ──► Service <app>: picks pods by the label `app: <app>` — and only pods that are READY
   ──► Pod: the container's port
```

Five ideas explain almost every rule in this repo:

| Idea | What it means here | What breaks if you ignore it |
|---|---|---|
| **The path is the config** | `kubernetes/apps/apps/whoami/` → Application `whoami` in namespace `apps` | a directory at the wrong depth is silently never deployed |
| **Nothing deploys by itself** | push = Argo *registers* the app; Sync = Argo *applies* it | — it's the safety rail: you always see the diff first |
| **Pin everything** | `image: name:1.2.3`, chart `version: 1.2.3` | `latest` is invisible to Renovate and can't be rolled back |
| **Labels tie it together** | `app: <app>` on every object; the Service finds pods by it | a wrong label = a Service with no pods = "no available server" |
| **Ready means ready** | a readiness probe decides when a pod gets traffic | with no probe the pod is "Healthy" the instant it starts, even mid-boot |

→ deeper: [`../index.md`](../index.md) §1–§4, [`../platform/argocd.md`](../platform/argocd.md)

---

## 2. The lab: onboard `whoami`

[`traefik/whoami`](https://github.com/traefik/whoami) is a tiny web server that prints back every request it
receives. No state, no secret, nothing to lose — you delete it at the end. It still passes through every layer a
real app does, which makes it the cheapest way to see them all.

### Step 1 — Answer the four questions

Every app starts here ([`adding-an-app.md`](../platform/adding-an-app.md) §0):

| Question | whoami | So… |
|---|---|---|
| Namespace | `apps` | it's a tool, not media |
| State | none | no `storage.yaml`, no NFS folder, no `strategy: Recreate` |
| Who reaches it | Tailscale devices, at `whoami.williampring.ca` | an Ingress; no NodePort (nothing on the LAN needs it) |
| Secrets | none | no `generators:` block |

### Step 2 — Write the directory

Start from the skeleton and drop what this app doesn't need:
```bash
cp -r kubernetes/templates/app kubernetes/apps/apps/whoami
cd kubernetes/apps/apps/whoami
rm storage.yaml README.md      # stateless; the README belongs to the template
```
Now make the four files look like this. Read the comments — they are the lesson.

**`kustomization.yaml`** — the list Argo renders. A file in the folder that isn't listed here is never applied:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

**`deployment.yaml`** — what to run, and how to tell it's working:
```yaml
# whoami — a tiny web server that echoes every request back. Lab app: no state, no secret.
#   data   → none (stateless)
#   before first Sync: DNS record whoami → the master's Tailscale IP, grey cloud
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: apps
  labels:
    app: whoami
spec:
  replicas: 1
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      automountServiceAccountToken: false   # it never talks to the Kubernetes API
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534                    # "nobody": it owns no files, so it doesn't need 1000
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: whoami
          image: traefik/whoami:v1.12.0     # PINNED — Renovate bumps it
          args: ["--port=8080"]             # default is 80; a non-root user binds 8080 with no extra privileges
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet: { path: /health, port: http }
            initialDelaySeconds: 2
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /health, port: http }
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { memory: 64Mi }
```
Things to notice:
- `selector.matchLabels` must equal `template.metadata.labels` — that is how the Deployment finds its own pods.
- The two `securityContext` blocks are Kubernetes' **restricted** profile: not root, no privilege escalation, no
  Linux capabilities, read-only filesystem. whoami needs none of those, so here it costs nothing. Real apps often
  need some (LinuxServer images start as root and drop to `PUID`), which is why the repo doesn't force it.
- No `strategy: Recreate`: nothing is mounted, so a rolling update may briefly run old and new pods side by side.
  An app with a local-path volume must use `Recreate` — two pods can't mount one ReadWriteOnce volume.
- `requests` is what the scheduler reserves; the memory `limit` is where the pod gets OOM-killed. No CPU limit on
  purpose: CPU is compressible, so a limit only throttles (same reasoning as `karakeep/deployment.yaml`).

**`service.yaml`** — a stable name and port in front of whichever pods are ready:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: apps
  labels:
    app: whoami
spec:
  type: ClusterIP
  selector:
    app: whoami          # must match the pod labels, or the Service has no endpoints
  ports:
    - name: http
      port: 80           # what the Ingress (and other pods) connect to
      targetPort: http   # the container's named port (8080)
```

**`ingress.yaml`** — the hostname, and the request for an HTTPS certificate:
```yaml
# https://whoami.williampring.ca — Tailscale-only (DNS: whoami → A → master's Tailscale IP, grey cloud).
# cert-manager sees the annotation and issues whoami-tls by itself (docs/platform/tls.md).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami
  namespace: apps
  labels:
    app: whoami
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - whoami.williampring.ca
      secretName: whoami-tls
  rules:
    - host: whoami.williampring.ca
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: whoami
                port:
                  number: 80
```

### Step 3 — Check it before pushing

```bash
cd ~/repos/Homelab
make render APP=kubernetes/apps/apps/whoami    # the exact objects Argo will apply
make conventions                               # this repo's own rules: depth, ports, pins, probes…
make lint                                      # yamllint
make validate                                  # every app rendered + schema-checked, exactly like CI
```
`render` should print three objects (Service, Deployment, Ingress) and `conventions` should end `CONVENTIONS OK`.

**Break it on purpose** (then undo each one). This is where the checks start to make sense:

| Change | What catches it |
|---|---|
| `image: traefik/whoami:latest` | `make conventions` → **C** FAIL |
| move the files up to `kubernetes/apps/whoami/` | `make conventions` → **A** FAIL — Argo itself would just silently ignore it |
| delete the `readinessProbe` | `make conventions` → **G** WARN |
| change the Service selector to `app: whoam` | **nothing.** It renders and it is valid YAML; you'd find out at Step 6 as "no available server". Rendering proves the pieces are *valid*, not that they *connect*. |

### Step 4 — DNS (outside the cluster, before Sync)

Cloudflare → `williampring.ca` → DNS → **Add record**:

| Type | Name | Content | Proxy status |
|---|---|---|---|
| `A` | `whoami` | the master's Tailscale IP — the same value every other record has (`dig +short home.williampring.ca`) | **DNS only** (grey cloud) |

Why grey: an orange cloud sends the traffic through Cloudflare's edge, which can't reach a `100.x` Tailscale
address. Grey means Cloudflare only answers the DNS question and the traffic goes straight over your tailnet —
which is also why none of this is public.
```bash
dig +short whoami.williampring.ca      # → 100.x.x.x
```

### Step 5 — Push, and watch Argo register it

```bash
git add kubernetes/apps/apps/whoami && git commit -m "feat(whoami): lab app" && git push
```
Within about three minutes, on the master:
```bash
sudo k3s kubectl -n argocd get applications whoami
# NAME     SYNC STATUS   HEALTH STATUS
# whoami   OutOfSync     Missing
```
What happened: the ApplicationSet ([`kubernetes/bootstrap/apps.yaml`](../../kubernetes/bootstrap/apps.yaml)) polls
`main`, found a new directory matching `kubernetes/apps/*/*`, and stamped out an Application from its template —
name = the directory, namespace = its parent. **OutOfSync / Missing** means "git has objects the cluster doesn't".
Your phone gets *"whoami: update waiting"* from Bark. Argo reads GitHub, not your laptop — an unpushed commit is the
usual reason an app never appears.

Impatient? `sudo k3s kubectl annotate applicationset apps -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite`

### Step 6 — Sync, and watch each layer come up

Argo UI → **whoami** → **App Diff** (everything is new, so the diff is the whole app) → **Sync**.

```bash
sudo k3s kubectl get pods -n apps -l app=whoami -w
#   whoami-…   0/1   Running   ← container started; readiness probe not passed yet
#   whoami-…   1/1   Running   ← /health answered: the pod may now receive traffic

sudo k3s kubectl get endpointslices -n apps -l kubernetes.io/service-name=whoami
#   the pod's IP shows up here only once it is Ready — this is the Service's list of targets

sudo k3s kubectl get certificate -n apps whoami-tls
#   READY False → True within 1–2 minutes
```
The certificate: cert-manager saw `cert-manager.io/cluster-issuer` on the Ingress, created a Certificate, proved to
Let's Encrypt that you own the domain by writing a TXT record through the Cloudflare API (DNS-01 — it works even
though nothing is public), and stored the result in the Secret `whoami-tls`, which Traefik serves.

From a device on Tailscale:
```bash
curl https://whoami.williampring.ca
```
```
Hostname: whoami-…                 ← the pod that answered
IP: 10.42.…                        ← that pod's address inside the cluster
RemoteAddr: 10.42.…                ← Traefik, not you: it ended your TLS connection and opened a new one
GET / HTTP/1.1
Host: whoami.williampring.ca       ← how Traefik chose this Ingress
X-Forwarded-For: …                 ← who Traefik thinks the client was
X-Forwarded-Proto: https
```
That output *is* the request path from §1, printed. Bark says *"whoami: deployed"*.

### Step 7 — Wire it in (every real app does this)

Optional for the lab; this is how a real app joins everything else.

**Homepage tile** — `kubernetes/apps/apps/homepage/configmap.yaml`, inside `services.yaml`, in the right group:
```yaml
        - whoami:
            href: https://whoami.williampring.ca
            description: Echoes requests back (lab app)
            icon: mdi-account-question
            siteMonitor: http://whoami.apps.svc.cluster.local/health
            namespace: apps
            podSelector: app=whoami
```
`siteMonitor` makes Homepage ping it; `namespace` + `podSelector` put the pod's status on the tile.

**Gatus checks** — `kubernetes/apps/monitoring/gatus/configmap.yaml`. One in-cluster check (is the app alive?) and
one edge check (do DNS, the cert and Traefik work?):
```yaml
      - name: whoami
        group: apps
        url: "http://whoami.apps.svc.cluster.local/health"
        interval: 1m
        conditions: ["[STATUS] == 200"]
        alerts: [{ type: custom }]
```
```yaml
      - name: whoami.williampring.ca
        group: edge
        url: "https://whoami.williampring.ca/health"
        interval: 5m
        conditions: ["[STATUS] == 200", "[CERTIFICATE_EXPIRATION] > 168h"]
        alerts: [{ type: custom }]
```
Both red → the app is down. Only `edge` red → the app is fine; look at DNS, TLS or Traefik.

**Doc** — `docs/apps/<app>.md` (copy the shape of [`apps/karakeep.md`](../apps/karakeep.md)) plus a line in
[`../index.md`](../index.md). **Renovate** — nothing to do: the pinned tag is already tracked. A stateless app can
join the `stateless patch updates` group in `renovate.json`; one that migrates a database belongs in the
`db-migration` rule.

### Step 8 — Tear it down (removing is a skill too)

```bash
git rm -r kubernetes/apps/apps/whoami && git commit -m "chore(whoami): remove lab app" && git push
```
The Application disappears from Argo — **but the pod keeps running.** Generated Applications have no deletion
finalizer, on purpose: deleting a directory by mistake must never delete an app or its data. So you clean up:
```bash
sudo k3s kubectl delete deploy,svc,ingress -n apps -l app=whoami
sudo k3s kubectl delete secret whoami-tls -n apps          # the cert's Secret outlives the Ingress
sudo k3s kubectl get deploy,svc,ingress,certificate,secret -n apps | grep whoami     # nothing left?
```
Then delete the Cloudflare record (and the Homepage tile and Gatus checks, if you added them). The full pattern
for a real app: [`../runbooks/cluster-cleanup.md`](../runbooks/cluster-cleanup.md).

---

## 3. From the lab to a real app

whoami skipped the hard parts. Each of these changes the files, and each has a real app in the repo to copy.

### 3.1 State — where does the data live?

| Kind of data | Put it on | In `storage.yaml` | Copy from |
|---|---|---|---|
| precious — can't be recreated (photos, budget, archives) | NFS `192.168.68.50:/data/<folder>` | static PV (`Retain`) + a PVC bound to it by `volumeName`, `storageClassName: ""` | `apps/actual/storage.yaml` |
| rebuildable (indexes, caches, thumbnails) | local-path = the node's disk | a PVC with `storageClassName: local-path`, ReadWriteOnce | `media/kavita/storage.yaml` |
| a database | the Postgres LXC `.7` / Valkey `.103` | nothing — env vars plus a secret | `apps/degoog/` (Valkey) |

What follows from that choice:
- The NFS folder must exist and be owned `1000:1000` before Sync (`mkdir -p` + `chown -R 1000:1000` on `.50`), and
  the container must run as uid 1000 — `runAsUser`, or the image's `PUID`/`PGID`.
- Any ReadWriteOnce volume → `strategy: Recreate`.
- SQLite never goes on NFS (file locking) — it goes on local-path, like Calibre's `app.db`.

### 3.2 Health — choosing the probe

| The app has… | Use | Examples here |
|---|---|---|
| a health endpoint | `httpGet` on it | Kavita `/api/health`, Karakeep `/api/health`, SearXNG `/healthz`, Meilisearch `/health` |
| no health endpoint | `httpGet` on `/` — any 2xx/3xx passes, so a redirect to a login page is fine | degoog, Calibre-Web |
| a check on the `Host` header | `httpGet` + `httpHeaders: [{ name: Host, value: … }]` with a host the app accepts | Homepage: `/api/healthcheck` as `Host: 127.0.0.1:3000` |
| no HTTP at all | `exec` a client, or `tcpSocket` | immich-postgres runs `pg_isready` |
| a sidecar container | a probe on the sidecar too — ⚠️ it gates the **whole** pod | Karakeep's `chrome` (`/json/version`) |

- **Readiness and liveness do different things.** A failing readiness probe takes the pod out of its Service (no
  traffic, no restart). A failing liveness probe *restarts* the container.
- Start with readiness. Add liveness only for hangs a restart actually cures — and never point it at something that
  depends on another service, or a database blip turns into a restart loop.
- Slow first boot (migrations)? A long `initialDelaySeconds` on readiness is harmless. For liveness use a
  `startupProbe` instead, so a slow boot isn't killed halfway through a migration.
- **Look at the image's own `HEALTHCHECK` first** — it is the authors' answer to "how do I know this is up?",
  path *and* host. It's in the Dockerfile, or `docker inspect <image>` → `Config.Healthcheck`.
- A probe is a request from the kubelet to `<pod-ip>:<port>` — not to your hostname. An app that checks the `Host`
  header (Homepage does, on every route) answers it with **400**, even though the same URL works in your browser.
  That is what `httpHeaders` is for.
- Otherwise probe the same path Gatus checks, so "Ready" in Kubernetes and "green" in Gatus mean the same thing —
  and if Gatus is red for that app, find out why before copying its path.

### 3.3 Size and placement

- Set `requests` near what the app uses idle and a memory `limit` with headroom; check `sudo k3s kubectl top pod -n <ns>`
  after a week and adjust.
- Heavy apps (lots of RAM, ML, transcoding) get `nodeSelector: immich-node: "true"` — the 32GB worker.

### 3.4 Secrets

```bash
./scripts/secrets.sh new apps/myapp API_KEY DB_PASSWORD     # .enc.yaml + .sops.yaml + the generator, in one go
./scripts/secrets.sh set myapp API_KEY=abc123 DB_PASSWORD=-  # '-' generates a strong value
./scripts/secrets.sh encrypt myapp                           # encrypts, then proves it decrypts
make conventions                                             # D: every secretKeyRef points at a real key
```
Encrypt before the first commit: git history is forever and this repo is public. Pods don't restart when a Secret
changes — `sudo k3s kubectl rollout restart deploy/myapp -n apps`. → [`../platform/secrets.md`](../platform/secrets.md) §3 and §5.

### 3.5 A database or Redis

One Postgres role + database per app on the LXC (template: `scripts/postgres-ghostfolio-setup.sh` in git history) and one Valkey ACL user
per app ([`../platform/redis.md`](../platform/redis.md)). The passwords go in the app's SOPS secret. Create them
**before** the first Sync, or the pod crash-loops on connect. The full walk-through is
[`../archive/deploy-ghostfolio.md`](../archive/deploy-ghostfolio.md).

### 3.6 LAN access (Kindle, TV)

`type: NodePort` plus a free `nodePort: 30xxx` — see the README's Addresses table; `make conventions` (**B**) catches
collisions. Every node answers on every NodePort. Plain HTTP, LAN only.

### 3.7 A Helm chart instead of raw manifests

`helmCharts:` in `kustomization.yaml` (see `media/immich/` and `cert-manager/cert-manager/`). Pin the chart
`version:` — and then check whether the chart also chooses the **app** version for you. Immich's does (its
`appVersion`), so `values.yaml` pins `image.tag` separately; before that pin existed, every chart bump quietly
upgraded Immich, database migration included. Renovate tracks both: the chart through its kustomize manager, the tag
through a custom regex manager in `renovate.json`.

### 3.8 Public? Default no.

Everything is Tailscale-only (grey-cloud DNS → a Tailscale IP). The exceptions are few and deliberate: `public-immich.`
(the Immich share proxy), plus `deploy.` (Argo CD) and `bark.` through a Cloudflare tunnel → NPMplus. Don't add
another without a reason and an auth layer in front of it.

---

## 4. When it doesn't work

Work from the outside in: does Argo have it → does the pod run → is it Ready → does the Service have endpoints →
do the Ingress, cert and DNS work?

| Symptom | Likely cause | Look / fix |
|---|---|---|
| The app never shows up in Argo | not pushed; directory at the wrong depth | `git log origin/main -1`; `make conventions` (A); the refresh annotation above |
| `ComparisonError`, "kustomize build failed" | the directory doesn't render | `make render APP=…`; after fixing, Argo → **Hard Refresh** |
| `ComparisonError` mentioning `ksops`/`sops` | the secret file isn't encrypted, or was encrypted to another age key | `./scripts/secrets.sh status`; [`../platform/secrets.md`](../platform/secrets.md) troubleshooting |
| Sync fails: "provided port is already allocated" | NodePort collision | `make conventions` (B) |
| Pod `Pending` | PVC not bound (`volumeName` typo), `nodeSelector` matches no node, not enough memory for `requests` | `sudo k3s kubectl describe pod …` → Events |
| `ImagePullBackOff` | the tag doesn't exist | `describe pod`; look the tag up in the registry |
| `CreateContainerConfigError` | a Secret or one of its keys is missing (an out-of-band secret not created, a key typo) | `describe pod`; `make conventions` (D) |
| `CrashLoopBackOff` | the app itself: config, DB unreachable, permissions | `sudo k3s kubectl logs deploy/<app> -n <ns> --previous` |
| `Running` but `0/1` | readiness failing: wrong path or port, still starting, a sidecar not ready | `describe pod` → "Readiness probe failed: …" |
| "HTTP probe failed with statuscode: 400" | the app rejects the probe's `Host` (`<pod-ip>:<port>`) | send an allowed one with `httpHeaders` (§3.2) — Homepage is the example |
| `permission denied` under `/data` | NFS folder not owned by 1000:1000, or the container isn't uid 1000 | `ls -ln /data/<folder>` on `.50`; `runAsUser` / `PUID` |
| Traefik's `404 page not found` | no Ingress matches that host: a typo, or no `ingressClassName: traefik` | `sudo k3s kubectl get ingress -A \| grep <host>` |
| `no available server` | the Service has no Ready endpoints: selector ≠ pod labels, or readiness failing | `get endpointslices -n <ns> -l kubernetes.io/service-name=<app>` |
| Browser certificate warning | the Certificate isn't issued yet, or the challenge is failing | `get certificate -n <ns>`; `describe challenge -A` → [`../platform/tls.md`](../platform/tls.md) |
| The name doesn't resolve, or times out | no DNS record, orange cloud, or the device isn't on Tailscale | `dig +short <host>` → should be `100.x` |
| The NodePort works, the hostname doesn't | the app is fine — it's DNS, TLS or the Ingress | the three rows above |

More Argo-specific cases: [`../platform/argocd.md`](../platform/argocd.md).

---

## 5. Check yourself

<details><summary>1. You created <code>kubernetes/apps/whoami/deployment.yaml</code> (one level too shallow) and pushed. What does Argo do?</summary>

Nothing — and nothing errors. The ApplicationSet only generates Applications for `kubernetes/apps/*/*` directories.
`make conventions` (**A**) is the only thing that tells you.
</details>

<details><summary>2. The pod is <code>1/1 Running</code>, but the browser shows "no available server". Where do you look?</summary>

At the Service: `get endpointslices -n apps -l kubernetes.io/service-name=whoami`. If it is empty while the pod is
Ready, the selector doesn't match the pod's labels — or `targetPort` names a port the container doesn't have.
</details>

<details><summary>3. Why must an app with a local-path volume use <code>strategy: Recreate</code>?</summary>

A rolling update starts the new pod before stopping the old one. Both want the same ReadWriteOnce volume, so the new
pod can't mount it and hangs in `ContainerCreating`.
</details>

<details><summary>4. You changed an encrypted secret, pushed and synced, but the app still uses the old value. Why?</summary>

Environment variables are read when the container starts, and a changed Secret doesn't restart anything.
`sudo k3s kubectl rollout restart deploy/<app> -n <ns>`.
</details>

<details><summary>5. Why is the DNS record grey-cloud?</summary>

Orange routes the traffic through Cloudflare's edge, which can't reach a Tailscale `100.x` address. Grey only answers
the DNS question, so the traffic stays on your tailnet — and the site stays private.
</details>

<details><summary>6. Renovate never opens a PR for your new app's image. Two likely reasons?</summary>

The tag isn't a version Renovate can compare (`latest`, or an unusual format — see the qBittorrent and karakeep-chrome
rules in `renovate.json`), or the version sits where Renovate doesn't look: `kubernetes/templates/` is ignored, and a
version inside a Helm values file needs a custom manager, like Immich's.
</details>

<details><summary>7. What's the difference between deleting the app's directory and deleting the app?</summary>

Deleting the directory makes Argo forget the app; its objects keep running. Deleting the app means removing those
objects — and the DNS record, NFS data and database role — yourself. Two steps, on purpose.
</details>

<details><summary>8. Renovate opens "immich chart 0.13.4 → 0.14.0". Does merging it upgrade Immich?</summary>

No. The app version is pinned at `controllers.main.containers.main.image.tag` in `media/immich/values.yaml`, so the
chart bump changes only the chart's templates. An Immich upgrade arrives as its own PR, labelled `⚠️ db-migration`.
</details>

<details><summary>9. You add a readiness probe to a sidecar and the whole app goes offline. Why?</summary>

A pod counts as Ready only when every container in it is Ready. One unready sidecar takes the pod out of its Service.
</details>

<details><summary>10. Homepage loads fine in your browser, but its readiness probe fails with status 400. Why?</summary>

The probe isn't your browser. It is a request from the kubelet to `<pod-ip>:3000`, and Homepage refuses any `Host` that
isn't on its `HOMEPAGE_ALLOWED_HOSTS` list. Your browser sends `home.williampring.ca`, which is on the list. The fix is
to make the probe send a Host the app allows (`httpHeaders`) — copied from the image's own `HEALTHCHECK`, which uses
`127.0.0.1:3000` and `/api/healthcheck`. (This really happened, the first time these probes were added.)
</details>

---

## 6. Words used here

| Term | Meaning |
|---|---|
| **Application / ApplicationSet** | Argo's record of "deploy this directory into that namespace" / the generator that makes one per directory |
| **Sync · OutOfSync · Healthy** | apply git to the cluster · git and the cluster differ · Argo's verdict on the running objects |
| **Hard Refresh** | re-render, ignoring Argo's cache — needed after fixing a render error |
| **Deployment → ReplicaSet → Pod** | the desired state → one version of it → a running copy |
| **Service** (`ClusterIP` / `NodePort`) | a stable name and address in front of the Ready pods its selector matches; NodePort also opens a 30000–32767 port on every node |
| **EndpointSlice** | the Service's current list of Ready pod addresses |
| **Ingress / Traefik** | hostname → Service rules / the controller (bundled with k3s) that carries them out |
| **cert-manager · ClusterIssuer · Certificate · DNS-01** | issues TLS certs · how to reach Let's Encrypt (`letsencrypt`) · one cert request · proving domain ownership with a DNS TXT record |
| **PV · PVC · StorageClass** | a piece of storage · a claim on one · a way to create them on demand (`local-path`); the NFS PVs are written by hand |
| **RWO / RWX** | ReadWriteOnce — one node mounts it / ReadWriteMany — many nodes can |
| **SOPS · age · KSOPS** | encrypts the values in a YAML file · the key type · the kustomize plugin that decrypts inside Argo |
| **readiness / liveness / startup probe** | may it get traffic? / should it be restarted? / still booting — don't judge yet |
| **requests / limits** | reserved for scheduling / the ceiling (memory over the limit = OOM-kill) |
| **nodeSelector** | run only on nodes with this label (`immich-node=true` = the 32GB worker) |

---

**Next:** onboard a real app with [`../platform/adding-an-app.md`](../platform/adding-an-app.md) as the checklist.
For what to learn after that, see the roadmap in
[`../architecture/production-architecture.md`](../architecture/production-architecture.md).
