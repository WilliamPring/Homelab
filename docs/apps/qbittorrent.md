# qBittorrent + Gluetun: torrents that only ever leave through Mullvad

**qBittorrent** is the torrent client: a WebUI where you add torrents and watch them download.
**Gluetun** is a small VPN client container. It connects to **Mullvad** over WireGuard and puts up a firewall
so nothing else can get out. Both run together in **one pod**. Because of that, qBittorrent has no route to
the internet except through Mullvad.

```
you ── https://qbittorrent.williampring.ca (Tailscale) ──► WebUI          ← control comes IN normally
                                                         qBittorrent ──► Mullvad ──► peers   ← torrents go OUT via VPN only
```

| | |
|---|---|
| Argo app | `qbittorrent` (namespace `media`): `kubernetes/apps/media/qbittorrent/` |
| WebUI | `https://qbittorrent.williampring.ca` (Tailscale) · `http://192.168.68.63:30080` (LAN) |
| Downloads | NFS `192.168.68.50:/data/downloads/{incomplete,complete}` |
| Runs on | the 32GB worker (`immich-node: "true"`) |

---

## 1. The one idea that makes this work: a pod shares one network

All containers in a Kubernetes pod share **one network namespace**: the same IP address, the same network
interfaces and the same firewall rules. Think of it as two programs on one small computer.

```
┌─ pod: qbittorrent ──────────────────────────────────────────────────────────────────┐
│  ONE network namespace (pod IP 10.42.x.x)                                           │
│                                                                                     │
│   interfaces:  eth0  ── the normal pod network (Traefik, kubelet, the node)         │
│                tun0  ── the WireGuard tunnel to Mullvad (Gluetun creates this)       │
│   firewall:    Gluetun's iptables rules (the "kill switch"): they apply to BOTH     │
│                                                                                     │
│   ┌─ container: gluetun ─────────┐        ┌─ container: qbittorrent ─────────────┐  │
│   │ connects to Mullvad          │        │ no VPN settings at all               │  │
│   │ creates tun0                 │        │ bound to tun0 (qBittorrent.conf)     │  │
│   │ writes the firewall rules    │        │ WebUI listens on :8080               │  │
│   │ DNS over TLS on 127.0.0.1    │◄───────┤ resolv.conf → 127.0.0.1 (dnsConfig)  │  │
│   │                              │        │ /downloads → NFS · /config → PVC     │  │
│   └──────────────────────────────┘        └──────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

qBittorrent doesn't know a VPN exists. It just sees a computer whose only usable route out is `tun0`.

### Where each kind of traffic goes

| Traffic | Path | Allowed by |
|---|---|---|
| Torrent peers and trackers | qBittorrent → `tun0` → Mullvad (Toronto) → internet | the tunnel is the default route |
| DNS lookups | qBittorrent → `127.0.0.1:53` → Gluetun → DNS-over-TLS → `tun0` | `dnsPolicy: None` + `dnsConfig` (see lock 4) |
| You opening the WebUI | Traefik (or NodePort) → `eth0` → `:8080` | `FIREWALL_INPUT_PORTS=8080` |
| Replies to Traefik / kubelet probes | `:8080` → `eth0` → back the way they came | nothing needed — replies to an accepted connection ride conntrack |
| qBittorrent → another pod (not used yet) | `eth0` → 10.42.x.x | `FIREWALL_OUTBOUND_SUBNETS=10.42.0.0/16` (k3s pod range) |
| Anything else to the internet over `eth0` | **dropped** | nothing allows it, which is the whole point |

The WebUI never goes through the VPN, and it doesn't need to: it comes in over Tailscale and never touches
the public internet.

---

## 2. The four locks (why your real IP can't leak)

Locks 1–3 each stop *packets* going out the wrong way; any one of them would do on its own, and having all
three means one mistake doesn't expose your IP. Lock 4 is a different kind: it closes a leak the other three
can't see, because it isn't about where packets go — it's about who you ask for directions.

| # | Lock | Where | What happens if the VPN isn't up |
|---|---|---|---|
| 1 | **Start order.** Gluetun is a *native sidecar* (an `initContainer` with `restartPolicy: Always`). Kubernetes won't start qBittorrent until Gluetun's `startupProbe` (`/gluetun-entrypoint healthcheck`) passes | `deployment.yaml` | qBittorrent simply hasn't started yet |
| 2 | **Firewall kill switch.** Gluetun's iptables rules drop every packet that isn't going through the tunnel (apart from the holes in §1, none of which reach the internet) | Gluetun, at runtime | packets are dropped, not sent over `eth0` |
| 3 | **Interface binding.** `Session\Interface=tun0` in qBittorrent.conf | `configmap.yaml` | qBittorrent never even tries `eth0`; torrents just stall |
| 4 | **DNS.** `dnsPolicy: None` + `dnsConfig.nameservers: [127.0.0.1]` point every lookup at Gluetun's own DNS-over-TLS resolver | `deployment.yaml` | lookups fail instead of falling back to CoreDNS |

### Why lock 4 is needed (this one is subtle)

Containers in a pod share a **network namespace** — one IP, one set of interfaces, one firewall. That is what
makes locks 1–3 work. But they do **not** share a **mount namespace**: each container has its own filesystem,
and so its **own `/etc/resolv.conf`**.

Kubernetes writes that file for you, and by default it points at CoreDNS. So without lock 4, qBittorrent's
packets all go through the tunnel (locks 1–3 hold) while its *questions* — "what is the IP of
`tracker.example.org`?" — go to CoreDNS, out to your home router, and on to **your ISP's resolver**. Your ISP
can't see what you downloaded, but it has a timestamped list of every tracker you looked up. That is usually
enough.

Three things make it easy to miss: `curl https://am.i.mullvad.net/connected` still says you're connected
(that lookup is cached or goes over the tunnel by then), the firewall never logs a drop (CoreDNS is a
*permitted* destination), and nothing in the pod ever errors. **A leak test that only checks your IP will
pass.** §5 step 3 checks the thing that actually breaks.

Readiness ties the VPN to monitoring. Gluetun's `readinessProbe` runs the same healthcheck, and a pod is
only *Ready* when **all** its containers are Ready. If the tunnel stays down for about 90 seconds, the pod
turns NotReady, the Service has no endpoints, and **Gatus alerts you**. Meanwhile Gluetun keeps trying to
reconnect on its own.

---

## 3. What each file does

```
kubernetes/apps/media/qbittorrent/
├── kustomization.yaml              lists everything below; `generators:` runs KSOPS for the secret
├── deployment.yaml                 the pod: seed-config → gluetun (sidecar) → qbittorrent
├── configmap.yaml                  qBittorrent.conf SEED (tun0 binding, save paths, WebUI behind a proxy)
├── storage.yaml                    NFS PV/PVC for /downloads · local-path PVC for /config
├── service.yaml                    ClusterIP + NodePort 30080 (WebUI only)
├── ingress.yaml                    qbittorrent.williampring.ca + Let's Encrypt cert
├── qbittorrent-secret.enc.yaml     Mullvad WireGuard key + address (SOPS-encrypted)
└── qbittorrent-secret.sops.yaml    the KSOPS generator: "decrypt that file at render time"
```

When the pod starts, the containers come up in this order:

```
seed-config (busybox, runs once, exits)
   │  copies qBittorrent.conf onto the PVC, but only if one isn't there yet
   ▼
gluetun (keeps running) ── startupProbe: is the tunnel healthy? ── no → wait (up to 5 min)
   │                                                               yes ↓
   ▼
qbittorrent (starts now, inside a network where the tunnel already exists)
```

**The config seed only runs on first start.** After that, the file on the PVC is the live one, so changes you
make in the WebUI stay. To reset to what's in git, delete `/config/qBittorrent/qBittorrent.conf` and restart the pod.

---

## 4. First-time setup (in order)

### 4.1 Get a Mullvad WireGuard key
1. Go to <https://mullvad.net/account> → **WireGuard configuration** → Platform *Linux* → **Generate key**.
2. Pick any server and download the `.conf` file. Gluetun picks the actual server later, so it doesn't matter which one you choose.
3. From the `[Interface]` section, copy two values:
   ```ini
   PrivateKey = aBcD...=                        → WIREGUARD_PRIVATE_KEY
   Address    = 10.66.1.2/32,fc00:bbbb::1/128   → WIREGUARD_ADDRESSES = 10.66.1.2/32   (IPv4 part only)
   ```
   Take only the IPv4 address: the cluster doesn't do IPv6, and an IPv6 address makes Gluetun fail to connect.
   The key uses one of your account's 5 device slots.

### 4.2 Put it in the SOPS secret (on the Arch box)
```bash
$EDITOR kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml      # replace both REPLACE_ME values
sops --encrypt --in-place kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml
sops -d kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml >/dev/null && echo ENCRYPTED
```
**Encrypt before you push.** Argo's KSOPS step can't decrypt a file that was never encrypted, so the app
shows a render error until you do. (CI only warns about this while `STRICT_SECRETS=0`.)

### 4.3 Create the download folders (file server, 192.168.68.50)
```bash
mkdir -p /data/downloads/{complete,incomplete}
chown -R 1000:1000 /data/downloads && chmod -R 775 /data/downloads
```

### 4.4 Add the DNS record
Cloudflare → `qbittorrent` → **A** → the master's Tailscale IP, **grey cloud** (DNS only).

### 4.5 Push → Sync
```bash
# (you) push the branch → within ~3 min Argo lists `qbittorrent` as OutOfSync
# Argo UI → qbittorrent → read the diff → SYNC
sudo k3s kubectl get pods -n media -l app=qbittorrent -w      # wait for 2/2 Running, Ready
```
`0/2 Init:1/2` for a little while is normal: that's Gluetun connecting. If it stays there for minutes, see §7.

### 4.6 First login and set a password
qBittorrent generates a **temporary** admin password each time it starts, until you set your own:
```bash
sudo k3s kubectl logs -n media deploy/qbittorrent -c qbittorrent | grep -i password
#   The WebUI administrator password was not set. A temporary password is provided for this session: XXXXXXXX
```
Open `https://qbittorrent.williampring.ca` and log in as `admin` with that password. Then go to **Tools → Options →
WebUI → Authentication**, set a real password and click **Save**. It's stored, hashed, in the config on the PVC.

---

## 5. Prove it works (do this once, and after any change to the pod)

```bash
NS="-n media"; POD=deploy/qbittorrent

# 1. Gluetun says it connected, and prints the public IP it ended up with
sudo k3s kubectl logs $NS $POD -c gluetun | grep -iE 'public ip|healthy|error' | tail
#   [ip getter] Public IP address is 146.70.x.x (Canada, Ontario, Toronto)
#   [healthcheck] healthy!

# 2. Ask Mullvad from INSIDE qBittorrent's container. It must say you're connected:
sudo k3s kubectl exec $NS $POD -c qbittorrent -- curl -s https://am.i.mullvad.net/connected
#   You are connected to Mullvad (server ca-tor-wg-xxx). Your IP address is 146.70.x.x

# 3. THE DNS CHECK (lock 4). Steps 1-2 pass even when DNS is leaking, so check it directly.
#    a) qBittorrent must be asking its own pod, not CoreDNS:
sudo k3s kubectl exec $NS $POD -c qbittorrent -- cat /etc/resolv.conf
#   nameserver 127.0.0.1          <- correct
#   nameserver 10.43.0.10         <- LEAKING: that is CoreDNS. dnsPolicy/dnsConfig didn't apply.
#
#    b) and the answers must actually be coming back (proves Gluetun's resolver is up):
sudo k3s kubectl exec $NS $POD -c qbittorrent -- getent hosts mullvad.net
#
#    c) Gluetun should log the lookups it is doing over DNS-over-TLS:
sudo k3s kubectl logs $NS $POD -c gluetun | grep -i dns | tail

# 4. Compare with your home IP (run this on the master, which is outside the pod). The two must differ:
curl -s https://am.i.mullvad.net/ip

# 5. Optional: test the kill switch. Take the tunnel down and show that nothing gets out:
sudo k3s kubectl exec $NS $POD -c gluetun -- ip link set tun0 down
sudo k3s kubectl exec $NS $POD -c qbittorrent -- curl -s -m 5 https://am.i.mullvad.net/ip || echo "BLOCKED - good"
#   Gluetun's healthcheck notices within seconds and rebuilds the tunnel on its own.
```

For an end-to-end check from qBittorrent itself, add a torrent IP checker such as <https://ipleak.net>
(the "Torrent Address detection" section gives you a magnet link). It should only ever show the Mullvad IP.

---

## 6. Day-to-day

- **Add a torrent:** WebUI → *File → Add torrent link* (magnet) or upload a `.torrent`. In-progress files go to
  `/data/downloads/incomplete` and move to `/data/downloads/complete` when finished.
- **Change the Mullvad location:** edit `SERVER_COUNTRIES` / `SERVER_CITIES` in `deployment.yaml`, then push and Sync.
  Your key works with every Mullvad WireGuard server. The names come from Gluetun's server list (e.g. `Vancouver`,
  `Montreal`).
- **Rotate the Mullvad key:** revoke the old key on mullvad.net, generate a new one, run `sops` on the secret file to
  edit it, push, Sync, then `rollout restart deploy/qbittorrent -n media`. Pods don't restart by themselves when a
  Secret changes.
- **Upgrades:** Renovate opens PRs for `qmcgaw/gluetun` and `lscr.io/linuxserver/qbittorrent`. Read the changelog,
  merge, then Sync.
- **About the image tag.** It is `5.3.0_v2.1.2-ls485`, not `5.3.0`. LinuxServer re-pushes the short tag on every
  rebuild, so `5.3.0` can be a different image tomorrow and you'd never know which one a pod is running. The long
  tag is `<app>_<libtorrent>-ls<build>` and never moves. The price is that Renovate can't read it as a version
  number, so `renovate.json` carries a `versioning: regex:…` rule for this one image — if you ever change the tag
  *shape*, that rule has to change with it or the updates go quiet.

### Things to know (limitations)
- **No port forwarding.** Mullvad removed port forwarding in 2023. Other peers can't open connections *to* you,
  so you're "not connectable". Downloads still work fine because you connect out to peers. Seeding to other
  not-connectable peers is limited, and that's expected.
- **The NodePort (`:30080`) is plain HTTP on the LAN**, like the other NodePorts. Use the HTTPS hostname when you can.
- **qBittorrent can't resolve `*.svc.cluster.local` names.** This is lock 4 working as intended: the pod asks
  Gluetun, and Gluetun doesn't know about cluster services. If you ever connect it to Sonarr/Radarr, have
  *them* call *it* by name (inbound works fine), not the other way round. If you truly need the reverse, use
  the other pod's IP rather than reinstating CoreDNS — putting `10.43.0.10` back in `dnsConfig` re-opens the leak.

---

## 7. Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| Pod stuck at `Init:1/2` | Gluetun can't connect (wrong/revoked key, or an IPv6 address in `WIREGUARD_ADDRESSES`) | `kubectl logs -n media deploy/qbittorrent -c gluetun`. Repeated `i/o timeout` / handshake errors usually mean a bad key: generate a new one (§4.1) |
| Pod stuck at `Init:1/2` **after a node reboot or OOM-kill**, logs say `adding IPv6 rule: ...: file exists` | a stale WireGuard `ip rule` from the previous container — ip rules are pod-scoped and outlive an abrupt exit | the `postStart` hook in `deployment.yaml` clears these on every start, so this should self-heal. If it persists, delete the pod so it gets a fresh network namespace |
| Argo shows a render / `ComparisonError` mentioning ksops or sops | the secret is still the plaintext template | encrypt it (§4.2) → push → *Hard Refresh* |
| Pod `CreateContainerError` / mount error on `tun` | the node has no `/dev/net/tun` | on the worker: `ls -l /dev/net/tun` (should be `crw-rw-rw- 10,200`). `sudo modprobe tun` to load it |
| WebUI shows plain `Unauthorized` | qBittorrent's host-header check behind the proxy | confirm `WebUI\HostHeaderValidation=false` in `/config/qBittorrent/qBittorrent.conf` (it's seeded, but an older config on the PVC wins) |
| WebUI times out but the pod is Ready | Gluetun's firewall is blocking the port | `FIREWALL_INPUT_PORTS` must include `8080` |
| Pod flips to NotReady, Gatus alerts | VPN healthcheck failing | Gluetun logs. Usually Mullvad server trouble that it fixes on its own; otherwise change `SERVER_CITIES` |
| Torrents stuck at "Stalled" with 0 peers | tun0 binding with no tunnel, or the tracker is down | check §5 steps 1–2. If the VPN is fine, try another torrent |
| Files appear as the wrong owner on NFS | `PUID`/`PGID` vs the folder owner | `/data/downloads` must be `1000:1000` (§4.3) |
| Nothing resolves: every tracker is "unreachable", but the IP check passes | Gluetun's resolver isn't answering on `127.0.0.1:53`, and lock 4 means there's no fallback | `logs -c gluetun \| grep -i dns`. `DNS_SERVER` must stay at its default `on` (it is what listens on 127.0.0.1); `DNS_UPSTREAM_RESOLVER_TYPE` defaults to `DoT` |
| **One** tracker never resolves while others are fine | Gluetun blocks known-malicious domains by default (`BLOCK_MALICIOUS=on`), and a tracker can land on that list. With no fallback resolver, the lookup just fails — it looks identical to a dead tracker | confirm with `logs -c gluetun \| grep -i blocked`. Allow it with `DNS_UNBLOCK_HOSTNAMES=tracker.example.org` in `deployment.yaml` rather than turning blocking off wholesale |
| DNS stops working for a minute, roughly daily | `DNS_UPDATE_PERIOD` defaults to `24h`: Gluetun rebuilds its blocklist and restarts the resolver, and lock 4 means there is no second nameserver to cover the gap | harmless if torrents just pause. Set `DNS_UPDATE_PERIOD=0` to disable the periodic rebuild if it annoys you |
| `resolv.conf` shows `10.43.0.10` | `dnsPolicy`/`dnsConfig` didn't apply (old pod, or the fields were dropped) | this is the DNS leak — `rollout restart`, then re-check §5 step 3 |

---

## 8. Quick reference

```bash
sudo k3s kubectl get pods -n media -l app=qbittorrent                         # 2/2 Ready = VPN up + WebUI up
sudo k3s kubectl logs -n media deploy/qbittorrent -c gluetun --tail=50         # the VPN side
sudo k3s kubectl logs -n media deploy/qbittorrent -c qbittorrent --tail=50     # the torrent side
sudo k3s kubectl exec -n media deploy/qbittorrent -c qbittorrent -- curl -s https://am.i.mullvad.net/connected
sudo k3s kubectl rollout restart deploy/qbittorrent -n media                   # after a secret change
```

| Setting | File | Value | Why |
|---|---|---|---|
| `VPN_SERVICE_PROVIDER` / `VPN_TYPE` | deployment | `mullvad` / `wireguard` | which VPN, which protocol |
| `WIREGUARD_PRIVATE_KEY` / `_ADDRESSES` | secret | from the Mullvad `.conf` | who you are to Mullvad |
| `SERVER_COUNTRIES` / `SERVER_CITIES` | deployment | `Canada` / `Toronto` | where your traffic exits |
| `FIREWALL_INPUT_PORTS` | deployment | `8080` | lets the WebUI in |
| `FIREWALL_OUTBOUND_SUBNETS` | deployment | `10.42.0.0/16` | lets this pod *start* a connection to another pod |
| `dnsPolicy` / `dnsConfig` | deployment | `None` / `127.0.0.1` | lock 4 — lookups go to Gluetun, not CoreDNS |
| `Session\Interface` | configmap | `tun0` | qBittorrent only ever uses the tunnel |
| `WebUI\HostHeaderValidation` | configmap | `false` | WebUI works behind Traefik + NodePort |
| `restartPolicy: Always` on gluetun | deployment | (native sidecar) | Gluetun starts first and gates qBittorrent |

### Words used on this page
- **Network namespace**: the Linux feature that gives a pod its own private set of interfaces, routes and firewall rules.
  Every container in a pod shares one.
- **Mount namespace**: the same idea for the filesystem — but each *container* gets its own, which is why each one has
  its own `/etc/resolv.conf` and why lock 4 is a separate setting rather than something the shared network gives you.
- **DNS leak**: when your traffic goes through the VPN but your name lookups don't, so your ISP still gets a list of
  everything you connected to. Payload hidden, metadata exposed.
- **DNS over TLS (DoT)**: encrypted DNS. Gluetun runs a DoT resolver on `127.0.0.1:53` so even the lookups inside the
  tunnel aren't readable by the exit server's network.
- **Sidecar**: a helper container in the same pod as the main app. A *native* sidecar (Kubernetes 1.29+) is declared under
  `initContainers` with `restartPolicy: Always`, so it starts first and keeps running.
- **WireGuard**: the VPN protocol. `tun0` is the virtual interface it creates.
- **Kill switch**: firewall rules that block traffic when the VPN is down, instead of falling back to the normal connection.
- **Gluetun**: <https://github.com/qdm12/gluetun-wiki> (the Mullvad page and the "firewall" options are the relevant ones).

### History
An earlier version (Aug 2026) ran in a `vpn` namespace, was applied by an Ansible role, and used hostPath volumes and
`:latest` images. It was dropped in the GitOps refactor. This version keeps what that one learned (`FIREWALL_*`, the
host-header fix, revoked-key symptoms) and moves it into Argo: pinned images, a SOPS secret, NFS downloads, and a native sidecar.
