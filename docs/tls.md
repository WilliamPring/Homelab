# TLS — cert-manager + Let's Encrypt (Cloudflare DNS-01), on Argo CD

Every `https://*.williampring.ca` hostname gets a real Let's Encrypt certificate from
**cert-manager**, validated with a Cloudflare **DNS-01** TXT record — so certs issue even though
nothing is reachable from the internet (hosts are Tailscale-only).

```
Ingress  (annotation: cert-manager.io/cluster-issuer: letsencrypt)
   │  ingress-shim creates a Certificate → CertificateRequest → Order → Challenge
   ▼
ClusterIssuer "letsencrypt"  ── Cloudflare API token ──►  TXT _acme-challenge.<host>  ──►  Let's Encrypt
   │
   ▼
Secret <app>-tls  (Traefik serves it)
```

| Argo app | Source | Deploys | Sync order |
|---|---|---|---|
| `cert-manager` | Helm chart `jetstack/cert-manager` + `gitops/cert-manager/values.yaml` | CRDs, controller, webhook, cainjector (ns `cert-manager`) | **1st** |
| `cert-manager-issuer` | `gitops/cert-manager/issuer/` | the `letsencrypt` ClusterIssuer | 2nd (needs the CRDs) |

Out of git, hand-created once: the **`cloudflare-api-token`** Secret in `cert-manager`
(`docs/secrets.md`). Everything else is reproducible from the repo.

---

## Migration from the Ansible install (one-time — do this now)

cert-manager used to be installed by the Ansible `certmanager` role from the static release
manifest, at **v1.17.2**. The Helm chart renders the *same* objects with the same names and
labels, so Argo's first Sync **adopts the running install in place**. Certificates, the ACME
account key and the Cloudflare token are untouched.

cert-manager's rule: **upgrade one minor at a time**, latest patch of each. The app is pinned
to `v1.18.6` for that reason. Renovate then opens one PR per minor (`1.19`, `1.20`, `1.21`) —
merge and Sync them in order, reading each release's upgrade notes. Nothing in the notes for
1.18 → 1.21 affects this setup (no custom RBAC, no ServiceMonitor, no direct Order/Challenge
creation); 1.18 changes new Certificates' default `rotationPolicy` to `Always`, which is fine.

```bash
# 0. snapshot of what works today
sudo k3s kubectl get certificate -A                         # all READY=True — note the list
sudo k3s kubectl -n cert-manager get deploy -o wide          # v1.17.2 images

# 1. register both apps (by hand — no app-of-apps yet)
sudo k3s kubectl apply -f gitops/apps/cert-manager.yaml
sudo k3s kubectl apply -f gitops/apps/cert-manager-issuer.yaml

# 2. Argo UI → cert-manager → review the diff (expect: image tags 1.17.2→1.18.6, CRD updates,
#    resource limits, Argo tracking labels) → SYNC (plain; ServerSideApply is already set)
sudo k3s kubectl -n cert-manager rollout status deploy/cert-manager
sudo k3s kubectl -n cert-manager rollout status deploy/cert-manager-webhook
sudo k3s kubectl -n cert-manager rollout status deploy/cert-manager-cainjector

# 3. Argo UI → cert-manager-issuer → diff should be labels only → SYNC
sudo k3s kubectl get clusterissuer letsencrypt               # READY True
sudo k3s kubectl get certificate -A                         # same list, all READY=True

# 4. the Ansible side is already updated in git (role removed); nothing to run.
```
Then, over the following weeks: merge the `1.19` PR → Sync → check certs; `1.20`; `1.21`.

---

## Day-to-day

- **New hostname**: add the annotation + `tls:` block to the app's Ingress (copy any existing
  one), add the Cloudflare DNS record (grey cloud → master's Tailscale IP). The cert appears
  in ~1–2 min: `kubectl get certificate -n <ns>`.
- **Renewal** is automatic (cert-manager renews at ⅔ of the 90-day lifetime). Nothing to do.
- **Upgrades**: Renovate PR (label `step-by-minor`) → read
  https://cert-manager.io/docs/releases/upgrading/ for that minor → merge → Sync →
  `kubectl get certificate -A` all READY.
- **Rotating the Cloudflare token**: create a new "Edit zone DNS" token in Cloudflare, then
  ```bash
  sudo k3s kubectl -n cert-manager create secret generic cloudflare-api-token \
    --from-literal=api-token='<NEW>' --dry-run=client -o yaml | sudo k3s kubectl apply -f -
  ```
  Existing certs keep working; the next renewal uses the new token.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Sync fails: `metadata.annotations: Too long: must have at most 262144 bytes` | CRDs too big for client-side apply → `ServerSideApply=true` is in the app's syncOptions; make sure it still is |
| Certificate stuck `READY=False`, Order `pending`, Challenge "propagation" | DNS-01 self-check can't see the TXT record: node resolver (Tailscale MagicDNS / local DNS) → un-comment `dns01RecursiveNameservers*` in `values.yaml`, Sync |
| Challenge: `error listing zones` / `401` | Cloudflare token wrong or lacks *Zone → DNS → Edit* on this zone → rotate (above) |
| Webhook errors during/after upgrade (`x509` / `connection refused`) | cainjector hasn't re-injected the CA yet → wait 1 min; `kubectl -n cert-manager rollout restart deploy/cert-manager-webhook` if it persists |
| Everything READY but browser shows old/expired cert | Traefik caches the Secret briefly; or the Ingress `secretName` differs from the Certificate's → compare |
| `cert-manager-issuer` sync error "no matches for kind ClusterIssuer" | synced before `cert-manager` → Sync cert-manager first, then Hard Refresh + Sync the issuer |

### Handy checks
```bash
sudo k3s kubectl get certificate,certificaterequest,order,challenge -A
sudo k3s kubectl -n cert-manager logs deploy/cert-manager --tail=50
sudo k3s kubectl describe challenge -A | grep -A3 -i reason
```
