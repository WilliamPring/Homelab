# Traffic Routing Plan — Gateway API (Option B)

The modern, standardized replacement for Ingress, running on Traefik. This is the
"move apps off NodePort onto real HTTPS hostnames" step (was deferred as "Path B").

## Decisions (locked)
- **Routing API:** Gateway API (`Gateway` + `HTTPRoute`), not Ingress, not Traefik IngressRoute.
- **Controller:** **Traefik v3** (bundled with recent k3s) — it implements Gateway API as a
  *provider* you enable. v3 is REQUIRED (v2's Gateway API support is too weak/experimental);
  the `gateway_api` role fails early if it detects v2. Considered Envoy Gateway (Gateway-API-
  *native*) but chose Traefik v3 for pragmatism (it's already installed, mature, matches the
  existing homelab). Gateway API is vendor-neutral, so the routes stay portable if we ever swap.
- **TLS scope:** a single **`*.williampring.ca`** wildcard cert from the **self-signed homelab
  CA** (cert-manager) — no Cloudflare. (Simple; a self-signed CA has no rate limits.)
- **Gateway namespace:** a dedicated **`gateway`** namespace.
- **First app:** Jellyfin (prove the chain), then everything else via a data-driven list.
- **Ingress topology:** **single-node ingress on the HP.** DNS = ONE wildcard record →
  the HP's IP. The HP runs the apps anyway, so it's the SPOF regardless — pointing all
  node IPs at DNS + "CF load balancing" is NOT real LB (just round-robin, no health checks,
  and CF can't proxy private Tailscale IPs). MetalLB (a floating VIP) is the real-failover
  upgrade — deferred until a 2nd capable node exists.

## The mental model
Gateway API splits routing into role-based resources (vs Ingress cramming it all in one):
```
GatewayClass  → names the controller (Traefik)              [platform]
Gateway       → the entry point: port 443, TLS, who may attach [infra/you]
HTTPRoute     → hostname → Service for one app               [per app]
ReferenceGrant→ permit cross-namespace refs (if needed)
```

## The traffic path
```
Client (Tailscale) → DNS: *.williampring.ca → HP IP
  → Traefik/Gateway on the HP (hostPort 443)
  → HTTPRoute (match hostname) → Service (ClusterIP) → Pod
  → TLS terminated with the *.williampring.ca cert (self-signed homelab CA)
```

## Build phases (implemented as Ansible, gated by `gateway_api_enabled`)

### Phase 0 — Foundations
- **Re-enable cert-manager + the self-signed CA** (`certmanager_enabled: true`). Gateway TLS
  needs it. cert-manager mints the wildcard secret from `homelab-ca-issuer`.
- **Install Gateway API CRDs** (not in k8s core): `standard-install.yaml`, pinned version.
- **Enable Traefik's Gateway provider** via a `HelmChartConfig` (⚠️ exact key is Traefik-
  version-specific — VERIFY).

### Phase 1 — The Gateway (`roles/gateway_api`)
- `gateway` namespace, `GatewayClass` (traefik), wildcard `Certificate` (→ `wildcard-tls`
  secret), and the `Gateway` (HTTPS:443, hostname `*.williampring.ca`, `allowedRoutes:
  from: All`).

### Phase 2 — Routes (`roles/httproute`, data-driven)
- `vars/routes.yml` — a list `{name, namespace, hostname, service, port}`.
- A play loops `include_role: httproute` over it (same pattern as `helm_releases`) → one
  `HTTPRoute` per app. Add an app's route = one data line.

### Phase 3 — Cleanup (later)
- Switch app Services **NodePort → ClusterIP** (a NodePort still has a ClusterIP, so routing
  works either way — this is just tidy-up).

### Phase 4 — DNS
- **One** record: `*.williampring.ca → <HP IP>` (DNS-only / Tailscale). Not all node IPs.
- For testing on the VMs before the HP: use Pi-hole local DNS records or `/etc/hosts`.

## Toggles
- `certmanager_enabled: true` — cert-manager + self-signed CA (required by the Gateway).
- `gateway_api_enabled: true` — CRDs + Traefik provider + Gateway + HTTPRoutes.
  (Set BOTH true to bring up Gateway API TLS ingress.)

## VERIFY-ON-DEPLOY (the version-specific bits)
1. **Traefik Gateway provider values** in the `HelmChartConfig` — the exact keys differ by
   the Traefik version k3s ships. Check `traefik --help` / Traefik docs for your version.
2. **cert-manager ↔ Gateway** — we use the *manual Certificate → secret* approach (Gateway
   listener references `wildcard-tls`) to avoid cert-manager's experimental Gateway feature-gate.
3. **Gateway API CRD version** — pin one compatible with your Traefik version.

## Coexistence
Your OLD apps can keep using Traefik `IngressRoute` while new apps use `HTTPRoute` — migrate
gradually, no big-bang.
