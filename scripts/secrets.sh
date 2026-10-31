#!/usr/bin/env bash
# scripts/secrets.sh — one command for every SOPS task in this repo.
#
#   ./scripts/secrets.sh help
#
# Why this exists: the raw sops commands are fine but easy to get subtly wrong — the wrong
# extract path, forgetting `-i`, editing an encrypted file by hand (MAC mismatch), or creating
# the .enc.yaml without the .sops.yaml generator beside it, which fails much later as
# "secret not found" at Sync time. This wraps the five things you actually do.
#
# Works on Arch (where the age key lives) and macOS. Nothing here talks to the cluster.
# Full background: docs/platform/secrets.md
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"
AGE_KEY="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[1m'; c_0=$'\033[0m'
die(){ printf '%serror:%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
ok(){  printf '  %sok%s   %s\n' "$c_g" "$c_0" "$*"; }
bad(){ printf '  %sNO%s   %s\n' "$c_r" "$c_0" "$*"; }
note(){ printf '  %s--%s   %s\n' "$c_y" "$c_0" "$*"; }

need_sops(){
  command -v sops >/dev/null 2>&1 || die "sops not installed.  Arch: sudo pacman -S sops age   macOS: brew install sops age"
}
need_key(){
  need_sops
  [ -f "$AGE_KEY" ] || die "no age key at $AGE_KEY
  The private key lives on the Arch box. To use this machine too:
    mkdir -p \"$(dirname "$AGE_KEY")\"
    scp arch:~/.config/sops/age/keys.txt \"$AGE_KEY\"
    chmod 600 \"$AGE_KEY\"
  (Or set SOPS_AGE_KEY_FILE to point somewhere else.)"
}

# Resolve "karakeep" or a path into the real .enc.yaml. Saves typing the full path every time.
resolve(){
  local want="${1:-}" hits
  [ -n "$want" ] || die "which secret?  e.g. '$0 ${CMD:-view} karakeep'   (list them: $0 status)"
  [ -f "$want" ] && { printf '%s\n' "$want"; return; }
  hits="$(find kubernetes -name "*${want}*.enc.yaml" | sort)"
  case "$(printf '%s' "$hits" | grep -c .)" in
    0) die "no *.enc.yaml matching '$want'  (try: $0 status)" ;;
    1) printf '%s\n' "$hits" ;;
    *) die "'$want' matches several files:
$(printf '%s\n' "$hits" | sed 's/^/    /')" ;;
  esac
}

is_encrypted(){ grep -q '^sops:' "$1"; }

# A strong random value. openssl everywhere; /dev/urandom as the fallback.
gen_value(){
  local len="${1:-48}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 $((len * 2)) | tr -d '\n=+/' | cut -c "1-$len"
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$len"
  fi
  echo
}

# ── status ────────────────────────────────────────────────────────────────────────────
# The one command that needs NO key: it reads structure, never values.
cmd_status(){
  printf '%sSecrets in this repo%s   (key: %s)\n\n' "$c_b" "$c_0" \
    "$([ -f "$AGE_KEY" ] && echo "present at $AGE_KEY" || echo "NOT on this machine")"
  local f dir app plain=0 enc=0
  for f in $(find kubernetes -name '*.enc.yaml' | sort); do
    dir="$(dirname "$f")"; app="$(basename "${f%-secret.enc.yaml}")"
    if is_encrypted "$f"; then
      enc=$((enc + 1)); ok "$f"
    else
      plain=$((plain + 1)); bad "$f  ${c_y}PLAINTEXT — do not commit${c_0}"
    fi
    # keys are readable even when encrypted (encrypted_regex covers values only)
    printf '         keys: %s\n' "$(awk '/^(data|stringData):/{i=1;next} i&&/^[^ \t]/{i=0} i&&/^[ \t]+[A-Za-z0-9_.-]+:/{gsub(/^[ \t]+|:.*/,"");printf "%s ",$0}' "$f")"
    # wiring: how does kustomize actually pick this file up? The three states are genuinely
    # different, and confusing them is what produces "secret not found" at Sync time:
    #   generator  → KSOPS decrypts it. The intended pattern.
    #   resource   → applied verbatim, so the VALUES ARE CLEARTEXT in git. Valid, but a choice.
    #   neither    → the file is inert; nothing ever creates the Secret.
    local kf="$dir/kustomization.yaml" as_gen=0 as_res=0
    grep -q "^[^#]*${app}-secret.sops.yaml" "$kf" 2>/dev/null && as_gen=1
    grep -q "^[^#]*$(basename "$f")" "$kf" 2>/dev/null && as_res=1
    if [ "$as_gen" = 1 ]; then
      printf '         wiring: KSOPS generator\n'
    elif [ "$as_res" = 1 ]; then
      printf '         %swiring: applied as a PLAIN resource → values are CLEARTEXT in git%s\n' "$c_y" "$c_0"
      [ -f "$dir/${app}-secret.sops.yaml" ] && \
        printf '                 (%s-secret.sops.yaml exists but is not listed — the generator is disabled)\n' "$app"
    else
      printf '         %swiring: not referenced by kustomization.yaml — nothing creates this Secret%s\n' "$c_r" "$c_0"
    fi
    echo
  done
  printf '%d encrypted, %d plaintext\n' "$enc" "$plain"
  [ "$plain" -gt 0 ] && printf "\nEncrypt one with:  %s encrypt <app>\n" "$0"
  return 0
}

# ── view / get ────────────────────────────────────────────────────────────────────────
# resolve BEFORE need_key everywhere, so "which file did you mean?" wins over "install sops".
cmd_view(){ local f; f="$(resolve "${1:-}")" || exit 1; need_key; sops -d "$f"; }

cmd_get(){
  local f k; f="$(resolve "${1:-}")" || exit 1
  need_key
  k="${2:?usage: get <app|path> <KEY>}"
  # Try stringData then data — apps in this repo use stringData, but don't assume.
  sops -d --extract "[\"stringData\"][\"$k\"]" "$f" 2>/dev/null \
    || sops -d --extract "[\"data\"][\"$k\"]" "$f" 2>/dev/null \
    || die "no key '$k' in $f  (keys: $(sops -d "$f" | awk '/^(data|stringData):/{i=1;next} i&&/^[^ ]/{i=0} i&&/^ +[A-Za-z0-9_.-]+:/{gsub(/^ +|:.*/,"");printf "%s ",$0}'))"
}

cmd_edit(){ local f; f="$(resolve "${1:-}")" || exit 1; need_key; sops "$f"; }

# ── set ───────────────────────────────────────────────────────────────────────────────
# Change a value WITHOUT opening an editor — the thing that is genuinely fiddly by hand,
# because the right command differs depending on whether the file is already encrypted.
cmd_set(){
  local f; f="$(resolve "${1:-}")" || exit 1; shift
  [ "$#" -gt 0 ] || die "usage: set <app|path> KEY=value [KEY=value ...]"
  # NOTE: only the encrypted path needs sops. Filling in a plaintext template is a plain text
  # edit, so this still works on a machine that has neither sops nor the age key.
  local pair k v
  for pair in "$@"; do
    case "$pair" in *=*) ;; *) die "expected KEY=value, got '$pair'";; esac
    k="${pair%%=*}"; v="${pair#*=}"
    [ "$v" = "-" ] && { v="$(gen_value 48)"; printf '  generated %s\n' "$k"; }
    if is_encrypted "$f"; then
      need_key
      sops --set "[\"stringData\"][\"$k\"] \"$v\"" "$f" || die "sops --set failed for $k"
    else
      # plaintext template: rewrite the line in place, preserving comments and order
      ruby -e '
        f, k, v = ARGV
        lines = File.readlines(f)
        done_ = false
        lines.map! do |l|
          if l =~ /^(\s+)#{Regexp.escape(k)}:\s/ && !done_
            done_ = true
            "#{$1}#{k}: #{v.inspect}\n"
          else l end
        end
        unless done_
          # Append at the END of the data block, not straight after the header — a new key
          # appearing above the existing ones reads like the file was reordered.
          i = lines.rindex { |l| l =~ /^(data|stringData):/ }
          abort "no data:/stringData: block in #{f}" unless i
          j = i + 1
          j += 1 while j < lines.length && lines[j] =~ /^(\s+\S|\s*$|\s*#)/
          lines.insert(j, "  #{k}: #{v.inspect}\n")
        end
        File.write(f, lines.join)
      ' "$f" "$k" "$v" || exit 1
    fi
    printf '  set %s in %s\n' "$k" "$f"
  done
  is_encrypted "$f" && printf '\n%sStill encrypted.%s Push, Sync, then: kubectl rollout restart deploy/<app> -n <ns>\n' "$c_g" "$c_0" \
                    || printf '\n%sThis file is PLAINTEXT.%s Encrypt before committing:  %s encrypt %s\n' "$c_y" "$c_0" "$0" "$f"
}

# ── encrypt / verify ──────────────────────────────────────────────────────────────────
cmd_encrypt(){
  local f; f="$(resolve "${1:-}")" || exit 1
  need_key
  is_encrypted "$f" && { note "$f is already encrypted — nothing to do"; return 0; }
  grep -q 'REPLACE_ME' "$f" && die "$f still contains REPLACE_ME — put the real values in first (see: $0 set)"
  sops -e -i "$f" || die "sops -e -i failed"
  # Prove it: sops refuses to decrypt a file that was never encrypted, so a clean round-trip
  # is the only honest check that this is really ciphertext.
  sops -d "$f" >/dev/null 2>&1 || die "encrypted but will not decrypt — DO NOT COMMIT, restore from git"
  ok "$f encrypted and verified"
}

cmd_verify(){
  need_sops
  local f rc=0 have_key=0
  [ -f "$AGE_KEY" ] && have_key=1
  printf '%sVerifying every *.enc.yaml%s\n\n' "$c_b" "$c_0"
  for f in $(find kubernetes -name '*.enc.yaml' | sort); do
    if ! is_encrypted "$f"; then bad "$f — plaintext (never encrypted)"; rc=1; continue; fi
    if [ "$have_key" = 1 ]; then
      if sops -d "$f" >/dev/null 2>&1; then ok "$f — decrypts cleanly"
      else bad "$f — has a sops: block but will NOT decrypt (hand-edited? MAC mismatch)"; rc=1; fi
    else
      note "$f — encrypted (no key here, cannot test the round-trip)"
    fi
  done
  echo; [ "$rc" = 0 ] && printf '%sall good%s\n' "$c_g" "$c_0" || printf '%sproblems above%s\n' "$c_r" "$c_0"
  return $rc
}

# ── new ───────────────────────────────────────────────────────────────────────────────
# Creates BOTH files and wires the generator, because creating only the .enc.yaml is the
# mistake that surfaces much later as "secret not found" at Sync.
cmd_new(){
  local target="${1:?usage: new <namespace>/<app> KEY [KEY ...]}"; shift
  [ "$#" -gt 0 ] || die "give at least one key name, e.g. $0 new apps/myapp API_KEY"
  local ns app dir
  ns="${target%%/*}"; app="${target##*/}"
  [ "$ns" != "$app" ] || die "expected <namespace>/<app>, got '$target'"
  dir="kubernetes/apps/$ns/$app"
  [ -d "$dir" ] || die "$dir does not exist. Create the app directory first (docs/platform/adding-an-app.md)."
  local enc="$dir/$app-secret.enc.yaml" gen="$dir/$app-secret.sops.yaml"
  [ -f "$enc" ] && die "$enc already exists — use '$0 set $app KEY=value' instead"

  { echo "# $app-secret — SOPS-encrypted. Created by scripts/secrets.sh."
    echo "# Values are plaintext RIGHT NOW. Fill them in, then:  ./scripts/secrets.sh encrypt $app"
    echo "# Never commit this file while it is plaintext."
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "metadata:"
    echo "  name: $app-secret"
    echo "  namespace: $ns"
    echo "  labels:"
    echo "    app: $app"
    echo "type: Opaque"
    echo "stringData:"
    for k in "$@"; do echo "  $k: \"REPLACE_ME\""; done
  } > "$enc"

  { echo "# KSOPS generator — holds NO secret. It tells kustomize to decrypt the file below."
    echo "# Listed under 'generators:' in kustomization.yaml, never under 'resources:'."
    echo "apiVersion: viaduct.ai/v1"
    echo "kind: ksops"
    echo "metadata:"
    echo "  name: $app-secret"
    echo "  namespace: $ns"
    echo "  annotations:"
    echo "    config.kubernetes.io/function: |"
    echo "      exec:"
    echo "        path: ksops"
    echo ""
    echo "files:"
    echo "  - ./$app-secret.enc.yaml"
  } > "$gen"

  ok "created $enc"
  ok "created $gen"

  # Wire the generator into kustomization.yaml as TEXT, so existing comments survive.
  local kus="$dir/kustomization.yaml"
  if [ ! -f "$kus" ]; then
    note "no $kus — add 'generators:' with '$app-secret.sops.yaml' yourself"
  elif grep -q "$app-secret.sops.yaml" "$kus"; then
    note "$kus already references the generator"
  elif grep -q '^generators:' "$kus"; then
    ruby -e 'f,l=ARGV; s=File.read(f); s.sub!(/^generators:\n/, "generators:\n  - #{l}\n"); File.write(f,s)' \
      "$kus" "$app-secret.sops.yaml" && ok "added to the existing generators: block in $kus"
  else
    printf '\ngenerators:\n  - %s-secret.sops.yaml\n' "$app" >> "$kus"
    ok "appended a generators: block to $kus"
  fi

  cat <<EOF

${c_b}Next${c_0}
  1. put the real values in:
       $0 set $app ${1}=yourvalue          # or '-' to generate a strong random one
  2. encrypt + verify:
       $0 encrypt $app
  3. consume it in deployment.yaml:
       env:
         - name: ${1}
           valueFrom:
             secretKeyRef: { name: $app-secret, key: ${1} }
  4. ./scripts/ci/check-conventions.sh     # proves the secretKeyRef matches a real key
EOF
}

# ── rotate ────────────────────────────────────────────────────────────────────────────
cmd_rotate(){
  local f; f="$(resolve "${1:-}")" || exit 1; shift
  [ "$#" -gt 0 ] || die "name the keys to rotate, e.g. $0 rotate karakeep NEXTAUTH_SECRET"
  printf '%sRotating in %s%s\n' "$c_b" "$f" "$c_0"
  printf '\n%s⚠ This only replaces the value in git.%s If the credential also exists somewhere else\n' "$c_y" "$c_0"
  printf '  (a database role, an API provider, a VPN account) change it THERE first — otherwise\n'
  printf '  you have just broken the app rather than rotated it. Self-contained values\n'
  printf '  (NEXTAUTH_SECRET, MEILI_MASTER_KEY, app signing keys) are safe to rotate here alone.\n\n'
  local k args=()
  for k in "$@"; do args+=("$k=-"); done
  cmd_set "$f" "${args[@]}"
  cat <<EOF

${c_b}Then${c_0}
  git add -A && git commit && git push      # you do the git part
  Argo → Sync the app
  sudo k3s kubectl rollout restart deploy/<app> -n <ns>    # pods do NOT restart on a Secret change

  Rotating a value that was ever committed in plaintext is mandatory, not optional —
  git history keeps the old one forever.
EOF
}

cmd_gen(){ gen_value "${1:-48}"; }

# ── setup / doctor ────────────────────────────────────────────────────────────────────
cmd_setup(){
  printf '%sSOPS setup on this machine%s\n\n' "$c_b" "$c_0"
  command -v sops >/dev/null 2>&1 && ok "sops  $(sops --version 2>/dev/null | head -1)" || bad "sops not installed"
  command -v age  >/dev/null 2>&1 && ok "age   $(age --version 2>/dev/null | head -1)"  || bad "age not installed"
  if [ -f "$AGE_KEY" ]; then
    ok "age key at $AGE_KEY"
    case "$(ls -l "$AGE_KEY" | cut -c1-10)" in
      -rw-------) ok "permissions 600" ;;
      *) bad "permissions are $(ls -l "$AGE_KEY" | cut -c1-10) — run: chmod 600 $AGE_KEY" ;;
    esac
  else
    bad "no age key at $AGE_KEY"
  fi
  [ -f .sops.yaml ] && ok ".sops.yaml present (public key: $(grep -o 'age1[a-z0-9]*' .sops.yaml | head -1))" || bad "no .sops.yaml"
  cat <<EOF

${c_b}If something is missing${c_0}
  Arch:   sudo pacman -S sops age
  macOS:  brew install sops age

  The PRIVATE key lives on the Arch box. Copy it to another machine with:
    mkdir -p ~/.config/sops/age
    scp arch:~/.config/sops/age/keys.txt ~/.config/sops/age/keys.txt
    chmod 600 ~/.config/sops/age/keys.txt

  ⚠ Back up keys.txt in your password manager AND somewhere offline. Lose it and every
    *.enc.yaml in git is unreadable forever — there is no recovery.

  The cluster needs it too (after a rebuild, BEFORE syncing any app with a secret):
    sudo k3s kubectl create secret generic sops-age -n argocd \\
      --from-file=keys.txt=\$HOME/.config/sops/age/keys.txt
EOF
}

cmd_help(){
  cat <<EOF
${c_b}secrets.sh${c_0} — SOPS without remembering the flags.   docs/platform/secrets.md

  ${c_b}status${c_0}                      every secret: encrypted?, which keys, wiring  ${c_y}(no key needed)${c_0}
  ${c_b}setup${c_0}                       is this machine able to encrypt/decrypt?      ${c_y}(no key needed)${c_0}
  ${c_b}verify${c_0}                      round-trip every file; safe pre-commit check

  ${c_b}view${c_0}   <app>               print the whole secret, decrypted
  ${c_b}get${c_0}    <app> KEY           print ONE value (to pipe or paste)
  ${c_b}edit${c_0}   <app>               open in \$EDITOR, re-encrypt on save

  ${c_b}new${c_0}    <ns>/<app> KEY...   create .enc.yaml + .sops.yaml + wire the generator
  ${c_b}set${c_0}    <app> KEY=value     change a value in place ('-' = generate a strong one)
  ${c_b}encrypt${c_0} <app>              encrypt a plaintext template, then prove it decrypts
  ${c_b}rotate${c_0} <app> KEY...        new random values + what to do afterwards
  ${c_b}gen${c_0}    [length]            just print a random secret (default 48)

<app> is a substring — 'karakeep' finds kubernetes/apps/apps/karakeep/karakeep-secret.enc.yaml.
A full path works too.

${c_b}Examples${c_0}
  ./scripts/secrets.sh status
  ./scripts/secrets.sh new media/myapp API_KEY DB_PASSWORD
  ./scripts/secrets.sh set myapp API_KEY=abc123 DB_PASSWORD=-
  ./scripts/secrets.sh encrypt myapp
  ./scripts/secrets.sh get immich REDIS_PASSWORD
  ./scripts/secrets.sh rotate karakeep NEXTAUTH_SECRET MEILI_MASTER_KEY
EOF
}

CMD="${1:-help}"
case "$CMD" in
  status)  shift; cmd_status "$@" ;;
  setup|doctor) shift; cmd_setup "$@" ;;
  verify)  shift; cmd_verify "$@" ;;
  view|show|decrypt) shift; cmd_view "$@" ;;
  get)     shift; cmd_get "$@" ;;
  edit)    shift; cmd_edit "$@" ;;
  new)     shift; cmd_new "$@" ;;
  set)     shift; cmd_set "$@" ;;
  encrypt) shift; cmd_encrypt "$@" ;;
  rotate)  shift; cmd_rotate "$@" ;;
  gen)     shift; cmd_gen "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command '$1'   (try: $0 help)" ;;
esac
