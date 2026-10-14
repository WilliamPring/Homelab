# kubernetes/ — everything Argo CD deploys

```
kubernetes/
├── bootstrap/
│   ├── argocd/            Argo CD itself: pinned upstream install + patches (KSOPS, notifications, ingress).
│   │                      The ONE thing applied by hand:  sudo k3s kubectl apply -k kubernetes/bootstrap/argocd/ -n argocd
│   └── apps/              one Argo `Application` per app (hand-applied once; an ApplicationSet will replace these)
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
2. `kubernetes/bootstrap/apps/<app>.yaml` (copy any; change name + path + namespace).
3. `./scripts/ci/validate.sh` green → push → `sudo k3s kubectl apply -f kubernetes/bootstrap/apps/<app>.yaml` → Argo UI → Sync.
4. `docs/<app>.md`, a Homepage tile, a Gatus endpoint, a DNS record.

Sync is MANUAL everywhere — Argo shows the diff, you click. Conventions: `../CLAUDE.md`.
