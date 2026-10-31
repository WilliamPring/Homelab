# Bark — push notifications to the iPhone (replaces ntfy for alerts)

**Why:** ntfy's iOS app must *fetch* each message from your server, and your server is Tailscale-only,
so pushes were lost whenever Tailscale was asleep on the phone. Bark delivers server → **Apple push
(APNs)** → phone; the phone never has to reach your server after a one-time registration. Open
source (MIT), tiny Go server, free iOS app.

```
Gatus (outages)  ─┐
                  ├─ POST /push ─► bark (monitoring ns, NodePort 30889) ─► APNs ─► iPhone (Bark app)
Argo CD (deploys)─┘
Phone ─► NPMplus (bark.<domain>, TLS) ─► node:30889   ← only for the one-time device registration
```

| Argo app | Path | Deploys |
|---|---|---|
| `bark` | `kubernetes/apps/monitoring/bark` | Deployment, 1Gi PVC (device keys), NodePort Service. **No Ingress / no cert — NPMplus fronts it** |

---

## Setup

### 1. Deploy
Push → the ApplicationSet registers `bark` → Argo UI → Sync.
```bash
sudo k3s kubectl get pods -n monitoring -l app=bark
curl -s http://192.168.68.63:30889/ping          # {"code":200,"message":"pong",...}
```

### 2. NPMplus proxy host (your side)
Proxy host `bark.<your domain>` → scheme `http`, forward host `192.168.68.63`, port `30889`.
TLS as you do for your other NPMplus hosts. Websockets not needed. (Plain `http://192.168.68.63:30889`
also works from the LAN for testing.)

### 3. Register the phone
Bark app (App Store, "Bark – Custom notifications") → **Servers** (top-right) → add server →
`https://bark.<your domain>` (or the LAN URL while testing) → the app registers and shows a
**device key** (a short string like `aBcD12…`). Copy it.

### 4. Put the device key where the senders read it
Inline for now (your testing stance — a device key only allows sending pushes *to your phone*):
- `kubernetes/apps/monitoring/gatus/deployment.yaml` → env `BARK_DEVICE_KEY`
- `kubernetes/bootstrap/argocd/argocd-notifications-cm.yaml` → `context: barkDeviceKey`

Then push → Sync `gatus` → `sudo k3s kubectl -n monitoring rollout restart deploy/gatus`, and
`sudo k3s kubectl apply -k kubernetes/bootstrap/argocd/ -n argocd`.

### 5. Test
```bash
curl -s -X POST http://192.168.68.63:30889/push -H 'Content-Type: application/json' \
  -d '{"device_key":"<KEY>","title":"homelab","body":"hello from the cluster","group":"test"}'
```
Phone buzzes within a second, Tailscale on or off. Then lock the phone and send again — same.

---

## How alerts look
| Sender | Title | Level | Group |
|---|---|---|---|
| Gatus down | 🔴 DOWN *endpoint* | timeSensitive (breaks through Focus briefly) | homelab |
| Gatus resolved | 🟢 UP *endpoint* | timeSensitive | homelab |
| Argo | *app*: update waiting / deployed / SYNC FAILED / DEGRADED | active | argocd |

Levels: `passive` (silent), `active` (normal), `timeSensitive`, `critical` (overrides Do Not Disturb;
needs the app's critical-alert permission). Change per sender in the Gatus ConfigMap / Argo templates.
Tap a notification → opens the status page (Gatus) or the app in Argo.

**End-to-end encryption** (optional): the body otherwise passes through Apple in clear text. Bark
app → server → Encryption → set a key; senders then post `ciphertext` instead of `body`. Gatus's
custom provider cannot encrypt, so leave this off unless you move to a small relay.

## Switch-over from ntfy
Both channels fire during the transition (Gatus `alerts: [custom, ntfy]`, Argo subscribes `bark, ntfy`).
After a week of Bark arriving reliably: remove the `ntfy:` provider and `type: ntfy` entries from the
Gatus ConfigMap, the `ntfy` service/recipient from the Argo ConfigMap, and the ntfy app directory.

## Troubleshooting
| Symptom | Fix |
|---|---|
| CrashLoop, logs say **"invalid option"** mentioning `entrypoint.sh` | `args:` lost the command name — see the box below. `bark-server` must be the first entry |
| `/ping` works, no push | wrong/missing device key (`REPLACE_ME` still in place?); check `kubectl -n monitoring logs deploy/gatus` and `deploy/bark` for the POST result |
| Push arrives with Tailscale on but not off | that would be ntfy behaviour, not Bark's — make sure the Bark subscription is the one you are testing |
| App can't register | NPMplus host not resolving / not forwarding to `:30889`; try the LAN URL first |
| Bark server down | Gatus still pages via ntfy for that one endpoint; dashboard shows it red |

### ⚠️ `args:` replaces the image's command — it does not append to it

The Bark image is built as:

```
ENTRYPOINT ["/entrypoint.sh"]
CMD        ["bark-server"]
```

Kubernetes maps `command:` → ENTRYPOINT and `args:` → CMD, and setting either one **replaces** the
image's value. So listing only the flags:

```yaml
args: [--addr=0.0.0.0:8080, --data=/data]     # ✗ wrong
```

runs `/entrypoint.sh --addr=0.0.0.0:8080 --data=/data` — the script receives a flag where it expects
a command name and exits with *"invalid option"*. The command has to be restated:

```yaml
args: [bark-server, --addr=0.0.0.0:8080, --data=/data]    # ✓
```

**How to check any image before overriding its args** — read what it actually declares, rather than
guessing (`docker inspect` locally, or the registry API without pulling):

```bash
docker inspect finab/bark-server:v2.3.9 --format '{{.Config.Entrypoint}} {{.Config.Cmd}}'
```

If `Cmd` is non-empty, your `args:` must reproduce it. If `Cmd` is empty — as in Karakeep's Chrome
image — the entrypoint takes the flags directly and there is nothing to restate.
