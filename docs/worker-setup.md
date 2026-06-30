# Worker Node Setup

## k3s Agent Service Configuration

Each worker needs the following in `/etc/systemd/system/k3s-agent.service`:

```ini
ExecStart=/usr/local/bin/k3s \
    agent \
    --flannel-iface=tailscale0 \
    --node-ip=<tailscale-ip>
```

And `/etc/systemd/system/k3s-agent.service.env`:

```
K3S_URL=https://100.96.33.73:6443
K3S_TOKEN=<token-from-master>
```

Get token from master: `sudo cat /var/lib/rancher/k3s/server/node-token`

## Tailscale Configuration

Workers must advertise their pod CIDR and accept routes:

```bash
# Replace 10.42.X.0/24 with the actual pod CIDR assigned to this node
sudo tailscale set --accept-routes --advertise-routes=10.42.X.0/24
```

Find a node's pod CIDR:
```bash
sudo k3s kubectl get node <node-name> -o jsonpath='{.spec.podCIDR}'
```

Approve the route in Tailscale admin console → Machines → node → Edit route settings.

**IMPORTANT**: Never run `tailscale up --reset` on a worker without re-advertising the pod CIDR afterward. Resetting Tailscale wipes the advertised routes, breaking cross-node pod communication.

## NetworkManager

Make the ethernet connection system-wide (brings up without user login):

```bash
sudo nmcli connection modify "Wired connection 1" connection.permissions ""
sudo nmcli connection modify "Wired connection 1" connection.autoconnect yes
sudo nmcli connection modify "Wired connection 1" connection.autoconnect-priority 100
```

## Disable Suspend

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo systemctl set-default multi-user.target
```

## iptables Backend

Set to legacy for k3s compatibility:

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

## Tailscale Boot Ordering

Ensure Tailscale starts after network is fully up:

```bash
sudo mkdir -p /etc/systemd/system/tailscaled.service.d
sudo tee /etc/systemd/system/tailscaled.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
EOF
sudo systemctl enable NetworkManager-wait-online.service
sudo systemctl daemon-reload
```
