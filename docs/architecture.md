# Architecture Deep Dive

## The Networking Stack

Understanding how packets flow through this cluster is essential.

### Tailscale as the Transport Layer

Most k3s clusters use VXLAN (via flannel) to tunnel pod traffic between nodes. We use Tailscale instead.

The flannel config (`/var/lib/rancher/k3s/agent/etc/flannel/net-conf.json`) reveals this:

```json
{
  "Network": "10.42.0.0/16",
  "Backend": {
    "Type": "extension",
    "PostStartupCommand": "tailscale set --accept-routes --advertise-routes=$SUBNET",
    "ShutdownCommand": "tailscale down"
  }
}
```

On first boot, flannel runs `tailscale set --advertise-routes=<node-pod-cidr>`. Each node advertises its pod subnet as a Tailscale route:

```
pringles-master  → advertises 10.42.0.0/24
sourcream-worker → advertises 10.42.1.0/24
bbq-worker       → advertises 10.42.3.0/24
```

Pods on different nodes communicate through the Tailscale WireGuard tunnel. No VXLAN, no flannel.1 interface — just encrypted WireGuard traffic between nodes.

**Critical**: If Tailscale is reset on any node, these routes are wiped. Flannel's PostStartupCommand only runs once on k3s-agent start. Re-advertise manually:

```bash
# On the affected node
sudo tailscale set --accept-routes --advertise-routes=<node-pod-cidr>
# Approve in Tailscale admin console
```

### Pod CIDR Allocation

k3s assigns pod CIDRs automatically:
```
Cluster CIDR: 10.42.0.0/16
Master:        10.42.0.0/24
Workers:       10.42.1.0/24, 10.42.2.0/24, 10.42.3.0/24 (assigned in join order)
```

### Service CIDR
```
10.43.0.0/16 — ClusterIPs for Services
10.43.0.10   — CoreDNS (cluster DNS)
```

---

## The Ingress Stack

### Why hostPort Instead of LoadBalancer

k3s creates `svclb` DaemonSet pods that write iptables DNAT rules to forward host ports to Traefik's ClusterIP. This works on standard interfaces but fails with Tailscale because:

1. svclb pods write rules to their own network namespace (not the host's)
2. Traffic arriving at `100.x.x.x:80` (Tailscale interface) never enters the pod namespace
3. DNAT rules never fire

`hostPort` tells containerd to bind directly to the host interface at port 80/443. Simple, transparent, works with any interface.

### Why cert-manager Instead of Traefik Built-in ACME

Traefik's built-in ACME stores certs in `acme.json` on a PVC with `local-path` storage class (RWO — ReadWriteOnce). This means:
- Only one node can mount the PVC at a time
- Other Traefik instances (DaemonSet) can't access the certs
- Each instance independently requests its own cert → Let's Encrypt rate limits

cert-manager stores certs as k8s Secrets in etcd. Secrets are cluster-wide — any pod on any node can read them. DaemonSet Traefik instances all read the same Secret.

### The DNS-01 Challenge Flow

```
cert-manager sees Certificate resource
        ↓
Calls Let's Encrypt ACME API
        ↓
Let's Encrypt: "Prove you own *.media.williampring.ca"
"Create TXT record: _acme-challenge.media.williampring.ca = <token>"
        ↓
cert-manager calls Cloudflare API (using CF_DNS_API_TOKEN)
Creates TXT record in Cloudflare
        ↓
Let's Encrypt verifies DNS TXT record
Issues wildcard certificate (valid 90 days)
        ↓
cert-manager stores cert as k8s Secret "media-wildcard-tls" in kube-system
Deletes TXT record from Cloudflare
        ↓
Traefik reads Secret, serves HTTPS
cert-manager auto-renews 30 days before expiry
```

---

## The VPN Stack

### Gluetun Sidecar Pattern

Pods in the `vpn` namespace use Gluetun as a network sidecar:

```
Pod (shared network namespace)
├── gluetun container
│   ├── Creates WireGuard tunnel to Mullvad
│   ├── Sets default route through tun0
│   └── Runs internal firewall (blocks inbound except FIREWALL_INPUT_PORTS)
└── qbittorrent container
    └── All traffic exits via gluetun's tun0 — no VPN config needed
```

Key Gluetun env vars:
- `FIREWALL_OUTBOUND_SUBNETS: 10.42.0.0/16` — allows pod-to-pod traffic (bypasses VPN for cluster-internal traffic)
- `FIREWALL_INPUT_PORTS: 8080` — opens qBittorrent WebUI port through Gluetun's firewall

### Why Not Host-Level VPN

Running Mullvad at the host level would:
- Route ALL traffic through Mullvad (including k3s control plane, Tailscale, SSH)
- Require kill switch rules that conflict with Tailscale's fwmark
- Break cluster networking if Mullvad drops

Gluetun sidecar gives per-pod VPN with zero impact on everything else.

---

## iptables Backends

Debian Bookworm ships with two iptables backends:
- `iptables-nft` — uses nftables kernel subsystem (default on Bookworm)
- `iptables-legacy` — uses classic iptables kernel subsystem

k3s uses `iptables-legacy`. Set it as the default:

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

If these are mismatched, k3s's iptables rules are invisible to the host and vice versa.
