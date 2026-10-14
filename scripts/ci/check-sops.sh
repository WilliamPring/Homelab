#!/usr/bin/env bash
# check-sops.sh — fail if any *.enc.yaml passed in (or found under gitops/ kubernetes/) is NOT SOPS-encrypted.
# Used by the pre-commit hook; validate.sh has the fuller (per-value) check. Works on bash 3 (macOS) too.
set -u
rc=0
check() {
  f="$1"
  if grep -q '^sops:' "$f" && ! grep -q 'REPLACE_ME' "$f"; then echo "ok    $f"; else echo "PLAIN $f  ← encrypt before committing (docs/secrets.md §3)"; rc=1; fi
}
if [ "$#" -gt 0 ]; then
  for f in "$@"; do check "$f"; done
else
  while IFS= read -r f; do check "$f"; done < <(find gitops kubernetes -name '*.enc.yaml' 2>/dev/null | sort)
fi
exit $rc
