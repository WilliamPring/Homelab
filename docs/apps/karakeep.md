# Karakeep

Save a link, and keep a copy of the page that survives the original going offline. Bookmarks, full-text
search, highlights, lists — and optionally AI tagging (off here, see §6).

`https://karakeep.williampring.ca` · LAN: `http://<node-LAN-IP>:30300` · `kubernetes/apps/apps/karakeep/`

> Karakeep used to be called **Hoarder**. Old blog posts and the odd forum thread still use that name.

---

## 1. The shape of it: one pod, three containers

Karakeep is three programs that are useless apart. They run in a single pod and talk over `127.0.0.1`:

```
┌─ pod: karakeep ─────────────────────────────────────────────────────────────────────┐
│  ONE network namespace — so these three reach each other on localhost, no Services  │
│                                                                                     │
│   ┌─ karakeep :3000 ───────────┐  ┌─ chrome :9222 ───────┐  ┌─ meilisearch :7700 ─┐ │
│   │ the web app + the worker   │  │ headless Chromium    │  │ full-text search    │ │
│   │ "save this URL"            │─►│ loads the page and   │  │ index of everything │ │
│   │ writes /data (NFS)         │  │ snapshots it         │  │ /meili_data (local) │ │
│   └────────────────────────────┘  └──────────────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────┘
          only :3000 is exposed ──► Service ──► Traefik ──► karakeep.williampring.ca
```

**Why the Chrome container exists.** A normal bookmark is a URL, and URLs rot. Karakeep drives a real
headless browser to render each page — JavaScript and all — and stores the result. That's why saving a
bookmark takes a few seconds, and why this app wants more RAM than you'd expect from "a bookmark manager".

**Why one pod and not three Deployments.** They scale together (never), they're meaningless apart, and
putting them in one pod means no Services, no cluster DNS, and no startup ordering to get wrong — they
just use `127.0.0.1`. It's the same shared-network-namespace trick as qBittorrent + Gluetun; if that
phrase is new, [`qbittorrent.md`](qbittorrent.md) §2 explains it properly.

The trade-off is honest: they share a lifecycle. But a crash in one container restarts **only that
container** — Kubernetes doesn't tear down the pod for that — so in practice this costs very little.

**Why it isn't pinned to the 32GB node.** Chrome is bursty, and that node already carries Immich's ~26Gi
of limits. This one is left for the scheduler to place. If archiving turns out slow, that's the first
knob to revisit.

---

## 2. What each file does

```
kubernetes/apps/apps/karakeep/
├── kustomization.yaml            lists the resources + the KSOPS generator
├── deployment.yaml               the three containers above, all pinned
├── storage.yaml                  NFS PVC for /data · local-path PVC for the search index
├── service.yaml                  ClusterIP + NodePort 30300 (only :3000 — see below)
├── ingress.yaml                  karakeep.williampring.ca + Let's Encrypt cert
├── karakeep-secret.enc.yaml      NEXTAUTH_SECRET + MEILI_MASTER_KEY (SOPS-encrypted)
└── karakeep-secret.sops.yaml     the KSOPS generator: "decrypt that file at render time"
```

**Only port 3000 is in the Service, deliberately.** Chrome's DevTools port (`9222`) is remote code
execution by design, and Meilisearch's API (`7700`) has only the master key in front of it. Neither has
any business being reachable from outside the pod, so neither is in `service.yaml`.

### The two volumes, and why they're on different storage

| Volume | Holds | Class | Reasoning |
|---|---|---|---|
| `/data` | SQLite DB (bookmarks, tags, lists, highlights) **and** the archived page copies | **NFS** | once the original site is gone, this is the only copy in existence |
| `/meili_data` | Meilisearch's full-text index | **local-path** | derived entirely from `/data`. Lose it, re-index from the Admin page, lose nothing |

That split is the "precious vs rebuildable" rule from `CLAUDE.md` in one file.

---

## 3. Setup

### 3.1 Create the NFS directory
On the file server (`192.168.68.50`), once:
```bash
mkdir -p /data/karakeep && chown -R 1000:1000 /data/karakeep && chmod -R 775 /data/karakeep
```
The karakeep container runs as uid 1000 specifically so this works — NFS checks the number, not the name.

### 3.2 Fill in and encrypt the secret
On the Arch box (it has the age key):

```bash
openssl rand -base64 36                      # → NEXTAUTH_SECRET
openssl rand -base64 36 | tr -dc 'A-Za-z0-9' # → MEILI_MASTER_KEY
```

Paste both into `kubernetes/apps/apps/karakeep/karakeep-secret.enc.yaml`, then:

```bash
sops --encrypt --in-place kubernetes/apps/apps/karakeep/karakeep-secret.enc.yaml
```

Neither value is anything you need to remember — they're random, and nothing outside the cluster uses them.

- **`NEXTAUTH_SECRET`** signs your login session cookies. Changing it later just logs everyone out.
- **`MEILI_MASTER_KEY`** is the password between karakeep and meilisearch. **Both containers read the
  same key** — that's why it's one secret entry referenced twice, not two separate values. If they ever
  disagree, search breaks while everything else keeps working.

⚠️ Until this file is encrypted it is a plaintext template, and Argo's KSOPS step will fail to render the
app. That's the expected failure if you Sync too early — see §7.

### 3.3 Add the DNS record
Cloudflare → `karakeep` → **A** → the master's Tailscale IP, **grey cloud** (DNS only).

`NEXTAUTH_URL` in `deployment.yaml` names this hostname, so it's the canonical address and the one the
mobile apps and extension should use. The NodePort still works for logging in, though — Karakeep's
`AUTH_TRUSTED_ORIGINS` defaults to `*`, meaning it accepts whatever address the request actually arrived on.

### 3.4 Sync, then create your account
Push, Sync in Argo, open `https://karakeep.williampring.ca` and **sign up**. The first account created
becomes the admin.

### 3.5 Then close the door
Signups stay open by default. Once your account exists, add to `deployment.yaml`:

```yaml
            - name: DISABLE_SIGNUPS
              value: "true"
```

push, Sync. The server is Tailscale-only already, but there's no reason to leave registration open on
something that archives your reading.

---

## 4. Check it works

```bash
NS="-n apps"; POD=deploy/karakeep

# all three containers up (3/3)
sudo k3s kubectl get pods $NS -l app=karakeep

# the app
sudo k3s kubectl logs $NS $POD -c karakeep --tail=30

# the archiver — this is the one that fails quietly
sudo k3s kubectl logs $NS $POD -c chrome --tail=30

# search
sudo k3s kubectl logs $NS $POD -c meilisearch --tail=30
```

Then the real test: **save a bookmark and watch it get archived.** Paste a URL in the UI. Within a few
seconds the entry should gain a title, a screenshot and readable text. If the title appears but the
screenshot never does, Chrome is the problem, not Karakeep (§7).

---

## 5. Day-to-day

- **Browser extension** — Chrome and Firefox, in their respective stores. Point it at your server URL
  and generate an API key in Karakeep under Settings. This is how you'll actually use it.
- **Mobile apps** — iOS and Android, both point at the same URL + API key. Tailscale required.
- **Share sheet on iOS** works through the app, which is the nicest way to save things on a phone.
- **Re-index search** — Admin → re-index, if search results ever look stale or after restoring
  `/data` without `/meili_data`.
- **Upgrades** — Renovate opens PRs for all three images. Karakeep moves fairly quickly; read its release
  notes, since it does run DB migrations on start.

---

## 6. Turning on AI tagging later

It's off right now — no API key, no extra workload, nothing to pay for, and the app is fully functional
without it. You tag by hand.

To enable it, add **one** of these to the `karakeep` container's `env:` and Sync:

```yaml
# Option A — OpenAI (fast, good, costs a little per bookmark)
            - name: OPENAI_API_KEY
              valueFrom:
                secretKeyRef: { name: karakeep-secret, key: OPENAI_API_KEY }

# Option B — a local Ollama (free and private, but slow on CPU)
            - name: OLLAMA_BASE_URL
              value: "http://<ollama-host>:11434"
            - name: INFERENCE_TEXT_MODEL
              value: "<model>"
```

For option A, add the key to `karakeep-secret.enc.yaml` and re-encrypt — same two steps as §3.2.

For option B, be realistic: without a GPU, tagging one bookmark takes tens of seconds and Ollama wants
several GB of RAM. Workable for a trickle of saves; frustrating if you bulk-import.

---

## 7. Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| Argo render fails mentioning ksops or sops | the secret is still the plaintext template | encrypt it (§3.2) → push → **Hard Refresh** in Argo |
| Pod `ContainerCreating`, mount error | `/data/karakeep` missing on the NFS box | §3.1 |
| App loads, but every save fails to write | NFS dir not owned by `1000:1000` | `ls -ln /data/karakeep` on the file server |
| Bookmarks save but never get a screenshot or text | the chrome container | `logs -c chrome`. Chrome crashing on startup usually means memory — raise its limit |
| Chrome crashes with `/dev/shm` errors | shared memory too small in a container | `--disable-dev-shm-usage` is already set; if it recurs, add an `emptyDir` with `medium: Memory` at `/dev/shm` |
| Search returns nothing, everything else fine | meilisearch key mismatch, or an empty index | `logs -c meilisearch`. Then Admin → re-index |
| Login bounces back to the login page | `NEXTAUTH_URL` doesn't match the address you used | use `https://karakeep.williampring.ca`, not the NodePort |
| Pod restarts after an upgrade, then recovers | Karakeep ran a DB migration on start | normal — check `logs -c karakeep` to confirm it completed |

---

## 8. Quick reference

```bash
sudo k3s kubectl get pods -n apps -l app=karakeep                      # expect 3/3 Ready
sudo k3s kubectl logs -n apps deploy/karakeep -c karakeep --tail=50
sudo k3s kubectl logs -n apps deploy/karakeep -c chrome --tail=50
sudo k3s kubectl logs -n apps deploy/karakeep -c meilisearch --tail=50
sudo k3s kubectl rollout restart deploy/karakeep -n apps               # after a secret change
```

| Setting | Where | Value | Why |
|---|---|---|---|
| `DATA_DIR` | deployment | `/data` | upstream says never change it |
| `MEILI_ADDR` | deployment | `http://127.0.0.1:7700` | the sidecar, over the shared loopback |
| `BROWSER_WEB_URL` | deployment | `http://127.0.0.1:9222` | ditto |
| `NEXTAUTH_URL` | deployment | `https://karakeep.williampring.ca` | must match how you actually reach it |
| `NEXTAUTH_SECRET` | secret | random | signs session cookies |
| `MEILI_MASTER_KEY` | secret | random | shared by two containers — they must agree |
| meilisearch image | deployment | `v1.41.0` | deliberately matches Karakeep's own compose, not latest |
| NodePort | service | `30300` | mnemonic: Karakeep's own port 3000 |

### Words used on this page
- **Headless browser**: a real browser with no window, driven by another program. Karakeep uses one to
  render pages exactly as you'd see them before archiving.
- **DevTools protocol**: the API a browser exposes for remote control (port 9222 here). Powerful enough
  that it must never be exposed outside the pod.
- **Re-index**: rebuilding the search index from the source data. Safe and repeatable, which is why the
  index sits on a rebuildable volume.

Docs: <https://docs.karakeep.com/>
