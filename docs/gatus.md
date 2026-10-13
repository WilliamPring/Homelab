# Gatus — uptime checks → ntfy ("is it up right now?")

Gatus probes every service on a schedule and pages your phone through ntfy when something
fails three times in a row, then again when it recovers. Config is one YAML file in git;
history is a small sqlite file. It is the alerting half of monitoring; Grafana/Prometheus (if
they ever return) are the history half — they coexist (see the FAQ at the bottom).

```
gatus (monitoring ns) ──probes──► apps (in-cluster Service URLs)
                      ──probes──► edge (https://*.williampring.ca via Traefik: DNS + cert + ingress)
                      ──probes──► public (share.williampring.ca through Cloudflare)
                      ──probes──► infra (Postgres LXC, Valkey, NFS, Proxmox)
                      ──queries─► dns (Cloudflare records)
                      ──alerts──► ntfy topic `homelab-alerts`  ──► your phone
Dashboard: https://status.williampring.ca   (LAN: http://192.168.68.63:30881)
```

| Argo app | Path | Deploys |
|---|---|---|
| `gatus` | `gitops/gatus` | Deployment, config ConfigMap, 1Gi PVC, NodePort, Ingress — namespace `monitoring` |

---

## Deploy
```
Cloudflare DNS:  status → A → <master's Tailscale IP>   (grey cloud / DNS only)
```
```bash
# the monitoring namespace used to hold Loki/Grafana — clear the orphans first (docs/cluster-cleanup.md §1)
sudo k3s kubectl apply -f gitops/apps/gatus.yaml       # Argo UI → gatus → SYNC
sudo k3s kubectl get pods -n monitoring -w
```
Phone: ntfy app → **+** → topic `homelab-alerts` (same server as `homelab-argocd`).

Open https://status.williampring.ca. Within ~5 minutes every endpoint has run at least once.
Expected on day one: everything green except things that genuinely are not there yet (e.g.
RomM/Komf if not synced). Fix or delete those entries rather than living with red.

## How alerts behave
- `failure-threshold: 3` → an endpoint must fail 3 checks in a row before you are paged
  (1-minute checks ⇒ ~3 min; 5-minute checks ⇒ ~15 min). No flapping noise.
- `send-on-resolved: true` → one more message when it is back.
- Priority 4 (high) on ntfy — vibrates, no override of Do Not Disturb. Raise to 5 for specific
  endpoints if you want them to break through.
- If **ntfy itself** is down nothing can page you; the dashboard still shows it red.

## Editing checks
Everything is in `gitops/gatus/configmap.yaml`. Add an endpoint = copy a block, change name/url/
conditions, push, Sync. **Gatus reads its config at start**, so after a Sync that changes the
ConfigMap: `sudo k3s kubectl -n monitoring rollout restart deploy/gatus` (CI validates the YAML).

Useful conditions: `[STATUS] == 200` · `[BODY].field == value` · `[RESPONSE_TIME] < 3000` ·
`[CERTIFICATE_EXPIRATION] > 168h` · `[CONNECTED] == true` (tcp) · `[DNS_RCODE] == NOERROR`.

When you add an app to the cluster: add its in-cluster URL to `apps` and its hostname to `edge`.

## Troubleshooting
| Symptom | Cause / fix |
|---|---|
| **edge group all red, apps green** | pods can't reach the master's Tailscale IP. Check from a pod: `kubectl run -n monitoring t --rm -it --image=busybox:1.38 -- wget -qO- --no-check-certificate https://library.williampring.ca/api/health`. If that fails, switch edge checks to go via Traefik with a Host header: `url: https://traefik.kube-system.svc.cluster.local`, `headers: {Host: library.williampring.ca}`, `client: {insecure: true}` (you lose the cert-expiry check; keep the `dns` group for the DNS side) |
| one edge check red, its app green | DNS record missing, cert not issued (`kubectl get certificate -A`), or the Ingress host typo'd |
| `suwayomi.williampring.ca` red | its condition is `[STATUS] == 401` on purpose (Basic auth). If you ever turn auth off, change to 200 |
| no pushes arriving | ntfy URL/topic in the ConfigMap; phone subscribed to `homelab-alerts`; `kubectl -n monitoring logs deploy/gatus` shows alert attempts |
| config change not applied | Gatus only reads config at start → `rollout restart` after Sync |
| pod CrashLoop with a YAML error in logs | the ConfigMap failed to parse — `ruby -ryaml -e 'YAML.load(...)'` or just run `./scripts/ci/validate.sh` locally |

## FAQ: Gatus vs Grafana
Gatus answers *is it up now?* and pages you. Grafana answers *what happened over time?* and
needs Prometheus/Loki feeding it. If Grafana comes back, keep Gatus as the alerter and point
Grafana at Gatus's `/metrics` for uptime history. Host metrics (disk, CPU, temps) are a third
thing — Beszel is the light option for that.
