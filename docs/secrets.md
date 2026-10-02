# Secrets — the working guide

How secrets are stored, decrypted, reused and added in this repo. This is the day-to-day
reference. For the *why* and the full architecture, see `docs/secrets-architecture.md` (deep dive) and
`docs/sops-argocd.md` (the original learning plan).

```
YOU (Arch box, has the age PRIVATE key)         GIT (public key only)         ARGO CD (has the private key too)
sops -e / sops <file>  ──encrypt──►  gitops/<app>/<app>-secret.enc.yaml  ──►  repo-server + KSOPS decrypt
                                         values are ENC[...], keys readable          → real k8s Secret → pods
```

One rule covers everything: **a value is either `ENC[AES256_GCM,...]` in git, or it is not in
git at all.** Plaintext never gets committed.

---

## 1. What exists today

### Encrypted in git (SOPS + age, decrypted by Argo via KSOPS)

| File | Secret → namespace | Keys | Used by |
|---|---|---|---|
| `gitops/immich/prereqs/immich-secret.enc.yaml` | `immich-secret` → media | `REDIS_PASSWORD` | Immich (Valkey user `redis` @ .103) |
| `gitops/degoog/degoog-secret.enc.yaml` | `degoog-secret` → apps | `DEGOOG_SETTINGS_PASSWORDS` | degoog |
| `gitops/komf/komf-secret.enc.yaml` | `komf-secret` → media | `KAVITA_API_KEY` | Komf ⚠️ **template, not yet encrypted** |
| `gitops/romm/romm-secret.enc.yaml` | `romm-secret` → media | `ROMM_AUTH_SECRET_KEY`, `DB_PASSWD`, `REDIS_PASSWORD`, 6 optional provider keys | RomM ⚠️ **template, not yet encrypted** |

Each one has a sibling `<app>-secret.sops.yaml` (the KSOPS *generator*, not a secret — it just
says "decrypt that file") and is listed under `generators:` in the app's `kustomization.yaml`.

### Still hand-created in the cluster (NOT in git — recreate after a rebuild)

| Secret | Namespace | Holds | Where it's documented |
|---|---|---|---|
| `sops-age` | argocd | the age **private key** — the master key, can never be in git | this doc §2 |
| `immich-db` | media | Postgres password for Immich's in-cluster vector DB | `docs/immich.md` |
| `vaultwarden-db` | apps | full `postgresql://` URI to the Postgres LXC | `docs/vaultwarden.md` |
| `vaultwarden-admin` | apps | /admin panel token (panel currently disabled) | `docs/vaultwarden.md` |
| `grafana-admin` | monitoring | Grafana admin user/password | `docs/logging.md` |
| `cloudflare-api-token` | cert-manager | DNS-01 token — **all TLS depends on it** | `docs/sops-argocd.md` Phase 9 |

Migrating these into `.enc.yaml` files is the open item from `docs/sops-argocd.md` Phase 9.

### Known debt ⚠️
- `gitops/degoog/deployment.yaml` still has the Valkey URL **inline in plaintext**, including the
  password of the shared `redis` user. It is in git history on GitHub. Fix = rotate that password
  on the Valkey host, update `immich-secret`, move the URL into `degoog-secret`. Encrypting later
  does not un-leak it (Phase 8 of `docs/sops-argocd.md`).

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
sops -d gitops/immich/prereqs/immich-secret.enc.yaml
```
`.sops.yaml` at the repo root already matches `*.enc.yaml`, `*.sops.yaml` and `*secrets.yaml`
and names the public key, so none of the commands below need flags.

The cluster side is already done: the `sops-age` Secret in the `argocd` namespace is mounted
into the repo-server at `/etc/sops-age/keys.txt` (`gitops/argocd/repo-server-ksops-patch.yaml`).
If you ever rebuild the cluster, recreate it **first**, or no app with a secret will sync:
```bash
sudo k3s kubectl create secret generic sops-age -n argocd --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
```

**Back up `keys.txt`** in Vaultwarden *and* somewhere outside the cluster. Lose it and every
`.enc.yaml` in git is unreadable forever.

---

## 3. The five commands

```bash
# VIEW — whole file decrypted to the terminal, file untouched
sops -d gitops/immich/prereqs/immich-secret.enc.yaml

# EXTRACT — one value, e.g. to paste it somewhere else
sops -d --extract '["stringData"]["REDIS_PASSWORD"]' gitops/immich/prereqs/immich-secret.enc.yaml

# EDIT — decrypts into $EDITOR, re-encrypts on save (add/change/remove keys here)
sops gitops/degoog/degoog-secret.enc.yaml

# ENCRYPT — a plaintext template, in place, first time only
sops -e -i gitops/komf/komf-secret.enc.yaml

# VERIFY — before every commit. sops refuses to decrypt a file that was never encrypted,
# so a clean round-trip proves the file is ciphertext:
sops -d gitops/komf/komf-secret.enc.yaml > /dev/null && echo "ENCRYPTED - safe to commit"
#   "sops metadata not found"  → still plaintext, do NOT commit
grep -c 'ENC\[' gitops/komf/komf-secret.enc.yaml      # should equal the number of values (+1 for the mac line)
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
# example: give RomM the same Valkey password Immich uses
sops -d --extract '["stringData"]["REDIS_PASSWORD"]' gitops/immich/prereqs/immich-secret.enc.yaml
#  → paste into REDIS_PASSWORD in gitops/romm/romm-secret.enc.yaml
#  → in gitops/romm/deployment.yaml set REDIS_USERNAME to "redis" (the shared user) instead of "romm"
sops -e -i gitops/romm/romm-secret.enc.yaml
```
Do **not** do this with the Valkey password until the debt in §1 is fixed — you would be
spreading a password that is already public in git history. Prefer a fresh ACL user per app
(`docs/redis.md`).

Reading a value that only exists in the cluster (hand-managed ones):
```bash
sudo k3s kubectl get secret immich-db -n media -o jsonpath='{.data.password}' | base64 -d; echo
```

---

## 5. Adding a secret to a new app (checklist)

Using `myapp` in namespace `media` as the example. Four files touch:

```yaml
# 1. gitops/myapp/myapp-secret.enc.yaml  — plaintext for ~30 seconds, then encrypted
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
# 2. gitops/myapp/myapp-secret.sops.yaml  — the KSOPS generator (safe, holds no secret)
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
# 3. gitops/myapp/kustomization.yaml  — generator, NOT resource
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
sops -e -i gitops/myapp/myapp-secret.enc.yaml     # 5. encrypt
# 6. VERIFY (see §3) → commit → push → kubectl apply the Argo app → Sync
sudo k3s kubectl get secret myapp-secret -n media  # 7. exists → KSOPS worked
```
Copy `gitops/komf/` as a template — it is the smallest complete example.

---

## 6. Rotating a secret

1. Change the real credential at its source (DB `ALTER ROLE`, Valkey `ACL SETUSER`, regenerate
   the API key in the app's UI).
2. `sops gitops/<app>/<app>-secret.enc.yaml` → paste the new value → save.
3. Push → Sync → `rollout restart` the deployment.
4. If the old value was ever committed in plaintext, rotating is **mandatory**, not optional.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `sops: no key could be found` / `failed to decrypt` on your machine | no `~/.config/sops/age/keys.txt` here → §2 |
| `sops: no matching creation rules` | filename doesn't end in `.enc.yaml` / `.sops.yaml` |
| Argo: `secret "<app>-secret" not found`, pod `CreateContainerConfigError` | the `.enc.yaml` is still plaintext (KSOPS refuses it) → encrypt, push, sync |
| Argo: `plugin ... not allowed` / `exec` error | repo-server KSOPS patch or `--enable-alpha-plugins --enable-exec` missing (`gitops/argocd/argocd-cm.yaml`) |
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
- The private key: Arch box, Argo's `sops-age` Secret, Vaultwarden, one offline copy. Never git.
- One Secret per app, one DB role / Redis ACL user per app.
