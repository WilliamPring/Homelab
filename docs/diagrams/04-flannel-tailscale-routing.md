# Flannel + Tailscale Routing

## How Pod-to-Pod Traffic Flows Between Nodes

```mermaid
graph TB
    subgraph Master["pringles-master"]
        POD_A["Pod A\n10.42.0.39"]
        CNI_M["cni0 bridge\n10.42.0.1/24"]
        TS_M["tailscale0\n100.96.33.73"]
        RT_M["Route Table\n10.42.1.0/24 → tailscale0\n10.42.3.0/24 → tailscale0"]
    end

    subgraph Worker1["sourcream-worker"]
        TS_W1["tailscale0\n100.111.74.14"]
        CNI_W1["cni0 bridge\n10.42.1.1/24"]
        POD_B["Pod B\n10.42.1.55"]
        RT_W1["Route Table\n10.42.0.0/24 → tailscale0\n10.42.3.0/24 → tailscale0"]
    end

    WG["🔒 WireGuard Tunnel\n(Tailscale)\nEncrypted"]

    POD_A -->|"dest: 10.42.1.55"| CNI_M
    CNI_M -->|"lookup route table"| RT_M
    RT_M -->|"via tailscale0"| TS_M
    TS_M <-->|"encrypted WireGuard"| WG
    WG <-->|"encrypted WireGuard"| TS_W1
    TS_W1 -->|"dest: 10.42.1.55"| RT_W1
    RT_W1 --> CNI_W1
    CNI_W1 --> POD_B

    style WG fill:#90EE90
```

## Flannel Backend Configuration

```mermaid
graph LR
    subgraph Standard["Standard k3s Flannel"]
        VXLAN["VXLAN Backend\nflannel.1 interface\nUDP encapsulation"]
        NOTE1["Pods tunnel via\nVXLAN over LAN\n(unencrypted)"]
        VXLAN --- NOTE1
    end

    subgraph Ours["Our Setup (Tailscale Backend)"]
        EXT["Extension Backend\nPostStartupCommand:\ntailscale set --advertise-routes=\$SUBNET"]
        NOTE2["Pods tunnel via\nWireGuard (Tailscale)\n(encrypted end-to-end)"]
        EXT --- NOTE2
    end

    Standard -->|"we use this instead"| Ours
```

## Route Advertisement — What Must Stay Configured

```mermaid
graph TB
    subgraph Admin["Tailscale Admin Console"]
        APPROVE["Route Approvals\nRequired for each node"]
    end

    subgraph Master["pringles-master"]
        ADV_M["Advertises:\n10.42.0.0/24\n192.168.68.0/22 (LAN subnet)"]
    end

    subgraph W1["sourcream-worker"]
        ADV_W1["Advertises:\n10.42.1.0/24"]
    end

    subgraph W2["bbq-worker"]
        ADV_W2["Advertises:\n10.42.3.0/24"]
    end

    subgraph Warning["⚠️ Critical Warning"]
        WARN["Running 'tailscale up --reset'\nWIPES all advertised routes.\nFlannel PostStartupCommand\nonly runs on first k3s-agent boot.\nMust re-advertise manually."]
    end

    ADV_M --> APPROVE
    ADV_W1 --> APPROVE
    ADV_W2 --> APPROVE

    style Warning fill:#ffcccc
    style WARN fill:#ffcccc
```

## Debugging Cross-Node Routing

```mermaid
flowchart TD
    START["Pod-to-Pod communication failing"] --> CHECK1

    CHECK1["Check: Can master ping worker pod gateway?\nping -c 3 10.42.1.1\nping -c 3 10.42.3.1"]

    CHECK1 -->|"ping fails"| FIX1
    CHECK1 -->|"ping works"| CHECK2

    FIX1["Fix: Re-advertise pod CIDRs\nsudo tailscale set --accept-routes\n  --advertise-routes=10.42.x.0/24\nApprove in Tailscale admin console"]

    FIX1 --> CHECK1

    CHECK2["Check: Are routes in netmap?\nsudo tailscale debug netmap | grep 10.42"]
    CHECK2 -->|"routes missing"| FIX1
    CHECK2 -->|"routes present"| CHECK3

    CHECK3["Check: Are iptables backends matching?\nsudo update-alternatives --query iptables | grep Value"]
    CHECK3 -->|"iptables-nft"| FIX2
    CHECK3 -->|"iptables-legacy"| CHECK4

    FIX2["Fix: Switch to legacy\nsudo update-alternatives --set iptables /usr/sbin/iptables-legacy"]
    FIX2 --> CHECK3

    CHECK4["Check: k3s-agent logs for flannel errors\nsudo journalctl -u k3s-agent -n 50 | grep -i flannel"]

    style FIX1 fill:#90EE90
    style FIX2 fill:#90EE90
    style START fill:#ffcccc
```
