# kubernetes/ — everything Argo CD deploys

```
kubernetes/
├── bootstrap/
│   ├── argocd/            Argo CD itself: pinned upstream install + patches (KSOPS, notifications, ingress).
│   │                      The ONE thing applied by hand:  sudo k3s kubectl apply -k kubernetes/bootstrap/argocd/ -n argocd
│   └── apps.yaml          the ApplicationSet: every kubernetes/apps/<namespace>/<app>/ → an Application (applied once)
└── apps/
    └── <namespace>/
        └── <app>/         the app's manifests. Directory name = Argo app name. Parent dir = Kubernetes namespace.
```

| Namespace | Apps |
|---|---|
| `media` | immich, immich-prereqs, immich-public-proxy, kavita, komf, calibre, suwayomi, romm |
| `apps` | searxng, degoog, homepage |
| `monitoring` | gatus |
| `notifications` | ntfy |
| `cert-manager` | cert-manager, cert-manager-issuer |

## Shape of an app directory
Every app has a `kustomization.yaml` (phase 3 makes this true for all of them). Raw-manifest apps:
`deployment.yaml`, `service.yaml`, `ingress.yaml`, `storage.yaml`, optional `configmap.yaml`, and for
secrets `<app>-secret.enc.yaml` + `<app>-secret.sops.yaml` (SOPS/KSOPS — `docs/platform/secrets.md`).
Helm apps: `values.yaml` next to the chart reference. Reference example: `apps/media/komf/`.

## Adding an app
1. `kubernetes/apps/<namespace>/<app>/` with the files above (copy komf).
2. `./scripts/ci/validate.sh` green → push → the ApplicationSet registers it within ~3 min → Argo UI → Sync.
   (Needs a sync option the default lacks? add a case to `templatePatch` in `bootstrap/apps.yaml`.)
3. `docs/apps/<app>.md`, a Homepage tile, a Gatus endpoint, a DNS record.

Sync is MANUAL everywhere — Argo shows the diff, you click. Conventions: `../CLAUDE.md`.
