#!/usr/bin/env bash
# cluster-cleanup.sh — find things RUNNING in the cluster that git no longer asks for.
#
# WHY THIS EXISTS
#   Deleting an app directory removes its Argo Application (the ApplicationSet has no finalizer)
#   but leaves every deployed resource running. Nothing reports that. Over time the cluster drifts
#   away from the repo and the only record of what should still exist is in docs/runbooks/
#   cluster-cleanup.md as a hand-maintained list. This script derives that list from the repo
#   instead, so it cannot go stale.
#
# ⚠️ THIS SCRIPT NEVER DELETES ANYTHING. It reports, and with --commands prints the delete
#    commands for you to read and run yourself. Deleting a namespace takes its PVCs — and the
#    data on them — with it, so that stays a human decision.
#
# USAGE
#   KUBECTL="sudo k3s kubectl" ./scripts/cluster-cleanup.sh            # report
#   KUBECTL="sudo k3s kubectl" ./scripts/cluster-cleanup.sh --commands # + paste-ready deletes
#
# EXIT  0 = nothing unexpected   1 = found something worth looking at
set -uo pipefail
cd "$(dirname "$0")/.."

KUBECTL="${KUBECTL:-kubectl}"
SHOW_CMDS=0
[ "${1:-}" = "--commands" ] && SHOW_CMDS=1

red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; dim=$'\033[2m'; rst=$'\033[0m'
findings=0
CMDS=""

note()  { echo "  ${ylw}•${rst} $*"; findings=$((findings + 1)); }
cmd()   { CMDS="${CMDS}$1"$'\n'; }
ok()    { echo "  ${grn}✓${rst} $*"; }

# Namespaces Kubernetes/k3s owns. Everything else should trace back to this repo.
SYSTEM_NS="default kube-system kube-public kube-node-lease argocd kube-flannel"

# What the repo asks for: kubernetes/apps/<namespace>/<app>/
repo_ns()   { ls -d kubernetes/apps/*/ 2>/dev/null | awk -F/ '{print $3}'; }
repo_apps() { ls -d kubernetes/apps/*/*/ 2>/dev/null | awk -F/ '{print $4}'; }

in_list() { # in_list <needle> <space-separated haystack>
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

REPO_NS="$(repo_ns | tr '\n' ' ')"
REPO_APPS="$(repo_apps | tr '\n' ' ')"

echo "repo declares: $(echo "$REPO_APPS" | wc -w | tr -d ' ') apps across $(echo "$REPO_NS" | wc -w | tr -d ' ') namespaces"
echo

# ── 1. Argo Applications with no directory behind them ────────────────────────────────
echo "== 1. Argo Applications whose directory is gone from git =="
apps_live="$($KUBECTL get applications.argoproj.io -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
if [ -z "$apps_live" ]; then
  echo "  ${dim}(could not list Applications — wrong context, or Argo not reachable)${rst}"
else
  miss=0
  for a in $apps_live; do
    if ! in_list "$a" "$REPO_APPS"; then
      note "Application '$a' exists in Argo but kubernetes/apps/*/$a/ does not"
      cmd "$KUBECTL delete application $a -n argocd    # removes the Application ONLY; its resources stay"
      miss=1
    fi
  done
  [ "$miss" -eq 0 ] && ok "every Application maps to a directory"
fi
echo

# ── 2. Namespaces nothing in the repo targets ─────────────────────────────────────────
echo "== 2. Namespaces not declared by the repo =="
ns_live="$($KUBECTL get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
miss=0
for n in $ns_live; do
  in_list "$n" "$SYSTEM_NS" && continue
  in_list "$n" "$REPO_NS" && continue
  # cert-manager/sealed-secrets style: an app directory may create its own namespace
  in_list "$n" "$REPO_APPS" && continue
  note "namespace '$n' is not declared anywhere in kubernetes/apps/"
  echo "      ${dim}$($KUBECTL get all,pvc -n "$n" --no-headers 2>/dev/null | wc -l | tr -d ' ') object(s) inside${rst}"
  cmd "$KUBECTL get all,pvc,secret,ingress -n $n          # LOOK FIRST"
  cmd "$KUBECTL delete ns $n                              # ⚠️ takes its PVCs and their DATA"
  miss=1
done
[ "$miss" -eq 0 ] && ok "no unexpected namespaces"
echo

# ── 3. Workloads whose name matches no app ────────────────────────────────────────────
echo "== 3. Workloads in repo namespaces that match no app name =="
echo "  ${dim}heuristic: a workload should start with one of its namespace's app names${rst}"
miss=0
for n in $REPO_NS; do
  ns_apps="$(ls -d kubernetes/apps/"$n"/*/ 2>/dev/null | awk -F/ '{print $4}' | tr '\n' ' ')"
  for w in $($KUBECTL get deploy,statefulset,daemonset -n "$n" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    hit=0
    for a in $ns_apps; do
      case "$w" in "$a"*) hit=1; break ;; esac
    done
    if [ "$hit" -eq 0 ]; then
      note "$n/$w — no app directory in kubernetes/apps/$n/ explains this"
      cmd "$KUBECTL get deploy,sts,ds -n $n | grep $w    # LOOK FIRST — may belong to a Helm chart"
      miss=1
    fi
  done
done
[ "$miss" -eq 0 ] && ok "every workload traces to an app directory"
echo

# ── 4. Ingress hosts not in the repo ──────────────────────────────────────────────────
echo "== 4. Ingress hosts the repo does not declare =="
repo_hosts="$(grep -rhoE '[a-z0-9.-]+\.williampring\.ca' kubernetes/ 2>/dev/null | sort -u | tr '\n' ' ')"
miss=0
for h in $($KUBECTL get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2>/dev/null | sort -u); do
  [ -n "$h" ] || continue
  in_list "$h" "$repo_hosts" || { note "ingress host '$h' is live but not in kubernetes/"; miss=1; }
done
[ "$miss" -eq 0 ] && ok "every live ingress host is declared"
echo

# ── 5. Pods that are not healthy ──────────────────────────────────────────────────────
echo "== 5. Pods not Running/Completed =="
bad="$($KUBECTL get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"')"
if [ -n "$bad" ]; then
  echo "$bad" | while read -r l; do echo "  ${ylw}•${rst} $l"; done
  findings=$((findings + 1))
  cmd "# for each: $KUBECTL describe pod -n <ns> <pod> | tail -20"
else
  ok "all pods Running or Completed"
fi
echo

# ── 6. Storage and certs left behind ──────────────────────────────────────────────────
echo "== 6. Released/Failed PVs, unbound PVCs, unready certificates =="
pv="$($KUBECTL get pv --no-headers 2>/dev/null | awk '$5=="Released" || $5=="Failed"')"
[ -n "$pv" ] && { echo "$pv" | while read -r l; do echo "  ${ylw}•${rst} PV $l"; done; findings=$((findings + 1)); } || ok "no Released/Failed PVs"
pvc="$($KUBECTL get pvc -A --no-headers 2>/dev/null | awk '$3!="Bound"')"
[ -n "$pvc" ] && { echo "$pvc" | while read -r l; do echo "  ${ylw}•${rst} PVC $l"; done; findings=$((findings + 1)); } || ok "all PVCs Bound"
crt="$($KUBECTL get certificate -A --no-headers 2>/dev/null | awk '$3!="True"')"
[ -n "$crt" ] && { echo "$crt" | while read -r l; do echo "  ${ylw}•${rst} cert $l"; done; findings=$((findings + 1)); } || ok "all certificates Ready"
echo

# ── 7. Names from apps known to have been retired ─────────────────────────────────────
echo "== 7. Traces of retired apps =="
RETIRED="ntfy nitter vaultwarden prometheus grafana loki alloy"
miss=0
for r in $RETIRED; do
  hits="$($KUBECTL get all,ingress,pvc,secret,ns -A --no-headers 2>/dev/null | grep -ci "$r")"
  if [ "${hits:-0}" -gt 0 ]; then
    note "'$r' still matches $hits object(s) — retired, see docs/runbooks/cluster-cleanup.md"
    cmd "$KUBECTL get all,ingress,pvc,secret,ns -A | grep -i $r    # LOOK FIRST"
    miss=1
  fi
done
[ "$miss" -eq 0 ] && ok "no traces of retired apps"
echo

# ── summary ───────────────────────────────────────────────────────────────────────────
if [ "$findings" -eq 0 ]; then
  echo "${grn}CLUSTER MATCHES THE REPO${rst}"
  exit 0
fi
echo "${red}$findings area(s) to look at.${rst}"
if [ "$SHOW_CMDS" -eq 1 ] && [ -n "$CMDS" ]; then
  echo
  echo "── suggested commands (READ BEFORE RUNNING — none of this has been executed) ──"
  printf '%s' "$CMDS"
else
  echo "Re-run with --commands to print paste-ready delete commands."
fi
exit 1
