#!/usr/bin/env bash
set -euo pipefail

# Run this on any worker node to:
# 1. Fix Tailscale (remove bad flags)
# 2. Fix k3s agent flannel interface + node-ip
# 3. Fix network autoconnect

MASTER_IP="100.96.33.73"

fix_network() {
  echo "==> Fixing NetworkManager autoconnect"
  CONN=$(nmcli -f NAME,TYPE con show | grep ethernet | awk '{$NF=""; sub(/[[:space:]]+$/, ""); print}')
  if [[ -n "$CONN" ]]; then
    sudo nmcli connection modify "$CONN" connection.permissions ""
    sudo nmcli connection modify "$CONN" connection.autoconnect yes
    sudo nmcli connection modify "$CONN" connection.autoconnect-priority 100
    echo "Fixed: $CONN"
  else
    echo "WARNING: No ethernet connection found"
  fi
}

fix_tailscale() {
  echo "==> Fixing Tailscale"
  sudo systemctl stop tailscaled
  sudo rm -rf /var/lib/tailscale
  sudo mkdir -p /var/lib/tailscale
  sudo systemctl start tailscaled
  sleep 3
  sudo tailscale up --reset --accept-dns=false
  echo "Tailscale IP: $(tailscale ip -4)"
}

fix_k3s_agent() {
  echo "==> Fixing k3s agent"
  TAILSCALE_IP=$(tailscale ip -4)

  if command -v k3s &>/dev/null; then
    # Already installed — just update the service file
    sudo tee /etc/systemd/system/k3s-agent.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/k3s agent --flannel-iface=tailscale0 --node-ip=${TAILSCALE_IP}
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart k3s-agent
    echo "k3s agent updated with node-ip=${TAILSCALE_IP}"
  else
    # Not installed — prompt for token
    read -p "Enter k3s node token from master (sudo cat /var/lib/rancher/k3s/server/node-token): " TOKEN
    curl -sfL https://get.k3s.io | \
      K3S_URL=https://${MASTER_IP}:6443 \
      K3S_TOKEN=${TOKEN} \
      sh -s - \
      --node-ip=${TAILSCALE_IP} \
      --flannel-iface=tailscale0
    echo "k3s agent installed with node-ip=${TAILSCALE_IP}"
  fi
}

fix_suspend() {
  echo "==> Disabling suspend/sleep"
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  sudo systemctl set-default multi-user.target

  # logind
  sudo sed -i 's/#IdleAction=ignore/IdleAction=ignore/' /etc/systemd/logind.conf
  sudo sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' /etc/systemd/logind.conf
  sudo sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
  sudo systemctl restart systemd-logind

  # Quiet kernel messages
  echo "kernel.printk = 3 3 3 3" | sudo tee /etc/sysctl.d/99-quiet.conf
  sudo sysctl --system
}

fix_tailscale_boot() {
  echo "==> Fixing Tailscale boot ordering"
  sudo mkdir -p /etc/systemd/system/tailscaled.service.d
  sudo tee /etc/systemd/system/tailscaled.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
EOF
  sudo systemctl enable NetworkManager-wait-online.service
  sudo systemctl daemon-reload
}

main() {
  fix_network
  fix_suspend
  fix_tailscale_boot
  fix_tailscale
  fix_k3s_agent

  echo ""
  echo "==> Done. Reboot to confirm everything works."
  echo "    After reboot, verify on master: sudo k3s kubectl get nodes -o wide"
  read -p "Reboot now? (y/n): " answer
  if [[ "$answer" == "y" ]]; then
    sudo reboot
  fi
}

main
