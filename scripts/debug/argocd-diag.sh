#!/usr/bin/env bash
# argocd-diag.sh — READ-ONLY snapshot of the Argo CD side of the cluster, for debugging over git.
# Run ON THE MASTER as root (make diag does the copy/run/fetch for you). Prints no secret values.
set -u
K="k3s kubectl"
hr(){ printf '\n===== %s =====\n' "$*"; }
hr "when / where"; date -u +%FT%TZ; hostname; $K version --short 2>/dev/null | head -2
hr "nodes"; $K get nodes -o wide
hr "argocd pods (AGE tells you whether a restart happened)"; $K -n argocd get pods -o wide
hr "argocd-cm kustomize.buildOptions (must contain --enable-helm for the chart apps)"
$K -n argocd get cm argocd-cm -o jsonpath='{.data.kustomize\.buildOptions}'; echo
hr "repo-server tool versions (kustomize MUST be >= 5.8 to match Argo 3.5; if older, the KSOPS patch overrode it)"
$K -n argocd exec deploy/argocd-repo-server -c argocd-repo-server -- sh -c 'echo "kustomize: $(kustomize version 2>&1 | head -1)"; echo "helm: $(helm version --short 2>&1)"; echo "ksops: $(ksops version 2>&1 | head -1)"; echo "PATH kustomize: $(command -v kustomize)"' 2>&1
hr "applications (sync / health)"
$K -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision
hr "application ERRORS (conditions) — the full text"
$K -n argocd get applications -o json | python3 -c '
import sys,json
for a in json.load(sys.stdin)["items"]:
    for c in a["status"].get("conditions",[]):
        print("\n--", a["metadata"]["name"], "|", c["type"]); print(c["message"])' 2>/dev/null || $K -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.conditions[*].message}{"\n"}{end}'
hr "applicationset status"
$K -n argocd get applicationset apps -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>&1
hr "repo-server log — last 80 lines mentioning error/helm/kustomize/ksops"
$K -n argocd logs deploy/argocd-repo-server -c argocd-repo-server --tail=400 2>&1 | grep -iE 'error|helm|kustomize|ksops|failed' | tail -80
hr "notifications-controller log — last 20 lines"
$K -n argocd logs deploy/argocd-notifications-controller --tail=20 2>&1
hr "done"
