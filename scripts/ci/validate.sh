#!/usr/bin/env bash
# scripts/ci/validate.sh — the CI guard. Runs in GitHub Actions on every PR, and locally:
#
#   ./scripts/ci/validate.sh            # from the repo root
#
# What it checks (each section prints PASS/FAIL; any FAIL = non-zero exit):
#   1. secrets    every *.enc.yaml is SOPS-encrypted (sops: block, all values ENC[...], no REPLACE_ME)
#                 ⚠️ currently WARN-only (does not fail the run). Set STRICT_SECRETS=1 to enforce —
#                 flip it in .github/workflows/validate.yaml once komf/romm secrets are encrypted.
#   2. kustomize  every directory with a kustomization.yaml renders (KSOPS generator stripped —
#                 CI has no age key, so decryption itself is not tested)
#   3. plain      every plain manifest directory under gitops/ is valid YAML with k8s objects
#   4. helm       every Argo Application with a chart source renders with its values file
#                 (catches values-schema errors, e.g. the immich chart)
#   5. schema     kubeconform over everything rendered (core schemas + CRD catalog for Argo,
#                 cert-manager, …)
#
# Needs: kubectl, helm, ruby (YAML parsing), kubeconform. Set KUBECONFORM=/path if not on PATH.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
FAIL=0
pass(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
warn(){ printf '  \033[33mWARN\033[0m %s\n' "$*"; WARN=1; }
WARN=0
STRICT_SECRETS="${STRICT_SECRETS:-0}"
secret_problem(){ if [ "$STRICT_SECRETS" = "1" ]; then fail "$@"; else warn "$@"; fi; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1"; exit 2; }; }
need kubectl; need helm; need ruby; command -v "$KUBECONFORM" >/dev/null 2>&1 || { echo "missing tool: kubeconform (set KUBECONFORM=/path)"; exit 2; }

# ── 1. secrets ──────────────────────────────────────────────────────────────────────────
if [ "$STRICT_SECRETS" = "1" ]; then echo "== 1. secrets: *.enc.yaml must be encrypted (ENFORCED) =="; else echo "== 1. secrets: *.enc.yaml must be encrypted (WARN-only — STRICT_SECRETS=1 to enforce) =="; fi
while IFS= read -r f; do
  if ! grep -q '^sops:' "$f"; then secret_problem "$f — no sops: block (never encrypted)"; continue; fi
  if grep -q 'REPLACE_ME' "$f"; then secret_problem "$f — still contains REPLACE_ME"; continue; fi
  # every value under data:/stringData: must be ENC[...]
  bad=$(awk '
    /^(data|stringData):/ {inblk=1; next}
    inblk && /^[^ \t]/ {inblk=0}
    inblk && /^[ \t]+[A-Za-z0-9_.-]+:[ \t]*[^ \t]/ { if ($0 !~ /ENC\[/) print "    " $0 }
  ' "$f")
  if [ -n "$bad" ]; then secret_problem "$f — plaintext value(s):"; echo "$bad"; else pass "$f"; fi
done < <(find gitops -name '*.enc.yaml' | sort)

# ── 2. kustomize ────────────────────────────────────────────────────────────────────────
echo "== 2. kustomize: every kustomization renders (generators stripped) =="
while IFS= read -r k; do
  d=$(dirname "$k"); name=$(echo "$d" | tr '/' '-')
  tmp=$(mktemp -d); cp -R "$d"/. "$tmp"/
  # drop the generators: block (KSOPS needs the age key; CI has none)
  ruby -ryaml -e 'f=ARGV[0]; y=YAML.load_file(f); y.delete("generators"); File.write(f, y.to_yaml)' "$tmp/kustomization.yaml"
  if kubectl kustomize "$tmp" > "$OUT/kustomize-$name.yaml" 2> "$OUT/kustomize-$name.err"; then
    pass "$d  ($(grep -c '^kind:' "$OUT/kustomize-$name.yaml") objects)"
  else
    fail "$d"; sed 's/^/    /' "$OUT/kustomize-$name.err"
  fi
  rm -rf "$tmp"
done < <(find gitops -name kustomization.yaml | sort)

# ── 3. plain manifest dirs ──────────────────────────────────────────────────────────────
echo "== 3. plain: manifest directories without a kustomization =="
while IFS= read -r d; do
  [ -f "$d/kustomization.yaml" ] && continue
  case "$d" in gitops/apps|gitops/argocd) continue;; esac
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
done < <(find gitops -mindepth 1 -maxdepth 2 -type d | sort)

# ── 4. Argo Applications + helm charts ──────────────────────────────────────────────────
echo "== 4. argo apps: valid Applications; chart sources render with their values =="
: > "$OUT/argocd-apps.yaml"
for f in gitops/apps/*.yaml; do { cat "$f"; echo; echo '---'; } >> "$OUT/argocd-apps.yaml"; done
pass "gitops/apps  ($(ls gitops/apps/*.yaml | wc -l | tr -d ' ') Applications collected)"
# ruby prints one line per chart source: name|repoURL|chart|version|values|namespace
ruby -ryaml -e '
Dir["gitops/apps/*.yaml"].sort.each do |f|
  a=YAML.load_file(f); next unless a["kind"]=="Application"
  srcs=(a.dig("spec","sources")||[a.dig("spec","source")]).compact
  srcs.each do |s|
    next unless s["chart"]
    vals=(s.dig("helm","valueFiles")||[]).map{|v| v.sub(%r{^\$values/},"")}.join(",")
    puts [a.dig("metadata","name"), s["repoURL"], s["chart"], s["targetRevision"], vals, a.dig("spec","destination","namespace")].join("|")
  end
end' | while IFS='|' read -r app repo chart ver vals ns; do
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
done

# ── 5. kubeconform ──────────────────────────────────────────────────────────────────────
echo "== 5. schema: kubeconform over everything rendered =="
if "$KUBECONFORM" -strict -summary -ignore-missing-schemas \
     -schema-location default \
     -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
     "$OUT"/*.yaml > "$OUT/kubeconform.log" 2>&1; then
  pass "$(tail -1 "$OUT/kubeconform.log")"
else
  fail "kubeconform"; grep -vE '^Summary|^$' "$OUT/kubeconform.log" | sed 's/^/    /' | head -40
fi

echo
[ "$WARN" -eq 1 ] && echo "WARNINGS above (secrets check is WARN-only until STRICT_SECRETS=1)"
[ "$FAIL" -eq 0 ] && echo "ALL CHECKS PASSED  (rendered output in $OUT)" || { echo "CHECKS FAILED  (see above; rendered output in $OUT)"; exit 1; }
