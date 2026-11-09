# Homepage — the dashboard

`https://home.williampring.ca` — the index of the homelab. Every app with a UI has a tile here.

| | |
|---|---|
| **URL** | `https://home.williampring.ca` |
| **Manifests** | `kubernetes/apps/apps/homepage/` |
| **Namespace** | `apps` |
| **Image** | `ghcr.io/gethomepage/homepage` (pinned; Renovate PRs bumps) |
| **Storage** | none — the whole config is a ConfigMap |
| **Secret** | `homepage-secret` ← OpenBao `homelab/homepage` (widget API keys only; optional) |

---

## The one idea worth understanding

A tile has **two independent health signals**, and the difference between them is the
diagnostic:

| | what it checks | runs from |
|---|---|---|
| `siteMonitor` | an HTTP probe of the app's **in-cluster** Service | the homepage **pod** |
| `podSelector` | the actual Pod's status (Running / CrashLoopBackOff / OOMKilled) | the **Kubernetes API** |

Both deliberately bypass Cloudflare, Tailscale, Traefik and the cert. So:

```
tile GREEN + link works     → everything is fine
tile GREEN + link dead      → the APP is fine, the EDGE is broken
                              (DNS, Tailscale, Traefik, or an expired cert) → check Gatus
tile RED   + pod Running    → the app is up but not answering HTTP (hung, wrong port, auth)
tile RED   + pod not Running→ the app itself is down → kubectl logs
```

That split is the whole point. A plain list of links tells you nothing when something breaks;
this tells you *which layer* broke before you open a terminal.

> ⚠️ `siteMonitor` URLs are copied from **Gatus's** endpoint list
> (`kubernetes/apps/monitoring/gatus/configmap.yaml`). Gatus owns the *edge* checks
> (`https://library.williampring.ca/...`); Homepage owns the *in-cluster* ones. When you add
> an app, add it to both.

---

## The layout (redesigned Nov 2026)

```
┌ info bar (every tab) ─ cluster + node CPU/RAM │ Toronto weather │ clock │ search (degoog) ┐
├ [ Home ] [ Ops ] ───────────────────────────────────────────────────────────────────────┤
│ Home:  Media        Reading         Everyday       Money                                │
│        Immich ▦     Library ▦       Bookmarks ▦    Budget                               │
│        Downloads ▦  Books ▦         degoog         Portfolio                            │
│                     Manga sources ▦ SearXNG                                             │
│ Ops:   Cluster:        Argo CD ▦ │ Grafana ▦ │ Status ▦ │ Bark                          │
│        Infrastructure: Pulse │ OpenBao │ Proxmox .96 │ Proxmox .89                       │
│        bookmarks:      Homelab (repo, Argo/Gatus LAN)                                    │
│ every tab, bottom: LAN fallback — every NodePort with its local IP:port written out      │
└──────────────────────────────────────────────────────────────────────────────────────────┘
▦ = live widget (numbers from the app's API, not just a dot)
```

| Before | After |
|---|---|
| one long page, 3 groups (Media / Apps / Monitoring), 4 tiles across | two tabs: **Home** (what you use) and **Ops** (what runs it); 6 groups, each with an icon |
| plain `slate` dark theme | night-sky background at 35% opacity, frosted-glass cards (`cardBlur: md`), boxed info widgets, theme-coloured glyphs, refined stat blocks, `plexData` digits |
| one service widget (Grafana → Prometheus targets) | widgets on Immich, qBittorrent, Kavita, Calibre-Web, Suwayomi, Karakeep, Argo CD, Gatus and Grafana |
| Komf, RomM and Ghostfolio tiles | gone (apps removed); Wealthfolio is "Portfolio" |
| Proxmox only as bookmarks | Proxmox hosts are tiles under **Infrastructure** next to Pulse and OpenBao |
| info bar: cluster, search, weather | + date/time; weather cached 15 min |
| info bar: cluster first | **Nov 2026:** the two Proxmox hosts lead (Glances: CPU / RAM / disk / temp), then the cluster, then tickers (Finnhub), then search, clock, weather |

Why these choices (from the Homepage docs and the configs people share on r/selfhosted / GitHub):

- **Tabs**: the most common advice on busy dashboards is to split daily-use apps from admin
  tools. Groups with no `tab:` would show on every tab; every group here has one, so each lives
  in exactly one place. The info bar (`widgets.yaml`) is always on top.
- **Background + glass**: a dim photo with `cardBlur` is the look most shared dashboards use.
  The docs say `cardBlur` does not combine with the background's blur/saturate/brightness
  filters, so only `opacity` is set. The image comes from Unsplash and is loaded by your
  **browser**, not the pod. To self-host it, mount a file at `/app/public/images/` and use
  `image: /images/<file>`.
- **Column groups on Home, row groups on Ops**: four short groups side by side fill one screen.
  The Ops tiles carry most of the wide widgets, so they get full-width rows of four.
- **`useEqualHeights`**: tiles with a widget are taller; without this a row looks ragged.
- **LAN fallback on every tab**: that group has no `tab:`, so it sits at the bottom of both
  tabs, and each link shows its `192.168.68.63:<port>` so you can read the IP even when you can't click it.
- **No `focus: true` on search**: it would grab keystrokes from quicklaunch (type anywhere to
  filter tiles and launch one), which is the faster way to open an app.

---

## Service widgets and their secrets

Homepage replaces `{{HOMEPAGE_VAR_X}}` anywhere in its config with the env var `HOMEPAGE_VAR_X`
(official feature, see gethomepage.dev → Installation → "Using environment secrets"). The chain:

```
OpenBao homelab/homepage  (property HOMEPAGE_VAR_X)
  → externalsecret.yaml   → Secret apps/homepage-secret (key HOMEPAGE_VAR_X)
  → deployment.yaml env   (secretKeyRef, optional: true)
  → configmap.yaml        key: "{{HOMEPAGE_VAR_X}}"
```

Every env var is `optional: true`, so the pod starts before any of this exists. Until a key is
filled in, its widget shows an API error and the other tiles work.

| OpenBao property (`homelab/homepage`) | widget | how to get it |
|---|---|---|
| `HOMEPAGE_VAR_IMMICH_KEY` | Immich: photos / videos / storage | Immich → Account Settings → API Keys → new key with **`server.statistics`** only |
| `HOMEPAGE_VAR_QBITTORRENT_KEY` | qBittorrent: down/up speed, leech/seed + leech progress | qBittorrent → Options → WebUI → Authentication → **API Key** (qBit ≥ 5.2) |
| `HOMEPAGE_VAR_KAVITA_KEY` | Kavita: series / files | Kavita (admin user) → Settings → Account → API Key |
| `HOMEPAGE_VAR_CALIBRE_USERNAME` / `_PASSWORD` | Calibre-Web: books / authors / series | a Calibre-Web user (reads the OPDS feed). A separate low-privilege user is best |
| `HOMEPAGE_VAR_SUWAYOMI_USERNAME` / `_PASSWORD` | Suwayomi: download/read counts | the basic-auth login set in `suwayomi/deployment.yaml` |
| `HOMEPAGE_VAR_KARAKEEP_KEY` | Karakeep: bookmarks / favorites / highlights / tags | Karakeep → User Settings → API Keys |
| `HOMEPAGE_VAR_ARGOCD_KEY` | Argo CD: apps / **out of sync** / healthy / degraded | token of the read-only `homepage` account, see below |
| `HOMEPAGE_VAR_FINNHUB_KEY` | the **stocks** info bar widget (ticker + daily %) | a free key at [finnhub.io](https://finnhub.io). Not a tile — it is read through `settings.yaml` → `providers.finnhub` |

No credential needed: **Gatus** (up / down / uptime of the *edge* checks) and **Grafana**'s
Prometheus targets widget.

> ⚠️ **ESO writes the Secret only when every listed property exists.** One missing key and
> `homepage-secret` is not created (the ExternalSecret shows `SecretSyncedError`). Put all nine
> in at once. A placeholder such as `unset` works for one you have not generated yet:
> ```bash
> bao kv put homelab/homepage \
>   HOMEPAGE_VAR_IMMICH_KEY=… HOMEPAGE_VAR_QBITTORRENT_KEY=… HOMEPAGE_VAR_KAVITA_KEY=… \
>   HOMEPAGE_VAR_CALIBRE_USERNAME=… HOMEPAGE_VAR_CALIBRE_PASSWORD=… \
>   HOMEPAGE_VAR_SUWAYOMI_USERNAME=… HOMEPAGE_VAR_SUWAYOMI_PASSWORD=… \
>   HOMEPAGE_VAR_KARAKEEP_KEY=… HOMEPAGE_VAR_ARGOCD_KEY=…
> kubectl -n apps annotate externalsecret homepage-secret force-sync=$(date +%s) --overwrite
> kubectl -n apps rollout restart deploy/homepage      # env vars are read at start
> ```
> To change one later, use `bao kv patch`, force-sync, then restart.

### The Argo CD `homepage` account

The widget needs an API token. It uses a dedicated account, not admin:

- `kubernetes/bootstrap/argocd/argocd-cm-patch.yaml` adds `accounts.homepage: apiKey` (API
  tokens only, no UI login).
- `kubernetes/bootstrap/argocd/argocd-rbac-cm.yaml` adds `g, homepage, role:readonly`.
  `policy.default` stays unset, so nothing else changes.

These are **bootstrap** files: Argo does not sync them. You apply them:

```bash
kubectl apply -k kubernetes/bootstrap/argocd -n argocd
argocd account generate-token --account homepage     # or UI → Settings → Accounts → homepage → Generate New
bao kv patch homelab/homepage HOMEPAGE_VAR_ARGOCD_KEY=<token>
```

### Adding a widget

1. Add the `widget:` block to the tile in `configmap.yaml`. Use the **in-cluster** URL (the pod
   calls it, not your browser) and `"{{HOMEPAGE_VAR_<NAME>}}"` for the credential.
2. Add the property to OpenBao and to `externalsecret.yaml`'s `data:`.
3. Add the env var to `deployment.yaml` with `secretKeyRef: { name: homepage-secret, key: …, optional: true }`.
   `make conventions` checks that the key exists in the ExternalSecret.

---

## Glances on the Proxmox hosts

The two leftmost info-bar widgets (`pve-a` 192.168.68.96, `pve-b` 192.168.68.89) read **Glances**,
which runs **on the Proxmox hosts themselves** — not in k3s, so Argo does not manage it. Without it
they render an error box and everything else on the bar still works.

Why Glances and not the Proxmox API: this is the host's own CPU / RAM / disk / **temperature**, the
numbers a hypervisor hides. Per-VM and per-LXC detail is Pulse's job, and it already has a tile.

On **each** host, as root:
```bash
apt update && apt install -y glances
glances -V                      # 3.x on PVE 8 (bookworm), 4.x on PVE 9 — must match `version:` in widgets.yaml
```
Then a unit so it survives a reboot — `/etc/systemd/system/glances.service`:
```ini
[Unit]
Description=Glances REST API
After=network-online.target

[Service]
ExecStart=/usr/bin/glances -w --disable-webui --bind 192.168.68.96
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
Set `--bind` to **that host's own** address: `.96` on pve-a, `.89` on pve-b. (systemd takes no inline
`#` comments in `ExecStart` — anything after it is passed as an argument.)
```bash
systemctl enable --now glances
curl -s http://localhost:61208/api/4/cpu | head -c 200     # /api/3/ on Glances 3.x
```

⚠️ **The API has no authentication by default.** `--bind` to the LAN address above (never
`0.0.0.0` while the host has a public path), or add `--password` and set `username` / `password` on
both widgets. It is read-only either way, but it does describe your hardware.

Worth adding to Gatus's `infra` group alongside the two Proxmox checks, so a dead Glances pages you
instead of silently emptying the bar.

## What's in the ConfigMap

One ConfigMap, five keys, each mounted as its own file via `subPath` (so Homepage can still
create `/app/config/logs`):

| key | what it is |
|---|---|
| `settings.yaml` | title, theme + background, tabs/layout, `statusStyle`, quicklaunch |
| `services.yaml` | the tiles |
| `widgets.yaml` | the info bar: Proxmox hosts (Glances), cluster stats, stocks, search, clock, weather |
| `bookmarks.yaml` | repo, Argo/Gatus LAN links, and the **LAN fallback** list |
| `kubernetes.yaml` | how to talk to the cluster API |

### The LAN fallback bookmarks

Every app also listens on a NodePort. Those links need **no DNS, no Cloudflare, no Tailscale
and no cert** — they are what you use when every tile is dead but `kubectl get pods` looks
fine, i.e. the apps are up and the edge is not.

They all point at **`192.168.68.63`** — `k3s-master-01`.

ℹ️ A NodePort answers on **every** node, so `k3s-worker-01` (`192.168.68.62`) serves every one of
these too. If `.63` is down, swap the IP and the links still work.

> 🛑 **These IPs have moved before.** The master lived on `192.168.68.93` until a DHCP lease
> change moved it to `.63`, and the repo went on saying `.93` — including `ansible/inventory.ini`,
> which is Ansible's SSH target. The symptom is distinctive: **every** link in this list dies at
> once while `kubectl get pods` is completely healthy.
>
> Set **DHCP reservations for both nodes** on the router so this stops recurring, then verify:
> ```bash
> sudo k3s kubectl get nodes -o wide     # INTERNAL-IP must match .63 / .62
> ```

Two fixed LAN addresses worth memorising, because they are the ones you need when the edge
is down and they are **not** reachable by hostname at all:

```
Argo CD   http://192.168.68.63:30443      (LAN only, plain HTTP, no cert — on purpose)
Gatus     http://192.168.68.63:30881
Bark      http://192.168.68.63:30889
```

Three hostnames are fronted by **NPMplus + Cloudflare**, not Traefik — no Ingress and no
cert-manager cert exists for any of them in this repo:

| tile | hostname | LAN fallback |
|---|---|---|
| Argo CD | `https://deploy.williampring.ca` | `http://<node>:30443` |
| Bark | `https://bark.williampring.ca` | `http://<node>:30889` |
| Pulse | `https://pulse.williampring.ca` | — (runs on Proxmox, not in this cluster) |

Argo's NodePort is first in the bookmark list on purpose: that hostname depends on Cloudflare +
the tunnel + NPMplus, and Argo is the tool you need in order to repair exactly those things.

> ⚠️ Bark's hostname is for the **iPhone app's registration and this tile only**. Gatus and Argo
> push alerts to `http://bark.monitoring.svc.cluster.local:8080` — in-cluster, deliberately. If
> alerts went through the hostname, a Cloudflare or NPMplus outage would silence the very alert
> that tells you about it.

> 🛑 **The fallback list has a bootstrap problem.** Homepage itself has no NodePort, and
> `HOMEPAGE_ALLOWED_HOSTS` lists only `home.williampring.ca` plus the in-cluster name Gatus uses —
> so if DNS dies you cannot load the page that holds the fallback links. Keep the two addresses
> above somewhere outside the cluster. Fixing this properly needs a NodePort **and** a wider
> `HOMEPAGE_ALLOWED_HOSTS` **and** a README port-table entry; doing half of it just fails.

> ⚠️ **Every request is Host-checked — `/` included, not just the API.** Anything addressed to a
> host that isn't in `HOMEPAGE_ALLOWED_HOSTS` (or `localhost:3000` / `127.0.0.1:3000`, always
> allowed) gets `400 Host validation failed`. That bites three ways:
> - **The readiness probe** arrives as `<pod-ip>:3000`, so it sends `Host: 127.0.0.1:3000` to
>   `/api/healthcheck` — exactly what the image's own `HEALTHCHECK` does.
> - **Gatus's in-cluster check** arrives as `homepage.apps.svc.cluster.local:3000`, which is why that
>   name is in the list.
> - **A new hostname or a NodePort** gets 400 until you add it too (with the port, e.g. `192.168.68.63:30xxx`).

---

## The Kubernetes integration

`kubernetes.yaml` sets `mode: cluster`, which means "read the API using the ServiceAccount
token the kubelet projects into this pod". That token comes from `rbac.yaml`:

- **ServiceAccount** `homepage` in `apps`
- **ClusterRole** `homepage` — `get` and `list` only, on `namespaces`, `pods`, `nodes`,
  `ingresses`, and `metrics.k8s.io`. No `watch`, no `create`, no secrets.
- **ClusterRoleBinding** tying them together

> ⚠️ The ClusterRole and ClusterRoleBinding are **cluster-scoped**. Deleting the
> `kubernetes/apps/apps/homepage/` directory removes the Argo Application but leaves these
> behind — Argo Applications here have no finalizer. Delete them by name.
> `scripts/cluster-cleanup.sh` knows about this class of leftover.

### Discovery is off on purpose

`ingress: false`, `traefik: false`, `gateway: false` are **service-discovery** toggles, not
display toggles. Left on, Homepage scans Ingresses and auto-creates tiles for any annotated
`gethomepage.dev/enabled: "true"`. Nothing in this repo sets that annotation, so discovery
would find nothing anyway — they are off so that `services.yaml` stays the single source of
truth rather than tiles appearing from two places.

### If the cluster widgets render empty

The CPU/memory numbers come from metrics-server, not the core API. k3s bundles it:

```bash
sudo k3s kubectl get deploy metrics-server -n kube-system
sudo k3s kubectl top nodes            # must work before the widget can
```

---

## Adding a tile

```yaml
- Thing:
    href: https://thing.williampring.ca
    description: what it does, in a few words
    icon: thing.png                 # dashboard-icons name, or mdi-… / si-… glyph
    siteMonitor: http://thing.<ns>.svc.cluster.local:<port>/health
    namespace: <ns>
    podSelector: app=thing          # this repo labels pods `app: <name>`
```

> ⚠️ `podSelector` for **Immich** and **Argo CD** is commented out. Those two are rendered by
> upstream Helm charts / install manifests, so their labels are not this repo's `app: <name>`
> convention and were not verified. The verify command is in the comment next to each.
> A wrong selector shows a confident red dot for a healthy app, which is worse than no dot.

---

## Known gaps

- **No widget for Pulse or Proxmox.** Both have Homepage widgets (`pulse` needs a
  `monitoring:read` token; `proxmox` needs a PVE API token). They are not wired because the
  widget is called from the **pod**, and it is not verified that a pod can reach
  `pulse.williampring.ca` (a Tailscale IP) or the Proxmox hosts. Test with
  `kubectl -n apps exec deploy/homepage -- wget -qO- https://192.168.68.96:8006` before adding them.
- **No Gluetun widget** (VPN exit IP / country). Gluetun's control server (`:8000`) is not in the
  qBittorrent Service. That server can also *change* the VPN, so exposing it in-cluster needs an
  auth `config.toml` that allows only `GET /v1/publicip/ip`. Not worth it for one number.
- **Actual, Wealthfolio, SearXNG, degoog and Bark have no widget**: Homepage has none for them.
  A dot is all they get.
- **The background image is third-party** (Unsplash, loaded by the browser). If it ever 404s, the
  page falls back to the plain dark theme.
- **The Immich Public Proxy has no tile.** Its live hostname is `public-immich.williampring.ca`.
