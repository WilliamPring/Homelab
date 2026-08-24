# Platform Decisions

This document explains the architectural choices made and the tradeoffs considered.

---

## Why k3s Over Full Kubernetes

Full Kubernetes (kubeadm) requires multiple control plane components running separately (etcd, API server, scheduler, controller manager). On a 2-4GB ARM board this is impractical.

k3s bundles everything into a single binary (~70MB), uses SQLite instead of etcd by default, and has a much smaller memory footprint (~512MB vs ~2GB for full k8s).

Tradeoff: k3s is opinionated. Some advanced features require workarounds (like the Helm controller for managing addons).

---

## Why Tailscale Over WireGuard Direct

We considered running Mullvad (WireGuard) at the host level for all cluster traffic. Problems:

1. All traffic goes through Mullvad — k3s control plane, SSH, everything
2. Kill switch rules conflict with Tailscale's fwmark (`0x40000`)
3. If Mullvad drops, you lose SSH access to fix it

Tailscale handles NAT traversal, key rotation, and device management automatically. It uses WireGuard under the hood but adds a coordination layer that makes multi-device mesh networking trivial.

We use Tailscale for cluster networking + remote access, and Mullvad only for specific pod egress via Gluetun sidecar.

---

## Why Gluetun Sidecar Over Host-Level VPN

**Host-level VPN** (running Mullvad WireGuard via wg-quick):
- All egress goes through Mullvad — including k3s, Tailscale, apt
- Requires complex kill switch rules
- Breaks Tailscale without careful fwmark exemptions
- If Mullvad tunnel drops, entire node loses internet

**Gluetun sidecar**:
- Only pods that explicitly use the sidecar go through Mullvad
- Zero impact on host networking or other pods
- Each VPN pod is independently restartable
- Can mix VPN providers per-namespace

Tradeoff: Each VPN pod has its own WireGuard tunnel (more connections to Mullvad). Negligible on a homelab.

---

## Why cert-manager Over Traefik Built-in ACME

**Traefik built-in ACME**:
- Lightweight — no extra components
- Stores certs in `acme.json` on a PVC
- PVC uses `local-path` (RWO) — only one node can mount it
- DaemonSet Traefik breaks: each instance independently requests certs, hits Let's Encrypt rate limits

**cert-manager**:
- Adds ~300MB RAM (3 controllers)
- Stores certs as k8s Secrets in etcd — cluster-wide
- All Traefik instances share the same cert Secret
- DaemonSet works correctly
- Auto-renews 30 days before expiry
- Industry standard for k8s cert management

Decision: cert-manager is the right tool for HA ingress. The RAM cost is justified by correctness.

---

## Why DaemonSet for Traefik

A single Traefik Deployment means:
- All traffic goes through one node (SPOF)
- DNS must point to that specific node's IP
- If the node fails, ingress is down

DaemonSet Traefik:
- Runs on every node, binds hostPort 80/443 on each
- DNS round-robins across all 3 node IPs
- If one node fails, DNS still resolves to the other two
- Pods can schedule on any node without routing issues

---

## Why hostPort Over LoadBalancer (svclb)

k3s's built-in `svclb` controller creates DaemonSet pods that write iptables DNAT rules to forward host ports to service ClusterIPs.

Problem: svclb pods are not in host network namespace. They write iptables rules to their own namespace. Traffic arriving at the host's Tailscale interface (`tailscale0`) never enters that namespace, so DNAT rules never fire.

`hostPort` tells the container runtime (containerd) to bind the port directly on the host's network stack. No iptables tricks, works on any interface, fully transparent.

Verified with: `sudo ss -tlnp | grep -E "80|443"` shows the process directly.

---

## Subdomain Naming Convention

Format: `<service>.<function>.williampring.ca`

**Rejected approaches:**
- `qbittorrent.vpn.williampring.ca` — describes implementation (VPN), not function
- `qbittorrent.williampring.ca` — flat, doesn't scale as services grow
- `qbittorrent.ts.williampring.ca` — Tailscale is infrastructure, not function

**Chosen:**
- `qbittorrent.media.williampring.ca` — describes what it does
- Mirrors k8s namespace structure (media namespace → media subdomain)
- Scales naturally: add service, add IngressRoute, DNS wildcard covers it

---

## Why Not Expose Services Publicly

All services are internal — DNS points to Tailscale IPs (`100.x.x.x`) which are not publicly routable. No port forwarding on the router, no home IP exposure.

Tradeoff: Services only accessible on Tailscale. Remote access requires Tailscale client on all devices. This is acceptable — Tailscale's client exists for every platform (iOS, macOS, Windows, Linux, Android).

For services that need to be public (personal website), use a separate VPS or Cloudflare Tunnel — not this cluster.
