# Network Topology

## Physical + Overlay Network

```mermaid
graph TB
    subgraph Devices["Client Devices"]
        MAC["💻 Mac\n100.x.x.x"]
        iPhone["📱 iPhone\n100.78.220.105"]
        PC["🖥️ PC\n100.x.x.x"]
    end

    subgraph Tailscale["Tailscale Mesh (WireGuard)"]
        TS["Tailscale Coordination Server\ntailscale.com"]
    end

    subgraph LAN["Home LAN — 192.168.68.0/22"]
        subgraph Master["pringles-master — 192.168.68.115 / 100.96.33.73"]
            K3S_M["k3s control plane"]
            TS_M["tailscale0\n100.96.33.73"]
            POD_M["Pod CIDR\n10.42.0.0/24"]
        end

        subgraph Worker1["sourcream-worker — 192.168.68.116 / 100.111.74.14"]
            K3S_W1["k3s agent"]
            TS_W1["tailscale0\n100.111.74.14"]
            POD_W1["Pod CIDR\n10.42.1.0/24"]
        end

        subgraph Worker2["bbq-worker — 192.168.68.118 / 100.82.180.67"]
            K3S_W2["k3s agent"]
            TS_W2["tailscale0\n100.82.180.67"]
            POD_W2["Pod CIDR\n10.42.3.0/24"]
        end

        Router["🔀 Router\n192.168.68.1"]
    end

    subgraph Internet["Internet"]
        CF["☁️ Cloudflare DNS\n*.media.williampring.ca\n*.monitoring.williampring.ca"]
        Mullvad["🔒 Mullvad VPN\nCanada / Toronto"]
        LE["🔐 Let's Encrypt\nACME v2"]
    end

    MAC <-->|"WireGuard tunnel"| TS
    iPhone <-->|"WireGuard tunnel"| TS
    PC <-->|"WireGuard tunnel"| TS
    TS <--> TS_M
    TS <--> TS_W1
    TS <--> TS_W2

    TS_M <-->|"pod CIDR routes\nvia Tailscale"| TS_W1
    TS_M <-->|"pod CIDR routes\nvia Tailscale"| TS_W2
    TS_W1 <-->|"pod CIDR routes\nvia Tailscale"| TS_W2

    Master <--> Router
    Worker1 <--> Router
    Worker2 <--> Router
    Router <--> Internet

    CF -->|"DNS resolves to\nTailscale IPs"| MAC
    Mullvad <-->|"Gluetun WireGuard\ntunnel (per pod)"| Master
    LE <-->|"DNS-01 challenge\nvia Cloudflare API"| CF
```

## Key Points

- All inter-node pod traffic travels over the **Tailscale WireGuard tunnel**, not the LAN
- Each node advertises its pod CIDR (`10.42.x.0/24`) as a Tailscale subnet route
- Client devices reach services via Tailscale IPs (`100.x.x.x`), not LAN IPs
- Cloudflare DNS resolves subdomains to Tailscale IPs (DNS only, no proxy)
- Only media pods (qBittorrent, Arr stack) egress via Mullvad
