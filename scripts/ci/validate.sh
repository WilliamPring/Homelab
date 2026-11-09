#!/usr/bin/env bash
# scripts/ci/validate.sh — the CI guard. Runs in GitHub Actions on every PR, and locally:
#
#   ./scripts/ci/validate.sh            # from the repo root
#
# What it checks (each section prints PASS/FAIL; any FAIL = non-zero exit):
#   1. kustomize  every directory with a kustomization.yaml renders
#   2. plain      every plain manifest directory under gitops/ is valid YAML with k8s objects
#   3. helm       every Argo Application with a chart source renders with its values file
#                 (catches values-schema errors, e.g. the immich chart)
#   4. schema     kubeconform over everything rendered (core schemas + CRD catalog for Argo,
#                 cert-manager, …)
#
# There is no secrets check any more: SOPS/KSOPS was retired in Nov 2026, so no ciphertext
# lives in git at all. Secret VALUES are in OpenBao; only key NAMES are in the ExternalSecrets,
# and check-conventions.sh (D) verifies every secretKeyRef against them.
#
# Needs: kubectl, helm, ruby (YAML parsing), kubeconform. Set KUBECONFORM=/path if not on PATH.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
# All charts are public: give helm an EMPTY registry config so a laptop's docker credential
# helper (e.g. docker-credential-desktop from Docker Desktop) is never consulted for OCI pulls.
mkdir -p "$OUT/docker-config"; echo '{}' > "$OUT/docker-config/config.json"
export DOCKER_CONFIG="${DOCKER_CONFIG_OVERRIDE:-$OUT/docker-config}"     # helm's OCI client reads ~/.docker/config.json → credsStore
export HELM_REGISTRY_CONFIG="$OUT/docker-config/config.json"
FAIL=0
pass(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1"; exit 2; }; }
need kubectl; need helm; need ruby; command -v "$KUBECONFORM" >/dev/null 2>&1 || { echo "missing tool: kubeconform (set KUBECONFORM=/path)"; exit 2; }

# ── 1. kustomize ────────────────────────────────────────────────────────────────────────
# Renders the real directory: with KSOPS gone there is no generator to strip first, so what
# CI builds here is byte-for-byte what Argo's repo-server builds.
echo "== 1. kustomize: every kustomization renders =="
while IFS= read -r k; do
  d=$(dirname "$k"); name=$(echo "$d" | tr '/' '-')
  if kubectl kustomize --enable-helm "$d" > "$OUT/kustomize-$name.yaml" 2> "$OUT/kustomize-$name.err"; then
    pass "$d  ($(grep -c '^kind:' "$OUT/kustomize-$name.yaml") objects)"
  else
    fail "$d"; sed 's/^/    /' "$OUT/kustomize-$name.err"
  fi
done < <(find kubernetes -name kustomization.yaml | sort)

# ── 2. plain manifest dirs ──────────────────────────────────────────────────────────────
echo "== 2. plain: manifest directories without a kustomization =="
while IFS= read -r d; do
  [ -f "$d/kustomization.yaml" ] && continue
  name=$(echo "$d" | tr '/' '-'); : > "$OUT/plain-$name.yaml"; n=0
  for f in "$d"/*.yaml; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "values.yaml" ] && continue           # helm values, not k8s objects
    grep -q '^kind:' "$f" || continue                           # not a manifest
    if ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0]))' "$f" 2>"$OUT/plain-$name.err"; then
      { cat "$f"; echo; echo '---'; } >> "$OUT/plain-$name.yaml"; n=$((n+1))
    else fail "$f — invalid YAML"; sed 's/^/    /' "$OUT/plain-$name.err"; fi
  done
  [ "$n" -gt 0 ] && pass "$d  ($n files)" || rm -f "$OUT/plain-$name.yaml"
done < <(find kubernetes/apps -mindepth 2 -maxdepth 2 -type d | sort)   # kubernetes/apps/<ns>/<app>

# ── 3. Argo Applications + helm charts ──────────────────────────────────────────────────
# ⚠️ HISTORY: this used to glob kubernetes/bootstrap/apps/*.yaml — a directory of hand-written
# Application files that the kubernetes/apps/<ns>/<app> + ApplicationSet refactor deleted. The
# glob then matched nothing, so this section silently rendered ZERO charts while still printing
# a PASS. Chart coverage was never actually lost (immich and cert-manager carry `helmCharts:` in
# their kustomization.yaml, so section 2's `kubectl kustomize --enable-helm` renders them), but
# the PASS was a lie. The glob below now matches whatever chart-source Applications actually
# exist; if none do, the section says so instead of claiming a pass.
echo "== 3. argo: the ApplicationSet (and any leftover chart-source Application) =="
: > "$OUT/argocd-apps.yaml"
{ cat kubernetes/bootstrap/apps.yaml; echo; echo '---'; } >> "$OUT/argocd-apps.yaml"
pass "bootstrap: ApplicationSet collected ($(ls -d kubernetes/apps/*/* | wc -l | tr -d ' ') app directories it will generate)"
charts_seen=0
# ruby prints one line per chart source: name|repoURL|chart|version|values|namespace
# (process substitution, NOT a pipe: a pipe would run the loop in a subshell and swallow FAIL=1)
while IFS='|' read -r app repo chart ver vals ns; do
  charts_seen=$((charts_seen+1))
  args=(); IFS=',' read -ra vf <<< "$vals"; for v in "${vf[@]}"; do [ -n "$v" ] && args+=(-f "$v"); done
  case "$repo" in
    oci://*) ref="$repo"; [[ "$repo" == */"$chart" ]] || ref="$repo/$chart"
             cmd=(helm template "$app" "$ref" --version "$ver" -n "$ns" "${args[@]}");;
    http://*|https://*) cmd=(helm template "$app" "$chart" --repo "$repo" --version "$ver" -n "$ns" "${args[@]}");;
    *)       cmd=(helm template "$app" "oci://$repo/$chart" --version "$ver" -n "$ns" "${args[@]}");;   # OCI without scheme (Argo style)
  esac
  if "${cmd[@]}" > "$OUT/helm-$app.yaml" 2> "$OUT/helm-$app.err"; then
    pass "$app  ← $chart $ver  ($(grep -c '^kind:' "$OUT/helm-$app.yaml") objects)"
  else
    fail "$app  ← $chart $ver"; sed 's/^/    /' "$OUT/helm-$app.err" | head -20
  fi
done < <(ruby -ryaml -e '
Dir["kubernetes/**/*.yaml"].sort.each do |f|
  next if f =~ %r{/charts/}
  a=YAML.load_file(f) rescue next; next unless a.is_a?(Hash) && a["kind"]=="Application"
  srcs=(a.dig("spec","sources")||[a.dig("spec","source")]).compact
  srcs.each do |s|
    next unless s["chart"]
    vals=(s.dig("helm","valueFiles")||[]).map{|v| v.sub(%r{^\$values/},"")}.join(",")
    puts [a.dig("metadata","name"), s["repoURL"], s["chart"], s["targetRevision"], vals, a.dig("spec","destination","namespace")].join("|")
  end
end')
[ "$charts_seen" -eq 0 ] && echo "       (no chart-source Application files — charts live in kustomization.yaml \`helmCharts:\` and are rendered by section 2)"

# ── 4. kubeconform ──────────────────────────────────────────────────────────────────────
echo "== 4. schema: kubeconform over everything rendered =="
if "$KUBECONFORM" -strict -summary -ignore-missing-schemas \
     -schema-location default \
     -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
     "$OUT"/*.yaml > "$OUT/kubeconform.log" 2>&1; then
  pass "$(tail -1 "$OUT/kubeconform.log")"
else
  fail "kubeconform"; grep -vE '^Summary|^$' "$OUT/kubeconform.log" | sed 's/^/    /' | head -40
fi

echo
[ "$FAIL" -eq 0 ] && echo "ALL CHECKS PASSED  (rendered output in $OUT)" || { echo "CHECKS FAILED  (see above; rendered output in $OUT)"; exit 1; }
