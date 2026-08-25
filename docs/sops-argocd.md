# Managing Secrets with SOPS + Argo CD — a hands-on guide

> A learn-by-doing walkthrough for encrypting your homelab's secrets **into git** so they're
> versioned, reproducible, and safe to commit — using **SOPS** + **age**, decrypted by
> **Argo CD** via **KSOPS**. Written around *your* actual secrets.

---

## Why you're doing this (the problem, in your repo)

Right now your secrets are in two bad states:

**1. One is exposed in git (plaintext):**
```
gitops/degoog/deployment.yaml → redis://:7jDtb86...@192.168.68.103:6379   ← anyone with repo access sees it
gitops/degoog/secrets.yaml     → a Secret object committed to git
```

**2. The rest are hand-managed (out of git) — not reproducible:**
```
vaultwarden-db · immich-db · degoog-secret · grafana-admin · cloudflare-api-token · searxng secret_key
```
These live only in the cluster. Every time a node/cluster is rebuilt, you recreate them **by
hand** (you've felt this pain — worker rebuilds, missing secrets, Postgres won't start).

**The goal:** every secret lives in git, **encrypted**, so a cluster rebuild is just `git sync`
— and nothing sensitive is ever readable in the repo.

```
BEFORE:  secret in my head / a kubectl command   → rebuild = recreate by hand 😩
AFTER:   encrypted secret in git                 → rebuild = Argo decrypts + applies 🎉
```

---

## The concepts (understand these before touching anything)

| Tool | What it is | One-liner |
|---|---|---|
| **SOPS** | Mozilla's Secrets OPerationS | Encrypts the **values** in a YAML/JSON file, leaves the **keys** readable |
| **age** | A modern encryption tool | Simpler than GPG — one keypair, no keyring hell |
| **KSOPS** | A kustomize plugin | Lets Argo CD **decrypt** SOPS files while it builds manifests |

### Why SOPS encrypts *values*, not whole files
```yaml
# a SOPS-encrypted secret still reads like YAML — only the VALUES are ciphertext:
apiVersion: v1
kind: Secret
metadata:
  name: degoog-secret
stringData:
  DEGOOG_SETTINGS_PASSWORDS: ENC[AES256_GCM,data:9x8...,tag:...]   # ← encrypted
```
This means **git diffs still make sense** ("the password field changed") without leaking the
value. That's the whole magic.

### Why Argo CD needs KSOPS (the catch)
Argo CD can't decrypt SOPS on its own. You have to teach its **repo-server** how:
```
Argo repo-server  +  KSOPS plugin  +  your age PRIVATE key
   → when it builds your app, KSOPS decrypts the .sops.yaml files into real Secrets → applies them
```
This is the one piece that makes SOPS+Argo more setup than Sealed Secrets. Worth it for the
git-diff-friendliness and tool-agnostic files.

---

## Architecture — how it flows

```
YOU (laptop)                          GIT                         CLUSTER (Argo CD)
────────────                          ───                         ─────────────────
age PUBLIC key ──encrypts──►  secret.sops.yaml  ──push──►  repo-server + KSOPS
                              (ciphertext, safe                    │  has the age PRIVATE key
                               to commit)                          ▼
                                                          decrypts → real k8s Secret → synced
age PRIVATE key ─────────────────────────────────────────────────┘
   (never in git — lives on your laptop + as a k8s secret in the argocd namespace)
```

**The golden rule:** the **public** key encrypts (safe to share/commit); the **private** key
decrypts (guard it — laptop + Argo only, backed up offline).

---

## Prerequisites
- `kubectl`/`k3s` access to the cluster (you have this).
- Argo CD running (you have this).
- A terminal on your Arch box.

---

# The plan (phases) — do them in order

```
Phase 1  Install sops + age, make a keypair
Phase 2  Back up the private key (do NOT skip — losing it = losing all secrets)
Phase 3  Configure .sops.yaml (what to encrypt, with which key)
Phase 4  Encrypt your FIRST secret (degoog-secret — the safe starter)
Phase 5  Teach Argo CD to decrypt (KSOPS in repo-server + the age key)
Phase 6  Wire it with kustomize (the ksops generator)
Phase 7  Point the Argo app at it → sync → verify
Phase 8  Rotate + migrate the EXPOSED degoog Valkey password
Phase 9  Migrate the remaining hand-managed secrets
```

---

## Phase 1 — Install tools + generate your age key

```bash
# Arch:
sudo pacman -S sops age

# generate your keypair (this file IS your private key):
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

# it prints your PUBLIC key — copy it, you'll need it everywhere you encrypt:
#   Public key: age1qw...longstring...
cat ~/.config/sops/age/keys.txt   # contains BOTH; the # comment line is the public key
```
**Learn:** `keys.txt` holds your private key (`AGE-SECRET-KEY-...`) and shows the public key.
The public key is what you share; the private key never leaves safe places.

---

## Phase 2 — ⚠️ Back up the private key (the #1 rule)

If you lose `keys.txt`, **every SOPS secret in git becomes permanently undecryptable.** Back it
up NOW, offline:
```bash
# store the private key somewhere safe + OFFLINE:
#   - your password manager (you run Vaultwarden! put it there)
#   - a USB drive / printed paper in a drawer
cat ~/.config/sops/age/keys.txt   # copy the AGE-SECRET-KEY-... line into Vaultwarden
```
> Ironic-but-good: back up the age key in **Vaultwarden**. Just don't make Vaultwarden's own
> secret depend on it in a way that creates a chicken-and-egg on a full rebuild — keep a copy
> outside the cluster too.

---

## Phase 3 — Configure `.sops.yaml`

At the repo root, a `.sops.yaml` tells SOPS *which files* to encrypt, *which fields*, and *with
which key* — so you don't retype flags every time:
```yaml
# .sops.yaml  (repo root)
creation_rules:
  # any file ending in .sops.yaml → encrypt only the data/stringData fields, with your age key
  - path_regex: .*\.sops\.yaml$
    encrypted_regex: "^(data|stringData)$"
    age: "age1qw...YOUR_PUBLIC_KEY..."
```
**Learn:** `encrypted_regex: ^(data|stringData)$` = encrypt only the secret *values*, leave
`metadata`, `kind`, etc. readable → clean diffs.

---

## Phase 4 — Encrypt your first secret (start with `degoog-secret`)

We start here because it's low-risk and you already have it. Write the plaintext secret, then
encrypt it in place.

```yaml
# gitops/degoog/degoog-secret.sops.yaml   (plaintext for now — about to encrypt)
apiVersion: v1
kind: Secret
metadata:
  name: degoog-secret
  namespace: apps
type: Opaque
stringData:
  DEGOOG_SETTINGS_PASSWORDS: "your-real-password-here"
```
Encrypt it (SOPS reads `.sops.yaml` automatically):
```bash
sops --encrypt --in-place gitops/degoog/degoog-secret.sops.yaml
```
Open it — `stringData` is now ciphertext, everything else readable. **This is now safe to
commit.** Delete the old plaintext `gitops/degoog/secrets.yaml`.

To edit it later (SOPS decrypts → your $EDITOR → re-encrypts on save):
```bash
sops gitops/degoog/degoog-secret.sops.yaml
```

---

## Phase 5 — Teach Argo CD to decrypt (KSOPS + the age key)

Two parts: give Argo the **private key**, and give its repo-server the **KSOPS plugin**.

### 5a. The age private key as a k8s secret (in the argocd namespace)
```bash
sudo k3s kubectl create secret generic sops-age -n argocd \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
```
This is the ONE secret you still create by hand — it's the master key that unlocks all the
others. (You can't encrypt the key that does the decrypting — chicken-and-egg.)

### 5b. Add KSOPS to the argocd-repo-server
Argo's repo-server needs the `ksops` + `sops` binaries and the age key mounted at
`SOPS_AGE_KEY_FILE`. The standard way is an **initContainer** that installs KSOPS + a kustomize
plugin config, plus mounting the `sops-age` secret.

> ⚠️ **Version-sensitive** — get the exact repo-server patch from the current KSOPS docs
> (https://github.com/viaduct-ai/kustomize-sops#argo-cd) rather than copying stale YAML. (You
> learned this lesson with the Loki chart — always check the source for the current manifest.)
> The gist you're implementing:
> ```
> argocd-repo-server:
>   + initContainer: install ksops + sops into a shared volume
>   + volumeMount:   that volume onto the repo-server's PATH
>   + env SOPS_AGE_KEY_FILE=/.../keys.txt  (from the sops-age secret)
>   + kustomize build flags: --enable-alpha-plugins --enable-exec
> ```

**Learn:** the repo-server is the component that *renders* your manifests, so that's where
decryption has to happen — before the rendered Secret is applied to the cluster.

---

## Phase 6 — Wire it with kustomize (the ksops generator)

KSOPS runs as a kustomize **generator**. Convert the degoog app folder to kustomize:

```yaml
# gitops/degoog/secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: degoog-secret-generator
files:
  - ./degoog-secret.sops.yaml
```
```yaml
# gitops/degoog/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: apps
generators:
  - ./secret-generator.yaml      # KSOPS decrypts degoog-secret.sops.yaml → a real Secret
resources:
  - ./deployment.yaml
  - ./degoog-service.yaml
  - ./ingress.yaml
  - ./valkey.yaml
  - ./valkey-service.yaml
  - ./pvc.yaml
```
**Learn:** `generators:` is how kustomize plugins (like KSOPS) inject resources it produces at
build time — here, the decrypted Secret.

---

## Phase 7 — Point the Argo app at it → sync → verify

Your degoog Argo Application already uses `path: gitops/degoog` — since there's now a
`kustomization.yaml` there, Argo auto-detects it as a **kustomize** app (no Application change
needed). Then:
```bash
# push, then in Argo: degoog → SYNC
sudo k3s kubectl get secret degoog-secret -n apps            # exists (KSOPS created it)
sudo k3s kubectl get secret degoog-secret -n apps -o jsonpath='{.data.DEGOOG_SETTINGS_PASSWORDS}' | base64 -d; echo
# → your real password  (proof: git had ciphertext, Argo decrypted it into a real Secret)
```
If Argo errors on the sync about `plugins`/`exec`, the repo-server KSOPS setup (Phase 5b) isn't
right — recheck the flags/initContainer against the KSOPS docs.

**🎉 Milestone:** you now have a secret that lives *encrypted in git* and is decrypted
automatically by Argo. Rebuild the cluster → `git sync` restores it. No more by-hand.

---

## Phase 8 — Rotate + migrate the EXPOSED Valkey password ⚠️

This one is special: `redis://:7jDtb86...@192.168.68.103:6379` has been **committed to git in
plaintext** — which means it's in your **git history forever**, even after you encrypt it.
Encrypting going forward is NOT enough.

**You MUST rotate it (change the actual password):**
```bash
# 1. change the password ON the Valkey host (192.168.68.103):
#    edit valkey.conf → requirepass <NEW_PASSWORD> → restart valkey
# 2. put the NEW password in an ENCRYPTED secret + reference it (don't inline it):
```
```yaml
# gitops/degoog/degoog-secret.sops.yaml  (add the valkey URL here, then re-encrypt)
stringData:
  DEGOOG_SETTINGS_PASSWORDS: "..."
  DEGOOG_VALKEY_URL: "redis://:<NEW_PASSWORD>@192.168.68.103:6379"
```
Then in `deployment.yaml`, replace the inline value with a `secretKeyRef` to `degoog-secret`,
and `sops --encrypt --in-place` the file. Re-sync.

> 🔑 **The lesson:** once a secret hits git plaintext, it's compromised — rotate it, don't just
> hide it. (Optionally scrub history with `git filter-repo`/BFG, but rotating is what actually
> protects you.)

---

## Phase 9 — Migrate the remaining hand-managed secrets

Now repeat the Phase 4/6 pattern for each, so a rebuild restores everything from git:

| Secret | Namespace | Encrypt into | Notes |
|---|---|---|---|
| `immich-db` | media | `gitops/immich/prereqs/immich-db.sops.yaml` | Postgres password |
| `vaultwarden-db` | apps | `gitops/vaultwarden/vaultwarden-db.sops.yaml` | full postgresql:// URI |
| `grafana-admin` | monitoring | `gitops/kube-prometheus-stack/grafana-admin.sops.yaml` | admin-user + admin-password |
| `cloudflare-api-token` | cert-manager | `gitops/cert-manager/cf-token.sops.yaml` | ⚠️ ALL your TLS depends on it |
| searxng `secret_key` | apps | move from ConfigMap → a `.sops.yaml` Secret | currently a git placeholder |

Each: write plaintext `.sops.yaml` → `sops --encrypt --in-place` → add to a `kustomization.yaml`
generator → sync. The `sops-age` key already unlocks them all.

> The **only** hand-created secret that remains is `sops-age` (the master key) — everything else
> becomes reproducible from git.

---

## Key management & backup (don't skip)
```
age PRIVATE key (keys.txt):
  ✅ on your laptop (~/.config/sops/age/keys.txt)
  ✅ as k8s secret 'sops-age' in the argocd namespace
  ✅ backed up OFFLINE (Vaultwarden + a USB/paper) — losing it = losing all secrets
  ❌ NEVER in git
```
**Multi-recipient tip:** you can add more than one `age:` key in `.sops.yaml` (e.g. a laptop key
+ a backup key). Any listed key can decrypt — good insurance.

---

## Gotchas (learned the hard way)
| Symptom | Cause / fix |
|---|---|
| Argo sync: `plugin ... not allowed` / `exec` error | repo-server missing `--enable-alpha-plugins --enable-exec` or KSOPS not installed (Phase 5b) |
| `sops: no matching creation rules` | file doesn't match `path_regex` in `.sops.yaml` (name it `*.sops.yaml`) |
| Decrypts to empty / `failed to decrypt` | `sops-age` secret missing or wrong key in the argocd namespace |
| Secret updates but pod doesn't restart | k8s doesn't auto-restart on Secret change → `rollout restart` (or use a checksum annotation) |
| Exposed secret "fixed" but still in git history | you didn't ROTATE it — encrypting later doesn't un-leak the old value |

---

## Your learning checklist
- [ ] Understand: SOPS encrypts values, KSOPS lets Argo decrypt, age is the key pair
- [ ] Generate + **back up** the age key (Phase 1–2)
- [ ] Encrypt `degoog-secret` and see ciphertext in git (Phase 4)
- [ ] Get Argo decrypting it (Phase 5–7) — the real milestone
- [ ] **Rotate** the exposed Valkey password (Phase 8)
- [ ] Migrate the rest so a rebuild needs only the `sops-age` key (Phase 9)

---

## Is this the right choice vs Sealed Secrets?
```
SOPS + Argo (this) → tool-agnostic files, great diffs, needs KSOPS in repo-server (more setup)
Sealed Secrets     → simpler on Argo (no plugin), but Bitnami-adjacent + less flexible
```
You chose SOPS — it's the more powerful, portable option. The one cost is the repo-server KSOPS
setup (Phase 5b); after that, the day-to-day (`sops file.sops.yaml` to edit) is lovely.

---

*Start with Phases 1–7 on `degoog-secret` — get one secret flowing end-to-end before migrating
the rest. That first "git had ciphertext, Argo made a real Secret" moment is the whole point.*
