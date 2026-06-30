#!/usr/bin/env bash
set -euo pipefail

# ─── FILL THESE IN BEFORE RUNNING ─────────────────────────────────────────────
MULLVAD_PRIVATE_KEY="<your-wireguard-private-key>"
MULLVAD_ADDRESS="<your-wireguard-address>"        # e.g. 10.65.45.2/32
MULLVAD_COUNTRY="Canada"
# ──────────────────────────────────────────────────────────────────────────────

LAN_SUBNET="192.168.68.0/22"

check_placeholders() {
  if [[ "$MULLVAD_PRIVATE_KEY" == "<your-wireguard-private-key>" || \
        "$MULLVAD_ADDRESS" == "<your-wireguard-address>/32" ]]; then
    echo "ERROR: Fill in MULLVAD_PRIVATE_KEY and MULLVAD_ADDRESS at the top of this script."
    exit 1
  fi
}

step1_system_prep() {
  echo "==> Step 1: System prep"
  sudo apt update && sudo apt upgrade -y
  sudo apt install -y curl iptables

  # /dev/net/tun is required by Gluetun
  if [[ ! -c /dev/net/tun ]]; then
    sudo mkdir -p /dev/net
    sudo mknod /dev/net/tun c 10 200
    echo "Created /dev/net/tun"
  fi

  cat <<'EOF' | sudo tee /etc/sysctl.d/99-forwarding.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
  sudo sysctl --system

  # Bookworm defaults to cgroup v2 only — k3s needs memory cgroup enabled
  CMDLINE_FILE="/boot/firmware/cmdline.txt"
  if [[ -f "$CMDLINE_FILE" ]]; then
    if ! grep -q "cgroup_enable=memory" "$CMDLINE_FILE"; then
      sudo sed -i 's/$/ cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory/' "$CMDLINE_FILE"
      echo "cgroup args added to $CMDLINE_FILE — reboot required before continuing."
      echo "Re-run this script after reboot."
      exit 0
    fi
  else
    echo "WARNING: $CMDLINE_FILE not found — verify cgroup config manually."
  fi
}

step2_tailscale() {
  echo "==> Step 2: Tailscale"
  if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    echo "Tailscale already installed, skipping install."
  fi

  sudo systemctl enable --now tailscaled

  sudo tailscale up \
    --advertise-routes="$LAN_SUBNET" \
    --accept-routes \
    --accept-dns=false

  TAILSCALE_IP=$(tailscale ip -4)
  echo "Tailscale IP: $TAILSCALE_IP"
  echo "ACTION REQUIRED: Approve the subnet route in the Tailscale admin console:"
  echo "  https://login.tailscale.com/admin/machines"
  echo "  -> this node -> Edit route settings -> approve $LAN_SUBNET"
}

step3_k3s() {
  echo "==> Step 3: k3s"
  if command -v k3s &>/dev/null; then
    echo "k3s already installed, skipping install."
    return
  fi

  TAILSCALE_IP=$(tailscale ip -4)

  curl -sfL https://get.k3s.io | sh -s - \
    --node-ip="$TAILSCALE_IP" \
    --advertise-address="$TAILSCALE_IP" \
    --flannel-iface=tailscale0 \
    --disable=traefik

  # Wait for node to become Ready
  echo "Waiting for k3s node to be Ready..."
  until sudo k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    sleep 3
  done

  echo "k3s node is Ready."

  # Convenience alias
  if ! grep -q "alias kubectl='k3s kubectl'" ~/.bashrc; then
    echo "alias kubectl='k3s kubectl'" >> ~/.bashrc
  fi
}

step4_mullvad_secret() {
  echo "==> Step 4: Mullvad secret"

  # Create namespace if it doesn't exist
  if ! sudo k3s kubectl get namespace vpn &>/dev/null; then
    sudo k3s kubectl create namespace vpn
  fi

  # Delete and recreate so re-runs are idempotent
  sudo k3s kubectl delete secret mullvad-creds -n vpn --ignore-not-found

  sudo k3s kubectl create secret generic mullvad-creds \
    --namespace=vpn \
    --from-literal=private-key="$MULLVAD_PRIVATE_KEY" \
    --from-literal=address="$MULLVAD_ADDRESS"

  echo "Mullvad secret created in namespace 'vpn'."
}

main() {
  check_placeholders
  step1_system_prep
  step2_tailscale
  step3_k3s
  step4_mullvad_secret

  echo ""
  echo "==> Done. Steps 1-4 complete."
  echo "    Next: deploy Gluetun + qBittorrent (Step 5)."
  echo "    Run 'source ~/.bashrc' or open a new shell to use the kubectl alias."
}

main
