# Debugging Runbook

## TLS Secret Not Found (Traefik Default Cert Served)

**Symptom:** Browser shows "TRAEFIK DEFAULT CERT" instead of Let's Encrypt cert.

**Cause:** Traefik looks for the TLS Secret in the same namespace as the IngressRoute. If the Certificate was created in `kube-system` but the IngressRoute is in `vpn`, Traefik can't find it.

**Fix:** Create a Certificate in the same namespace as the IngressRoute:
```bash
sudo k3s kubectl apply -f k3s/cert-manager/vpn-certificate.yaml
sudo k3s kubectl get certificate -n vpn -w
```

---

## HTTP Not Redirecting to HTTPS

**Symptom:** `http://service.media.williampring.ca` returns 404 instead of 301 redirect.

**Cause:** Traefik v3 `redirectTo` in Helm values doesn't always work reliably. Use an explicit redirect Middleware instead.

**Fix:** Apply the redirect middleware:
```bash
sudo k3s kubectl apply -f k3s/namespace/vpn/redirect-middleware.yaml
```

Verify:
```bash
curl -v http://qbittorrent.media.williampring.ca 2>&1 | grep -i "location\|HTTP/"
# Should return: HTTP/1.1 301 Moved Permanently + Location: https://...
```

---

## Traefik DaemonSet — Stale Pending Pod

**Symptom:** 4 Traefik pods exist but only 3 nodes. One pod stuck Pending with "didn't have free ports".

**Cause:** Old pod from previous Deployment/DaemonSet generation still holding hostPort 80/443 on a node.

**Fix:**
```bash
# Find the old pod (it's the one NOT on any node in -o wide)
sudo k3s kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik -o wide
sudo k3s kubectl delete pod <old-pod-name> -n kube-system
```

---

## Traefik DaemonSet Conversion Failed (Helm ACME Error)

**Symptom:** Helm job fails with: `ACME functionality is not supported when running Traefik as a DaemonSet`

**Cause:** Built-in ACME (`additionalArguments` with `certificatesresolvers`) can't run on DaemonSet because `acme.json` PVC is RWO (single node only).

**Fix:** Remove all `certificatesresolvers` and `persistence` blocks from `traefik-config.yaml`. cert-manager handles certs instead — stored as k8s Secrets accessible by all nodes.

---

## Cross-Node Pod Communication Broken

**Symptom:** Pods on different nodes can't communicate. API server returns 502. `ping` to pod IPs on other nodes fails or routes through public internet.

**Check:**
```bash
ping -c 3 10.42.1.1   # sourcream-worker gateway
ping -c 3 10.42.3.1   # bbq-worker gateway
```

**Root cause:** Tailscale pod CIDR routes were wiped (happens after `tailscale up --reset`).

**Fix:**
```bash
# On pringles-master
sudo tailscale set --accept-routes --advertise-routes=10.42.0.0/24,192.168.68.0/22

# On sourcream-worker
sudo tailscale set --accept-routes --advertise-routes=10.42.1.0/24

# On bbq-worker
sudo tailscale set --accept-routes --advertise-routes=10.42.3.0/24
```

Then approve routes in Tailscale admin console for each node.

**Verify:**
```bash
sudo tailscale debug netmap | grep "10.42"
ping -c 3 10.42.1.1
```

---

## cert-manager Webhook 502

**Symptom:**
```
Internal error: failed calling webhook "webhook.cert-manager.io": 
Post "https://cert-manager-webhook.cert-manager.svc:443": proxy error 502
```

**Root cause:** cert-manager webhook pod is on a node the API server can't reach (cross-node routing broken).

**Fix:** Fix cross-node routing first (see above). Then retry the apply.

---

## SSH Not Working After Reboot (LAN IP)

**Symptom:** Can SSH via Tailscale IP but not LAN IP (`192.168.68.x`). Board requires local login first.

**Cause 1:** NetworkManager connection has user-level permissions (requires login).
```bash
sudo nmcli connection modify "Wired connection 1" connection.permissions ""
sudo nmcli connection modify "Wired connection 1" connection.autoconnect-priority 100
```

**Cause 2:** `--accept-routes` was set on a worker. This routes LAN traffic through Tailscale (master's subnet advertisement) instead of directly via eth0.
```bash
sudo tailscale up --reset --accept-dns=false
# Workers should NOT use --accept-routes
```

**Cause 3:** Tailscale starts before network is ready.
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

---

## Traefik Not Routing (Gateway Timeout)

**Symptom:** `https://service.media.williampring.ca` returns 504 Gateway Timeout.

**Check where Traefik and the target pod are running:**
```bash
sudo k3s kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik -o wide
sudo k3s kubectl get pods -n vpn -o wide
```

If they're on different nodes → cross-node routing issue. Fix pod CIDR routes (see above).

**Check if Traefik can reach the service:**
```bash
sudo k3s kubectl exec -n kube-system deployment/traefik -- wget -qO- http://<pod-ip>:8080
```

---

## Traefik hostPort Not Listening

**Symptom:** `curl -v https://100.96.33.73` returns "No route to host" or connection refused.

**Check which node Traefik is on:**
```bash
sudo k3s kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik -o wide
```

Traefik's hostPort only binds on the node it's running on. Test that node's Tailscale IP directly.

**Check if hostPort is in the config:**
```bash
sudo k3s kubectl get pod -n kube-system -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].spec.containers[0].ports}' | python3 -m json.tool
```

---

## iptables Rules Not Working

**Symptom:** iptables rules from k3s not taking effect, svclb pods running but ports not forwarding.

**Check backend:**
```bash
sudo update-alternatives --query iptables | grep Value
```

If `Value: /usr/sbin/iptables-nft`, switch to legacy:
```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
sudo k3s kubectl delete pods -n kube-system -l svccontroller.k3s.cattle.io/svcname=traefik
```

---

## Gluetun Tunnel Not Connecting (i/o timeout loop)

**Symptom:** Gluetun logs show repeated i/o timeout, cycling through servers.

**Check:**
```bash
sudo k3s kubectl logs -n vpn deploy/qbittorrent -c gluetun | tail -20
```

**Cause:** Wrong or revoked Mullvad WireGuard credentials.

**Fix:**
1. Go to mullvad.net → Account → WireGuard keys → generate new key
2. Download fresh `.conf` file
3. Update the secret:
```bash
sudo k3s kubectl delete secret mullvad-creds -n vpn
sudo k3s kubectl create secret generic mullvad-creds \
  --namespace=vpn \
  --from-literal=private-key="<new-key>" \
  --from-literal=address="<new-address>/32"
sudo k3s kubectl rollout restart deploy/qbittorrent -n vpn
```

---

## qBittorrent "Unauthorized" on Web UI

**Symptom:** Web UI returns plain "Unauthorized" text.

**Cause:** qBittorrent 5.x blocks requests where the Host header doesn't match. Config file doesn't have `HostHeaderValidation=false`.

**Fix:** Pre-populate the config before pod starts:
```bash
sudo mkdir -p /opt/qbittorrent/config/qBittorrent
sudo tee /opt/qbittorrent/config/qBittorrent/qBittorrent.conf <<'EOF'
[Preferences]
WebUI\Address=*
WebUI\ServerDomains=*
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
EOF
```

This directory must exist on whichever node the pod runs on.

---

## Traefik DaemonSet Conversion Failed (No Pods)

**Symptom:** Applied DaemonSet config via HelmChartConfig, Helm job completed but no Traefik pods exist.

**Cause:** Helm can't convert a `Deployment` to a `DaemonSet` in-place. Old Deployment was deleted, new DaemonSet failed to create.

**Fix:** Revert to Deployment first, then do a proper migration:
```bash
# Remove deployment.kind: DaemonSet from HelmChartConfig
sudo k3s kubectl apply -f k3s/traefik/traefik-config.yaml
# Wait for Traefik to come back as Deployment
# Then delete Deployment manually and re-apply DaemonSet config
```

---

## Node Shows Wrong INTERNAL-IP

**Symptom:** `kubectl get nodes -o wide` shows LAN IP instead of Tailscale IP for a worker.

**Cause:** Worker k3s-agent is missing `--node-ip=<tailscale-ip>` flag.

**Fix:**
```bash
# On the worker
sudo nano /etc/systemd/system/k3s-agent.service
# Add --node-ip=<tailscale-ip> to ExecStart
sudo systemctl daemon-reload
sudo systemctl restart k3s-agent
```

Or use the drop-in override:
```bash
sudo mkdir -p /etc/systemd/system/k3s-agent.service.d
sudo tee /etc/systemd/system/k3s-agent.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/k3s agent --flannel-iface=tailscale0 --node-ip=$(tailscale ip -4)
EOF
sudo systemctl daemon-reload && sudo systemctl restart k3s-agent
```
