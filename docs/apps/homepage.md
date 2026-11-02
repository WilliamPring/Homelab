# Homepage — the dashboard

`https://home.williampring.ca` — the index of the homelab. Every app with a UI has a tile here.

| | |
|---|---|
| **URL** | `https://home.williampring.ca` |
| **Manifests** | `kubernetes/apps/apps/homepage/` |
| **Namespace** | `apps` |
| **Image** | `ghcr.io/gethomepage/homepage` (pinned; Renovate PRs bumps) |
| **Storage** | none — the whole config is a ConfigMap |

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

## What's in the ConfigMap

One ConfigMap, five keys, each mounted as its own file via `subPath` (so Homepage can still
create `/app/config/logs`):

| key | what it is |
|---|---|
| `settings.yaml` | title, theme, layout, `statusStyle`, quicklaunch |
| `services.yaml` | the tiles |
| `widgets.yaml` | the top bar — cluster stats, search, weather |

| `bookmarks.yaml` | repo, Proxmox, and the **LAN fallback** list |
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

> ⚠️ **Node IPs have moved before** (one changed on its own — DHCP). If the whole fallback list
> dies at once while `kubectl get pods` is healthy, re-check the IPs and set DHCP reservations:
> ```bash
> sudo k3s kubectl get nodes -o wide     # INTERNAL-IP column
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

- **No API-backed widgets yet.** Homepage has real widgets for Immich, qBittorrent, Kavita,
  Calibre-web, Karakeep, RomM, Suwayomi, Gatus, ArgoCD, Ghostfolio, Gluetun, Proxmox and
  Pulse — they show actual data (library counts, VPN exit IP, out-of-sync app count) instead
  of a dot. Every one needs an API key or password, and **this repo is public**, so they are
  blocked on a SOPS-encrypted `homepage-secret` + `{{HOMEPAGE_VAR_*}}` substitution.
  Note that substitution is community-documented, not official — prove it with one throwaway
  variable before wiring several credentials through it, and set `hideErrors: true` so a
  broken widget does not paint the dashboard with API errors.
- **Actual Budget and SearXNG have no widget** — a dot is all they will ever get.
- **Pulse has no widget yet.** Its embedded iframe was removed in Nov 2026 (it loaded a whole
  second app on every page view). Homepage has a real `pulse` widget that would show VM/LXC and
  backup state as data — it needs an API token, so it is blocked on the same secret path.
- **The Immich Public Proxy has no tile.** Its live hostname is `public-immich.williampring.ca`
  (the proxy's `PUBLIC_BASE_URL`); the old `share.williampring.ca` record is gone. Point a tile
  there if you want one.
