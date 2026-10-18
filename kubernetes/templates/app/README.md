# App skeleton — copy me

```bash
cp -r kubernetes/templates/app kubernetes/apps/<namespace>/<app>
```
then replace every `example` / `EXAMPLE`, delete what the app does not need (storage, ingress), and follow
`docs/platform/adding-an-app.md`. This directory is NOT under `kubernetes/apps/`, so the ApplicationSet
ignores it; CI still renders it to keep it valid.
