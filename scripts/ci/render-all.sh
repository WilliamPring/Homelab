#!/usr/bin/env bash
# scripts/ci/render-all.sh — render every app to one file per app, for DIFFING.
#
#   ./scripts/ci/render-all.sh <repo-root> <out-dir>
#
# This is the same rendering validate.sh does, minus the checking: it exists so CI can render
# the PR's base and head and show you what the merge actually changes in the cluster.
#
# Why that matters here: Argo applies rendered OBJECTS, but a PR shows you SOURCE. A one-line
# chart bump can add a container, drop a volume, or rename every object — and a Renovate diff of
# `version: 1.2.3` → `version: 1.3.0` tells you none of it. Rendering both sides closes that gap.
#
# KSOPS generators are stripped (CI has no age key), so Secrets are absent from both sides —
# a secret VALUE change is invisible here by design. Keys are checked by check-conventions.sh.
set -uo pipefail
root="${1:?usage: render-all.sh <repo-root> <out-dir>}"
out="${2:?usage: render-all.sh <repo-root> <out-dir>}"
mkdir -p "$out"

# Public charts only: give helm an empty registry config so a credential helper is never consulted.
cfg="$(mktemp -d)"; echo '{}' > "$cfg/config.json"
export DOCKER_CONFIG="$cfg" HELM_REGISTRY_CONFIG="$cfg/config.json"

rc=0
while IFS= read -r k; do
  d="$(dirname "$k")"
  rel="${d#"$root"/}"
  name="$(echo "$rel" | tr '/' '-')"
  tmp="$(mktemp -d)"
  cp -R "$d"/. "$tmp"/
  ruby -ryaml -e 'f=ARGV[0]; y=YAML.load_file(f); y.delete("generators"); File.write(f, y.to_yaml)' \
    "$tmp/kustomization.yaml" 2>/dev/null
  if kubectl kustomize --enable-helm "$tmp" > "$out/$name.yaml" 2>"$out/$name.err"; then
    rm -f "$out/$name.err"
  else
    # A side that doesn't render is still useful output: the diff then shows the error text,
    # which is exactly what you want to see on a PR that breaks rendering.
    #
    # ⚠️ Normalise the volatile bits FIRST. kustomize and mktemp put a fresh random path in every
    # error message, so an un-normalised error differs from itself on every run — the PR comment
    # would then report a "change" on both sides of an unchanged, equally-broken app.
    sed -E -e "s|$tmp|<app>|g" \
           -e 's|/tmp/kustomize-helm-[0-9]+|<helm-tmp>|g' \
           -e 's|kustomize-helm-[0-9]+|kustomize-helm-<n>|g' \
           -e 's|/var/folders/[^ ]*/T/[^ ]*|<tmp>|g' \
           "$out/$name.err" > "$out/$name.yaml"
    rm -f "$out/$name.err"
    rc=1
  fi
  rm -rf "$tmp"
done < <(find "$root/kubernetes" -name kustomization.yaml | sort)

rm -rf "$cfg"
exit $rc
