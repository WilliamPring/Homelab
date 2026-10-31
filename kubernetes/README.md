# kubernetes/ — everything Argo CD deploys

```
kubernetes/
├── bootstrap/
│   ├── argocd/            Argo CD itself: pinned upstream install + patches (KSOPS/tool overrides, build flags,
│   │                      notifications, ingress).  Applied by hand:  sudo k3s kubectl apply -k kubernetes/bootstrap/argocd/ -n argocd
│   └── apps.yaml          the ApplicationSet: every kubernetes/apps/<namespace>/<app>/ → one Application (applied once)
├── apps/
│   └── <namespace>/<app>/ the app. Directory name = Argo app name. Parent dir = Kubernetes namespace.
└── templates/app/         copyable skeleton for a new app (ignored by the ApplicationSet, rendered by CI)
```

| Namespace | Apps |
|---|---|
| `media` | immich, immich-prereqs, immich-public-proxy, kavita, komf, calibre, suwayomi, romm, qbittorrent |
| `apps` | searxng, degoog, homepage, karakeep, actual |
| `monitoring` | gatus, bark |
| `cert-manager` | cert-manager, cert-manager-issuer |

Every app directory has a `kustomization.yaml` — raw manifests and Helm charts (`helmCharts:`) alike. Sync is
MANUAL everywhere: Argo shows the diff, you click.

- **Add / change / remove an app:** `docs/platform/adding-an-app.md`
- **How Argo renders and applies:** `docs/platform/argocd.md`
- **The whole flow:** `docs/index.md` · conventions: `../CLAUDE.md`
