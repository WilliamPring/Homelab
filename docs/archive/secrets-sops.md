# Secrets — the working guide (ARCHIVED)

> **Retired in Nov 2026.** SOPS + age + KSOPS no longer exists in this repo: qBittorrent was the last
> app, and with it went the Argo repo-server patch, `.sops.yaml`, `scripts/secrets.sh` and the CI
> secrets check. **The current secrets doc is [`../platform/openbao.md`](../platform/openbao.md).**
> Kept for history, and because the `sops-age` Secret and the age key itself still exist outside git.
> Nothing below is a working instruction any more.

> **Being replaced (Nov 2026).** SOPS is on its way out in favour of OpenBao (on a Proxmox LXC) +
> External Secrets Operator, so secret values stop living in git at all. Why, and the setup:
> [`openbao.md`](../platform/openbao.md). **Already on OpenBao:** Grafana (`kube-prometheus-stack-secret`), Wealthfolio (`wealthfolio-secret`), degoog (`degoog-secret`), Immich (`immich-secret`) and Karakeep (`karakeep-secret`);
> for every other app, everything below still applies.

How secrets are stored, decrypted, reused and added in this repo. This is the day-to-day
reference. For the *why* and the full architecture, see `docs/platform/secrets-architecture.md` (deep dive) and
the original plan (archived, since deleted).

```
YOU (Arch box, has the age PRIVATE key)         GIT (public key only)         ARGO CD (has the private key too)
sops -e / sops <file>  ──encrypt──►  kubernetes/apps/<namespace>/<app>/<app>-secret.enc.yaml  ──►  repo-server + KSOPS decrypt
                                         values are ENC[...], keys readable          → real k8s Secret → pods
```

One rule covers everything: **a value is either `ENC[AES256_GCM,...]` in git, or it is not in
git at all.** Plaintext never gets committed.

---

## 1. What exists today

### Encrypted in git (SOPS + age, decrypted by Argo via KSOPS)

| File | Secret → namespace | Keys | Used by |
|---|---|---|---|
| `kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml` | `qbittorrent-secret` → media | `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES` | Gluetun (Mullvad) ⚠️ **template, not yet encrypted** |
Each one has a sibling `<app>-secret.sops.yaml` (the KSOPS *generator*, not a secret — it just
says "decrypt that file") and is listed under `generators:` in the app's `kustomization.yaml`.

### Moved to OpenBao (no SOPS files any more — see `openbao.md`)

| OpenBao path | Secret → namespace | Keys | Used by |
|---|---|---|---|
| `homelab/grafana` | `kube-prometheus-stack-secret` → monitoring | `admin-user`, `admin-password` | Grafana login |
| `homelab/wealthfolio` | `wealthfolio-secret` → apps | `WF_SECRET_KEY`, `WF_AUTH_PASSWORD_HASH` | Wealthfolio |
| `homelab/degoog` | `degoog-secret` → apps | `DEGOOG_SETTINGS_PASSWORDS`, `DEGOOG_VALKEY_URL` | degoog |
| `homelab/immich` | `immich-secret` → media | `REDIS_PASSWORD` | Immich (Valkey user `redis` @ .103) |
| `homelab/karakeep` | `karakeep-secret` → apps | `NEXTAUTH_SECRET`, `MEILI_MASTER_KEY` | Karakeep (values were cleartext in git history — rotate) |

Each is built by the app's `externalsecret.yaml`. Change a value in OpenBao, not here (`openbao.md` §6).

### Still hand-created in the cluster (NOT in git — recreate after a rebuild)

| Secret | Namespace | Holds | Where it's documented |
|---|---|---|---|
| `sops-age` | argocd | the age **private key** — the master key, can never be in git | this doc §2 |
| `openbao-approle` | external-secrets | External Secrets' login to OpenBao (role-id + secret-id) | `openbao.md` §7 step 4 |
| `immich-db` | media | Postgres password for Immich's in-cluster vector DB | `docs/apps/immich.md` |
| `vaultwarden-db`, `vaultwarden-admin` | apps | **orphans** — Vaultwarden was removed (Oct 2026); delete both secrets | `docs/runbooks/cluster-cleanup.md` §4 |
| `grafana-admin` | monitoring | **orphan** from the August stack; delete it. Not used by the Nov 2026 stack, which reads `kube-prometheus-stack-secret` (from OpenBao) | `docs/runbooks/cluster-cleanup.md` §1 |
| `cloudflare-api-token` | cert-manager | DNS-01 token — **all TLS depends on it** | `docs/platform/tls.md` |

Migrating these into `.enc.yaml` files is the open item (§5 below is the recipe).

### Known debt ⚠️
- **Karakeep's two values were cleartext in a PUBLIC repo** (the old `karakeep-secret.enc.yaml`, now deleted
  but still in git history). `NEXTAUTH_SECRET` signs Karakeep's login cookies, so anyone holding it can forge a
  session — gated only by Karakeep being reachable on Tailscale/LAN. They now live in OpenBao
  (`homelab/karakeep`). **Fix = rotate them there:** OpenBao UI → `homelab` → `karakeep` → Create new version
  with new random values (Tools → Random, `openbao.md` §6; keep `MEILI_MASTER_KEY` alphanumeric), force-sync
  the ExternalSecret, then `kubectl rollout restart deploy/karakeep -n apps`. You get logged out once. If
  search comes back empty afterwards, re-index from Karakeep's admin settings (bookmarks themselves are on NFS).
- `kubernetes/apps/media/suwayomi/deployment.yaml` carries Suwayomi's Basic-auth username/password **inline**
  (chosen for now; host is Tailscale-only). Move to a SOPS secret with the §5 recipe when ready,
  then rotate the password since the old one stays in git history.
- The shared Valkey user `redis`'s password was **inline in degoog's `deployment.yaml`**, so it is in git
  history on GitHub. degoog now has its own user and its URL comes from OpenBao (`docs/apps/degoog.md`).
  Still to do: rotate `redis`'s password (only Immich uses it) — degoog.md, "Its Valkey user", step 4.
- `kubernetes/apps/apps/searxng/configmap.yaml` still has the placeholder `server.secret_key`
  (`REPLACE-WITH-…` — not `REPLACE_ME`, so the conventions check can't see it). SearXNG signs its
  image-proxy URLs with it, so anyone who knows it can use the instance as an image proxy; it is
  Tailscale-only, which limits that. Fix = `./scripts/secrets.sh new apps/searxng SEARXNG_SECRET`,
  set it to `-` (generate), and pass it as the `SEARXNG_SECRET` env var, which overrides the file.

---

## 2. One-time setup on a machine

The age private key lives at `~/.config/sops/age/keys.txt` on the **Arch box**. Any machine
that should encrypt/decrypt needs `sops`, `age`, and a copy of that file at the same path.

```bash
# Arch
sudo pacman -S sops age
# macOS
brew install sops age
mkdir -p ~/.config/sops/age && scp arch:~/.config/sops/age/keys.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# prove it works (prints the decrypted immich secret to the terminal, changes nothing):
sops -d kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml
```
`.sops.yaml` at the repo root already matches `*.enc.yaml`, `*.sops.yaml` and `*secrets.yaml`
and names the public key, so none of the commands below need flags.

The cluster side is already done: the `sops-age` Secret in the `argocd` namespace is mounted
into the repo-server at `/etc/sops-age/keys.txt` (`kubernetes/bootstrap/argocd/repo-server-ksops-patch.yaml`).
If you ever rebuild the cluster, recreate it **first**, or no app with a secret will sync:
```bash
sudo k3s kubectl create secret generic sops-age -n argocd --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
```

**Back up `keys.txt`** in your password manager *and* somewhere outside the cluster. Lose it and every
`.enc.yaml` in git is unreadable forever.

---

## 3. The script (`scripts/secrets.sh`) — start here

Everything in §3–§6 below is wrapped by one script, so the flags below are reference rather than
something to memorise. It works on Arch and macOS, and the first two commands need **no age key**:

```bash
./scripts/secrets.sh status      # every secret: encrypted?, which keys, how it is wired
./scripts/secrets.sh setup       # is THIS machine able to encrypt/decrypt? what's missing?
./scripts/secrets.sh help        # all commands
```

| Command | Does |
|---|---|
| `status` | per file: encrypted or plaintext, its key names, and whether it is wired as a **KSOPS generator**, as a **plain resource** (= cleartext in git), or not at all |
| `setup` | checks `sops`, `age`, the key file and its permissions; prints the install/copy commands |
| `new <ns>/<app> KEY...` | creates `<app>-secret.enc.yaml` **and** `<app>-secret.sops.yaml` **and** adds the generator to `kustomization.yaml` — the three-file step where forgetting one surfaces much later as "secret not found" |
| `set <app> KEY=value` | change a value with no editor. `KEY=-` generates a strong random one. Works on encrypted files (`sops --set`) and plaintext templates alike |
| `encrypt <app>` | `sops -e -i`, then **proves it decrypts** before saying it worked |
| `view` / `get <app> KEY` | whole file, or one value to pipe |
| `edit <app>` | `$EDITOR`, re-encrypts on save |
| `rotate <app> KEY...` | new random values + the follow-up steps, with a warning about credentials that also live elsewhere |
| `verify` | round-trips every file — the pre-commit check |
| `gen [len]` | just print a random secret |

`<app>` is a substring: `karakeep` finds `kubernetes/apps/apps/karakeep/karakeep-secret.enc.yaml`.

```bash
# add a secret to a new app, end to end
./scripts/secrets.sh new media/myapp API_KEY DB_PASSWORD
./scripts/secrets.sh set myapp API_KEY=abc123 DB_PASSWORD=-     # '-' = generate
./scripts/secrets.sh encrypt myapp
./scripts/ci/check-conventions.sh                                # secretKeyRef matches a real key
```

Also `make secrets` (status) and `make secrets-help`.

---

## 3b. The five raw commands

```bash
# VIEW — whole file decrypted to the terminal, file untouched
sops -d kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml

# EXTRACT — one value, e.g. to paste it somewhere else
sops -d --extract '["stringData"]["WIREGUARD_ADDRESSES"]' kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml

# EDIT — decrypts into $EDITOR, re-encrypts on save (add/change/remove keys here)
sops kubernetes/apps/apps/degoog/degoog-secret.enc.yaml

# ENCRYPT — a plaintext template, in place, first time only
sops -e -i kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml

# VERIFY — before every commit. sops refuses to decrypt a file that was never encrypted,
# so a clean round-trip proves the file is ciphertext:
sops -d kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml > /dev/null && echo "ENCRYPTED - safe to commit"
#   "sops metadata not found"  → still plaintext, do NOT commit
grep -c 'ENC\[' kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml      # should equal the number of values (+1 for the mac line)
```

After changing a secret: push → Argo → Sync. **Pods do not restart on Secret changes**, so:
```bash
sudo k3s kubectl rollout restart deploy/<app> -n <ns>
```

---

## 4. Reusing an existing value

Secrets are per-app on purpose, but sometimes the *same* credential is genuinely shared (one
Valkey host, one Postgres LXC). Pattern: extract → paste into the other app's template → encrypt.

```bash
# example: copy one value out of an encrypted file into another app's secret
sops -d --extract '["stringData"]["WIREGUARD_ADDRESSES"]' kubernetes/apps/media/qbittorrent/qbittorrent-secret.enc.yaml
#  → paste it into kubernetes/apps/<ns>/<app>/<app>-secret.enc.yaml
sops -e -i kubernetes/apps/<ns>/<app>/<app>-secret.enc.yaml
```
Do **not** do this with the Valkey password until the debt in §1 is fixed — you would be
spreading a password that is already public in git history. Prefer a fresh ACL user per app
(`docs/platform/redis.md`).

Reading a value that only exists in the cluster (hand-managed ones):
```bash
sudo k3s kubectl get secret immich-db -n media -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## 5. Adding a secret to a new app (checklist)

Using `myapp` in namespace `media` as the example. Four files touch:

```yaml
# 1. kubernetes/apps/<namespace>/myapp/myapp-secret.enc.yaml  — plaintext for ~30 seconds, then encrypted
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secret
  namespace: media
type: Opaque
stringData:
  API_KEY: "the-real-value"
```
```yaml
# 2. kubernetes/apps/<namespace>/myapp/myapp-secret.sops.yaml  — the KSOPS generator (safe, holds no secret)
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: myapp-secret
  namespace: media
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./myapp-secret.enc.yaml
```
```yaml
# 3. kubernetes/apps/<namespace>/myapp/kustomization.yaml  — generator, NOT resource
resources:
  - deployment.yaml
generators:
  - myapp-secret.sops.yaml
```
```yaml
# 4. deployment.yaml — consume it
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: myapp-secret
        key: API_KEY
```
```bash
sops -e -i kubernetes/apps/<namespace>/myapp/myapp-secret.enc.yaml     # 5. encrypt
# 6. VERIFY (see §3) → commit → push → kubectl apply the Argo app → Sync
sudo k3s kubectl get secret myapp-secret -n media  # 7. exists → KSOPS worked
```
Copy `kubernetes/apps/apps/wealthfolio/` as a template — it is the smallest complete example.

---

## 6. Rotating a secret

```bash
./scripts/secrets.sh rotate <app> KEY [KEY ...]      # new random values + the follow-up steps
```

⚠️ **The script only changes the value in git.** That is the whole job for a *self-contained*
value — one the app invents for itself, like `NEXTAUTH_SECRET`, `ACCESS_TOKEN_SALT` or
`MEILI_MASTER_KEY`. For anything that also exists somewhere else, change it **there first**, or
you have broken the app rather than rotated it:

| Value | Change it at the source first |
|---|---|
| `DB_PASSWD` | Postgres LXC `.7` → `ALTER ROLE … PASSWORD …` |
| `REDIS_PASSWORD` | Valkey `.103` → `ACL SETUSER …` |
| `KAVITA_API_KEY`, provider keys | the app's / provider's own UI |
| `WIREGUARD_PRIVATE_KEY` | Mullvad account page — a new key, not a random string |

Then: push → Sync → `kubectl rollout restart deploy/<app> -n <ns>` (**pods do not restart on a
Secret change**).

**If the old value was ever committed in plaintext, rotating is mandatory, not optional** — git
history keeps it forever, and on a public repo so does everyone who cloned it.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `sops: no key could be found` / `failed to decrypt` on your machine | no `~/.config/sops/age/keys.txt` here → §2 |
| `sops: no matching creation rules` | filename doesn't end in `.enc.yaml` / `.sops.yaml` |
| Argo: `secret "<app>-secret" not found`, pod `CreateContainerConfigError` | the `.enc.yaml` is still plaintext (KSOPS refuses it) → encrypt, push, sync |
| Argo: `plugin ... not allowed` / generator error | repo-server KSOPS patch not applied, or `--enable-alpha-plugins` missing from `kustomize.buildOptions` (`kubernetes/bootstrap/argocd/argocd-cm-patch.yaml`) → `apply -k` + restart the repo-server |
| Argo: `Failed to verify data integrity` / `MAC mismatch` | an encrypted file was hand-edited → restore from git and use `sops <file>` instead |
| Secret updated, app still uses old value | `kubectl rollout restart deploy/<app>` |
| Everything fails after a cluster rebuild | `sops-age` Secret missing in `argocd` → §2 |

Check the cluster side without printing the key:
```bash
sudo k3s kubectl -n argocd exec deploy/argocd-repo-server -c argocd-repo-server -- sh -c 'echo $SOPS_AGE_KEY_FILE; ls -l /etc/sops-age/'
```

---

## Rules
- `.enc.yaml` → encrypted Secret. `.sops.yaml` → generator. Never swap them, never put the
  `.enc.yaml` under `resources:`.
- Commit nothing with a plaintext value. §3 VERIFY before every commit.
- The private key: Arch box, Argo's `sops-age` Secret, your password manager, one offline copy. Never git.
- One Secret per app, one DB role / Redis ACL user per app.
