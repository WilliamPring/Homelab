# Homelab — conventions (for people and for AI tools)

This repo is a personal k3s homelab, deployed by Argo CD from git. Read this before changing anything.

## Ground rules
- **Never run `git commit` or `git push`.** The owner does all git operations.
- **Nothing deploys by itself.** Argo sync is MANUAL for every app; Renovate never automerges.
  Changing a manifest = a PR/push + the owner clicking Sync. Do not add `automated:` sync policies.
- **Pin everything.** Image tags, chart versions, tool versions. `latest` and `"*"` are invisible to Renovate.
- **Secrets**: SOPS + age via KSOPS. Pattern = `<app>-secret.enc.yaml` (encrypted) + `<app>-secret.sops.yaml`
  (generator) + `generators:` in `kustomization.yaml`. Target state: a value is either `ENC[...]` in git or not in git.
  **Current state (by the owner's choice while testing):** placeholder templates and one inline password exist; the
  checks WARN rather than block (`STRICT_SECRETS=0`). Do not "fix" this unasked — see `docs/platform/secrets.md` known debt.
- **One owner per thing.** Ansible = nodes (Tailscale, k3s, the few out-of-git secrets/labels). Argo = every app.
- **Hostnames** are `*.williampring.ca` → the master's Tailscale IP (DNS-only). Only `share.williampring.ca` is public.

## Layout
- `kubernetes/apps/<namespace>/<app>/` — every app's manifests. Directory name = Argo app name; parent = its namespace.
- `kubernetes/bootstrap/argocd/` — Argo's own install (pinned upstream URL + patches). Applied with `kubectl apply -k … -n argocd`.
- `kubernetes/bootstrap/apps.yaml` — the ApplicationSet: every `kubernetes/apps/<namespace>/<app>/` directory becomes an
  Application automatically. New app = new directory. Never hand-write Application files.
- `ansible/` — node provisioning. `docs/` — one doc per app + platform docs. `scripts/ci/` — validation.

## Shape of an app directory
- `kustomization.yaml` listing the resources (and the KSOPS generator if it has a secret).
- `deployment.yaml` (pinned image, resources, probes), `service.yaml` (NodePort if LAN access is wanted — pick a free
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
- **Bark** (`kubernetes/apps/monitoring/bark`, iOS push via APNs) is the primary channel for both Argo deploy events and
  Gatus outages; ntfy is kept only during the switch-over. Bark has NO Ingress/cert on purpose — the owner fronts it
  with NPMplus. Device key is inline for now (testing stance).

## Adding an app
Follow `docs/platform/adding-an-app.md` (checklist + why). Skeleton: `kubernetes/templates/app/`. The ApplicationSet
registers any new `kubernetes/apps/<namespace>/<app>/` directory — never hand-write Application files.

## When unsure
Check how `kubernetes/apps/media/komf/` does it — it is the smallest complete example (manifests + SOPS secret + docs/apps/kavita.md).
