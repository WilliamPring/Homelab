# Homelab — conventions (for people and for AI tools)

This repo is a personal k3s homelab, deployed by Argo CD from git. Read this before changing anything.

## Ground rules
- **Never run `git commit` or `git push`.** The owner does all git operations.
- **Nothing deploys by itself.** Argo sync is MANUAL for every app; Renovate never automerges.
  Changing a manifest = a PR/push + the owner clicking Sync. Do not add `automated:` sync policies.
- **Pin everything.** Image tags, chart versions, tool versions. `latest` and `"*"` are invisible to Renovate.
  A Helm chart that also picks the APP version (its `appVersion`) gets the app's image tag pinned in `values.yaml`
  too, with a Renovate custom manager — `kubernetes/apps/media/immich/values.yaml` is the example.
- **Secrets**: OpenBao (`https://192.168.68.91:8200`, a Proxmox LXC) + External Secrets Operator. Pattern =
  `externalsecret.yaml` in the app directory, listed in `resources:`, reading `homelab/<app>`. A secret VALUE is
  never in git; the KEY NAMES are, on purpose, so CI can check every `secretKeyRef` against them.
  ⚠️ ESO writes the Secret only when EVERY key it lists exists in OpenBao — add the key there BEFORE syncing, or
  that app's whole Secret stops updating. Docs: `docs/platform/openbao.md`. Never put OpenBao behind the
  Cloudflare tunnel.
  **SOPS/age/KSOPS was retired in Nov 2026** with the last app (qBittorrent). Do not reintroduce `*.enc.yaml`,
  `*.sops.yaml` or `generators:` — and do not re-add the repo-server tool overrides that came with KSOPS.
  **Still inline, by the owner's choice while testing:** Suwayomi's login and the Bark device-key placeholders.
  Do not "fix" those unasked — see the known debt in `docs/platform/openbao.md`.
- **One owner per thing.** Ansible = nodes (Tailscale, k3s, the few out-of-git secrets/labels). Argo = every app.
- **Hostnames** are `*.williampring.ca` → the master's Tailscale IP (DNS-only). Internet-facing exceptions:
  `public-immich.` (Immich share proxy), and `deploy.` (Argo CD) + `bark.` via a Cloudflare tunnel → NPMplus (no Ingress here).

## Layout
- `kubernetes/apps/<namespace>/<app>/` — every app's manifests. Directory name = Argo app name; parent = its namespace.
- `kubernetes/bootstrap/argocd/` — Argo's own install (pinned upstream URL + patches). Applied with `kubectl apply -k … -n argocd`.
- `kubernetes/bootstrap/apps.yaml` — the ApplicationSet: every `kubernetes/apps/<namespace>/<app>/` directory becomes an
  Application automatically. New app = new directory. Never hand-write Application files.
- `ansible/` — node provisioning. `docs/` — one doc per app + platform docs. `scripts/ci/` — validation.

## Shape of an app directory
- `kustomization.yaml` listing the resources (including `externalsecret.yaml` if it has a secret).
- `deployment.yaml` (pinned image, resources, a readiness probe on EVERY container — sidecars too, since one unready
  container takes the whole pod out of its Service), `service.yaml` (NodePort if LAN access is wanted — pick a free
  port from the README table), `ingress.yaml` (Traefik + `cert-manager.io/cluster-issuer: letsencrypt`), `storage.yaml`
  (NFS PV/PVC for precious data on 192.168.68.50; local-path PVC for rebuildable state).
- Heavy apps carry `nodeSelector: immich-node: "true"` (the 32GB worker). Containers run as uid 1000 to match NFS.
- Databases: the external Postgres LXC (192.168.68.7), one role per app. Redis: the external Valkey (192.168.68.103), one ACL user per app.

## Every change ships with
- `./scripts/ci/validate.sh` green (renders every app, helm charts included, kubeconform; `make validate`).
- `make lint` clean (yamllint; warnings for long comment lines are fine).
- The app's doc in `docs/` updated, and a Homepage tile + Gatus endpoint for anything user-facing.
- Renovate able to see any new version pin (image tag / chart version).

## Notifications
- **Bark** (`kubernetes/apps/monitoring/bark`, iOS push via APNs) is the primary channel for Argo deploy events, Gatus
  outages and Alertmanager pod alerts (via `bark-relay` in `kube-prometheus-stack/`), and the ONLY channel (ntfy was retired). Bark has NO Ingress/cert on purpose — the owner fronts it
  with NPMplus. Device key is inline for now (testing stance).

## Adding an app
Follow `docs/platform/adding-an-app.md` (checklist + why). Skeleton: `kubernetes/templates/app/`. The ApplicationSet
registers any new `kubernetes/apps/<namespace>/<app>/` directory — never hand-write Application files.
Learning the workflow from scratch: `docs/learn/onboarding-an-app.md` (a guided lab with a throwaway app).

## When unsure
Check how `kubernetes/apps/apps/wealthfolio/` does it — it is the smallest complete example (manifests + an
ExternalSecret from OpenBao + docs/apps/wealthfolio.md). Every app now follows that shape — nothing uses SOPS.
