# Homelab — Multi-Node ARM K3s Cluster

A self-hosted private cloud built on Radxa ROCK 4B+ single-board computers. All traffic is secured via Tailscale mesh VPN. Services are exposed internally via Traefik with automatic TLS certificates managed by cert-manager and Cloudflare DNS-01.

---

## Hardware

| Node | Board | Role | Tailscale IP | LAN IP |
|------|-------|------|-------------|--------|
| pringles-master | Radxa ROCK 4B+ (arm64) | k3s control plane | 100.96.33.73 | 192.168.68.115 |
| sourcream-worker | Radxa ROCK 4B+ (arm64) | k3s worker | 100.111.74.14 | 192.168.68.116 |
| bbq-worker | Radxa ROCK 4B+ (arm64) | k3s worker + Beszel hub | 100.82.180.67 | 192.168.68.118 |

- OS: Debian GNU/Linux 12 (Bookworm)
- Architecture: arm64
- Storage: eMMC (root) + SSD on master (planned for downloads)

---

## Architecture

```
Your Devices (Mac, iPhone, PC)
        │
   Tailscale mesh (100.x.x.x private network)
        │
   Cloudflare DNS (DNS only, no proxy)
   *.media.williampring.ca       → all 3 node IPs
   *.monitoring.williampring.ca  → all 3 node IPs
        │
   Traefik (DaemonSet, hostPort 80/443 on every node)
        │
   cert-manager (wildcard TLS via Cloudflare DNS-01)
   Certs stored as k8s Secrets in etcd — shared across all nodes
        │
   ┌─────────────────────────────────┐
   │  media namespace                │
   │  qbittorrent + Gluetun sidecar  │  → Mullvad VPN (Canada/Toronto)
   │  sonarr, radarr, prowlarr       │  → Mullvad VPN
   └─────────────────────────────────┘
   ┌─────────────────────────────────┐
   │  monitoring namespace           │
   │  Beszel hub                     │
   └─────────────────────────────────┘
```

### Key Design Decisions

- **Tailscale as flannel backend** — k3s uses Tailscale to route pod CIDRs between nodes instead of VXLAN. Each node advertises its pod CIDR (`10.42.x.0/24`) as a Tailscale subnet route.
- **Gluetun sidecar pattern** — VPN runs as a sidecar container, not host-level. Only media pods exit via Mullvad. Everything else uses direct internet.
- **cert-manager over Traefik built-in ACME** — Traefik's built-in ACME stores certs in a local file (not cluster-wide). cert-manager stores certs as k8s Secrets in etcd, accessible by all nodes — required for DaemonSet Traefik.
- **hostPort over LoadBalancer svclb** — svclb pods write iptables rules in pod network namespace, not host namespace. Doesn't work with Tailscale interfaces. hostPort tells containerd to bind directly to the host interface.

---

## Subdomain Convention

```
<service>.<function>.williampring.ca

qbittorrent.media.williampring.ca
sonarr.media.williampring.ca
radarr.media.williampring.ca
prowlarr.media.williampring.ca
beszel.monitoring.williampring.ca
grafana.monitoring.williampring.ca
```

---

## Diagrams

| Diagram | Description |
|---------|-------------|
| [Network Topology](docs/diagrams/01-network-topology.md) | Physical nodes, Tailscale mesh, LAN, internet |
| [Request Flow](docs/diagrams/02-request-flow.md) | HTTPS request lifecycle + cert issuance sequence |
| [Pod Architecture](docs/diagrams/03-pod-architecture.md) | Gluetun sidecar pattern, namespace layout |
| [Flannel + Tailscale Routing](docs/diagrams/04-flannel-tailscale-routing.md) | Cross-node pod routing, debugging flowchart |
| [Ingress Stack](docs/diagrams/05-ingress-stack.md) | Traefik DaemonSet, hostPort vs svclb, IngressRoute watch |
| [Decision Flowcharts](docs/diagrams/06-decision-flowcharts.md) | Adding new services, troubleshooting |

---

## Live Services

| URL | Service | Namespace |
|-----|---------|-----------|
| https://qbittorrent.media.williampring.ca | qBittorrent + Gluetun (Mullvad) | vpn |
| https://beszel.monitoring.williampring.ca | Beszel monitoring | monitoring (planned) |
| https://sonarr.media.williampring.ca | Sonarr | vpn (planned) |
| https://radarr.media.williampring.ca | Radarr | vpn (planned) |
| https://prowlarr.media.williampring.ca | Prowlarr | vpn (planned) |

---

## Quick Start

### 1. Master Node Setup
```bash
chmod +x scripts/rock4b-setup.sh
# Edit MULLVAD_PRIVATE_KEY and MULLVAD_ADDRESS at the top
sudo ./scripts/rock4b-setup.sh
```

### 2. Worker Node Setup
```bash
# Copy script to each worker and run
chmod +x scripts/fix-worker.sh
sudo ./scripts/fix-worker.sh
```

### 3. Tailscale Pod CIDR Routes (run on each node after setup)
```bash
# Master
sudo tailscale set --accept-routes --advertise-routes=10.42.0.0/24,192.168.68.0/22

# sourcream-worker
sudo tailscale set --accept-routes --advertise-routes=10.42.1.0/24

# bbq-worker
sudo tailscale set --accept-routes --advertise-routes=10.42.3.0/24
```
Approve routes in Tailscale admin console for each node.

### 4. Deploy cert-manager
```bash
sudo k3s kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml

# Create Cloudflare token secret
sudo k3s kubectl create secret generic cloudflare-token \
  --namespace=cert-manager \
  --from-literal=api-token='<your-cf-token>'

sudo k3s kubectl apply -f k3s/cert-manager/cluster-issuer.yaml
sudo k3s kubectl apply -f k3s/cert-manager/certificates.yaml
```

### 5. Deploy Traefik config
```bash
# Create Cloudflare token secret in kube-system
sudo k3s kubectl create secret generic cloudflare-token \
  --namespace=kube-system \
  --from-literal=api-token='<your-cf-token>'

sudo k3s kubectl apply -f k3s/traefik/traefik-config.yaml
```

### 6. Deploy Services
```bash
# Create Mullvad secret
sudo k3s kubectl create namespace vpn
sudo k3s kubectl create secret generic mullvad-creds \
  --namespace=vpn \
  --from-literal=private-key='<mullvad-private-key>' \
  --from-literal=address='<mullvad-address>/32'

# Deploy qBittorrent + Gluetun
sudo k3s kubectl apply -f k3s/namespace/vpn/vpn-stack.yaml

# Create cert in vpn namespace (Traefik reads Secrets from same namespace as IngressRoute)
sudo k3s kubectl apply -f k3s/cert-manager/vpn-certificate.yaml

# Create IngressRoutes
sudo k3s kubectl apply -f k3s/namespace/vpn/ingress.yaml
sudo k3s kubectl apply -f k3s/namespace/vpn/redirect-middleware.yaml
```

---

## Repository Structure

```
Homelab/
├── README.md
├── docs/
│   ├── architecture.md          # detailed architecture explanation
│   ├── debugging-runbook.md     # known issues + fixes
│   └── platform-decisions.md   # why we chose X over Y
├── scripts/
│   ├── rock4b-setup.sh          # master node setup (steps 1-4)
│   └── fix-worker.sh            # worker node fix script
└── k3s/
    ├── cert-manager/
    │   ├── cluster-issuer.yaml
    │   └── certificates.yaml
    ├── traefik/
    │   └── traefik-config.yaml
    ├── namespace/
    │   └── vpn/
    │       ├── vpn-stack.yaml
    │       └── ingress.yaml
    └── monitoring/
        └── beszel/
            ├── beszel-hub.yaml
            ├── beszel-agent-master.yaml
            └── beszel-agent-worker.yaml
```
