#!/usr/bin/env bash
# scripts/openbao-import.sh — one-time copy of the cluster's LIVE Secrets into OpenBao.
#
#   ./scripts/openbao-import.sh --dry-run    # what would be copied: key NAMES only, nothing written
#   ./scripts/openbao-import.sh              # copy every Secret whose OpenBao path is still empty
#   ./scripts/openbao-import.sh --force      # also overwrite paths that already exist (new version;
#                                            #   the old one stays in OpenBao's history — `bao kv rollback`)
#
# Why copy from the cluster and not from the *.enc.yaml files: the running Secrets are what the apps
# actually use today (KSOPS already decrypted them), so this needs no age key, works from any machine
# with kubectl, and can't import a stale or placeholder file by mistake. Docs: docs/platform/openbao.md §7
#
# Values are NEVER printed or put on a command line (where `ps` could see them): they go
# kubectl → jq → curl through pipes, and the token sits in a 0600 temp file that is deleted on exit.
#
# Needs: kubectl (pointed at the cluster), curl, jq, and a route to OpenBao (LAN or Tailscale).
# Settings (environment variables):
#   KUBECTL     how to call kubectl          default: kubectl   (on the master: KUBECTL="sudo k3s kubectl")
#   BAO_ADDR    OpenBao's address            default: https://192.168.68.91:8200
#   BAO_CACERT  the cert to trust            default: the repo's kubernetes/apps/external-secrets/external-secrets-store/openbao-ca.crt
#   BAO_TOKEN   use this token instead of logging in (e.g. the root token, from the LXC's openbao.env)
#   BAO_USER    userpass login name          default: william  (asks for the password)
set -euo pipefail
cd "$(dirname "$0")/.."

# namespace/secret-name  →  OpenBao path under homelab/  (the same pairs the externalsecret.yaml files use)
MAP="
apps/degoog-secret                        degoog
apps/ghostfolio-secret                    ghostfolio
apps/karakeep-secret                      karakeep
apps/wealthfolio-secret                   wealthfolio
media/immich-secret                       immich
media/komf-secret                         komf
media/qbittorrent-secret                  qbittorrent
media/romm-secret                         romm
monitoring/kube-prometheus-stack-secret   grafana
"
MOUNT=homelab

DRY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $a (try --help)"; exit 2 ;;
  esac
done

KUBECTL="${KUBECTL:-kubectl}"
BAO_ADDR="${BAO_ADDR:-https://192.168.68.91:8200}"
BAO_CACERT="${BAO_CACERT:-kubernetes/apps/external-secrets/external-secrets-store/openbao-ca.crt}"
BAO_USER="${BAO_USER:-william}"
for t in curl jq; do command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 2; }; done
grep -qx -- '-----BEGIN CERTIFICATE-----' "$BAO_CACERT" 2>/dev/null \
  || { echo "$BAO_CACERT has no certificate in it yet — paste OpenBao's cert there first (openbao.md §7)"; exit 2; }

TMP=$(mktemp -d); chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
api() {  # api METHOD PATH [curl args...] — prints the body, returns the HTTP code in $CODE
  local m=$1 p=$2; shift 2
  CODE=$(curl -sS --cacert "$BAO_CACERT" -H @"$TMP/hdr" -X "$m" -o "$TMP/body" -w '%{http_code}' \
         "$BAO_ADDR/v1/$p" "$@") || { echo "cannot reach $BAO_ADDR (on the LAN / Tailscale?)"; exit 1; }
}

# ── log in ────────────────────────────────────────────────────────────────────────────
: > "$TMP/hdr"; chmod 600 "$TMP/hdr"
if [ -n "${BAO_TOKEN:-}" ]; then
  printf 'X-Vault-Token: %s\n' "$BAO_TOKEN" > "$TMP/hdr"
else
  read -rs -p "OpenBao password for $BAO_USER: " PW; echo
  printf '%s' "$PW" | jq -Rs '{password: .}' > "$TMP/login"; unset PW
  api POST "auth/userpass/login/$BAO_USER" --data @"$TMP/login"; rm -f "$TMP/login"
  [ "$CODE" = 200 ] || { echo "login failed (HTTP $CODE): $(jq -r '.errors[]?' "$TMP/body")"; exit 1; }
  printf 'X-Vault-Token: %s\n' "$(jq -r .auth.client_token "$TMP/body")" > "$TMP/hdr"
fi
api GET "$MOUNT/config"   # cheap "is the token good and can it see the mount?" check
[ "$CODE" = 200 ] || { echo "token can't read $MOUNT/ (HTTP $CODE) — wrong login, or step 2 of openbao.md not done"; exit 1; }

# ── copy ──────────────────────────────────────────────────────────────────────────────
[ "$DRY" = 1 ] && echo "DRY RUN — nothing is written"
copied=0; skipped=0; missing=0
while read -r src path; do
  [ -n "$src" ] || continue
  ns=${src%%/*}; name=${src#*/}
  if ! $KUBECTL -n "$ns" get secret "$name" -o json > "$TMP/secret" 2>/dev/null; then
    echo "  MISSING  $src — not in the cluster; set homelab/$path by hand (bao kv put)"; missing=$((missing+1)); continue
  fi
  keys=$(jq -r '.data // {} | keys | join(", ")' "$TMP/secret")
  placeholder=$(jq -r '[.data // {} | to_entries[] | select(.value | @base64d | test("REPLACE_ME")) | .key] | join(", ")' "$TMP/secret")
  api GET "$MOUNT/metadata/$path"
  exists=0; [ "$CODE" = 200 ] && exists=1
  if [ "$exists" = 1 ] && [ "$FORCE" = 0 ]; then
    echo "  SKIP     $src → $MOUNT/$path already exists (--force to overwrite)"; skipped=$((skipped+1)); continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "  WOULD    $src → $MOUNT/$path  [$keys]$([ "$exists" = 1 ] && echo '  (overwrite)')"
  else
    jq '{data: (.data // {} | map_values(@base64d))}' "$TMP/secret" > "$TMP/payload"
    api POST "$MOUNT/data/$path" --data @"$TMP/payload"; rm -f "$TMP/payload"
    [ "$CODE" = 200 ] || { echo "  FAIL     $src → $MOUNT/$path (HTTP $CODE): $(jq -r '.errors[]?' "$TMP/body")"; exit 1; }
    echo "  COPIED   $src → $MOUNT/$path  [$keys]"; copied=$((copied+1))
  fi
  [ -n "$placeholder" ] && echo "           ⚠️  still a placeholder (REPLACE_ME): $placeholder — fix it in OpenBao: bao kv patch $MOUNT/$path KEY=…"
  rm -f "$TMP/secret"
done <<< "$MAP"

echo
echo "copied $copied · skipped $skipped (already there) · missing $missing"
[ "$DRY" = 1 ] || echo "Next: Sync each app in Argo — its ExternalSecret now finds the data (openbao.md §7)."
