# OpenBao — where secrets live (replacing SOPS)

> **Status (Nov 2026): migration in progress.** OpenBao runs on a Proxmox LXC and has had its one-time
> setup (§5). The cluster side (External Secrets Operator, §7) is next. Until that ships, apps still get
> their secrets the SOPS way described in `secrets.md`.

This doc explains **what** was set up and **why each piece is the way it is**, in enough detail that you
could rebuild it from nothing, or decide to change it, without guessing.

---

## 1. Why we're replacing SOPS

SOPS kept a copy of every secret **in git, encrypted**. That model is sound, but the way it worked here
kept biting:

| What kept going wrong | Root cause |
|---|---|
| "I encrypted it, but the file is still plaintext" | the age **private** key lives only on the Arch box. Any other machine (the Mac) can't encrypt-and-verify or decrypt, so you end up with two copies of a file in different states |
| a template with `REPLACE_ME` got committed | every secret is born as a plaintext file you must remember to encrypt before `git add` |
| `MAC mismatch` / "secret not found" at Sync | an encrypted file was edited by hand, or the KSOPS generator wasn't wired into `kustomization.yaml` |
| Argo needed special surgery | the repo-server is patched to carry `ksops` + `kustomize` + the age key (`bootstrap/argocd/repo-server-ksops-patch.yaml`) |

The new model removes the class of problem instead of patching each one:

> **Secret values never touch git at all.** Git only says *where* a value lives
> ("Grafana's admin password is at `homelab/grafana`, key `admin-password`"). The value itself lives
> in OpenBao, and a controller in the cluster fetches it.

No keys on laptops, nothing to encrypt, no plaintext copies to forget, and a stock Argo CD.

### Why OpenBao and not something else
Researched Nov 2026 (sources in the conversation that produced this doc):

| Option | Verdict |
|---|---|
| **OpenBao** ✅ | Truly open source (MPL-2.0, Linux Foundation): no paid tier, no license key, nothing feature-gated. A fork of HashiCorp Vault, so Vault's docs, tooling and External Secrets' **most mature provider** all apply. One small binary |
| Infisical | Friendlier UI, but **open-core**: a proprietary `ee/` tree needs a license key that phones home. Audit logs, rotation and SSO are paid. Heavy (~1 GB idle + Postgres + Redis) and churns fast (several releases a week) |
| Sealed Secrets | Removes KSOPS but keeps the "run a CLI to encrypt every change" step, you can't read a value back out of git, and you must back up the cluster's private key or lose everything on a rebuild |
| Cloud managers (Doppler, 1Password, Bitwarden SM) | Work, but put the keys to everything with a third party, and some need paid plans for machine access |

---

## 2. Where it runs, and why there

```
┌─ Proxmox ─────────────────────────────────┐        ┌─ k3s ──────────────────────────────────────┐
│  LXC "openbao"  https://<LXC-IP>:8200     │        │  External Secrets Operator (ESO)           │
│    /opt/openbao  storage (encrypted)      │◄─HTTPS─┤    logs in with AppRole (read-only)        │
│    unlock key + root token: openbao.env   │  LAN   │    reads homelab/<app> → writes a normal   │
│    backed up by Proxmox (vzdump)          │        │    Kubernetes Secret → the pod, as today   │
└───────────────────────────────────────────┘        └────────────────────────────────────────────┘
```

**On Proxmox, never inside k3s.** A secret store inside the cluster it serves creates a chicken-and-egg
problem. Rebuild the cluster and the apps need the store, but the store is one of the things being
rebuilt, and it has secrets of its own. You'd be hand-creating secrets to start the secret manager.
Outside the cluster it's like the Postgres (.7) and Valkey (.103) LXCs: **things the cluster depends on
live outside it**, survive a rebuild untouched, and get Proxmox backups for free.

**Installed with the community script** (`community-scripts/ProxmoxVE` → `ct/openbao.sh`): a Debian 13
unprivileged LXC, 1 CPU / 1 GB / 4 GB, OpenBao from its official GitHub release `.deb`.

### What the install script did for you (and why it matters)
| It did | Consequence |
|---|---|
| started OpenBao with a **self-signed TLS** certificate on `:8200` | your browser warns. ESO must be told to trust that cert (§6), or connect fails |
| ran `bao operator init -key-shares=1 -key-threshold=1` | created the storage's master key, split into **1** unlock key (more on this in §3) and a **root token** |
| wrote `BAO_UNSEAL_KEY` and `BAO_ROOT_TOKEN` to `/etc/openbao/openbao.env` (mode 600, root) | both are on the box's disk. See §4 for why that's an acceptable trade here, and what it costs |
| added a systemd drop-in: `ExecStartPost=bao operator unseal ${BAO_UNSEAL_KEY}` | OpenBao **unlocks itself on every start**. Without this, every reboot of the LXC would leave it locked until you typed the key |

---

## 3. The concepts, briefly (you'll see these words everywhere)

**Sealed / unsealed.** Everything OpenBao stores on disk is encrypted. At start it doesn't know the key,
so it is **sealed**: running, but unable to read or serve anything. **Unsealing** gives it the key. Vault's
default is to split that key into 5 pieces and require 3 (Shamir's secret sharing), so no single person
can unlock it alone. That's right for a company and pointless for one person, hence `shares=1
threshold=1`. Check with `bao status` → `Sealed: false`.

**Root token.** Created once at init. It can do *anything*, bypassing every policy. Use it to set things up,
then put it away (§5 step 5 gives you a normal login).

**Tokens.** Everything in OpenBao is done *with a token*. Logging in (with a password, an AppRole, …)
just means trading credentials for a token with certain **policies** and a **TTL** (time to live).

**Policies.** Plain-text rules: "this token may `read` paths under `homelab/data/*`". No policy = no access.
Policies are how ESO gets read-only access while you get full access.

**Auth methods.** Different ways to log in and get a token: `token` (paste one), `userpass` (username +
password, for humans), `approle` (a role-id + secret-id pair, for machines), `kubernetes` (pods prove who
they are with their service account), and more.

**Secrets engines** are mounted at a path. We use **KV v2** (key-value, version 2) mounted at `homelab/`.
KV v2 keeps **version history**: every write is a new version, and old ones can be read or restored. Its
quirk: the API inserts `data/` and `metadata/` into paths, so `bao kv get homelab/grafana` really reads
`homelab/data/grafana`. That's why the policy below names `homelab/data/*`.

---

## 4. The security trade-offs, stated honestly

| Choice | What it costs | Why it's acceptable here |
|---|---|---|
| unlock key on the LXC's disk (auto-unseal) | anyone with a copy of the LXC (or its backup) can unlock it | the alternative is typing the key after every reboot, which is exactly the kind of recurring hassle this migration exists to remove. Infisical would keep its `ENCRYPTION_KEY` on its own box the same way. **So protect the backups**: they're as sensitive as the secrets |
| root token on disk | anyone with root on the LXC has full control | root on that LXC already means game over (they could read the unlock key). Optional hardening: revoke it after setup (§9) |
| self-signed TLS | no browser trust; ESO needs the cert pinned | it's LAN-only. Traffic is still encrypted, and pinning the exact cert in ESO is *stronger* than trusting any public CA |
| one node, no HA | if the LXC is down, no **changes** reach the cluster | already-created Kubernetes Secrets keep working. Apps don't notice an OpenBao outage, only new or changed secrets wait. Gatus will watch it |

**Where the keys must also live:** `BAO_UNSEAL_KEY` and `BAO_ROOT_TOKEN` in your password manager. If
the LXC's disk dies and the backup's `openbao.env` is gone too, the unlock key is the only way to ever
read the data again.

---

## 5. The one-time setup, step by step

Run in the LXC's console (Proxmox → the container → Console, log in as `root`).

### Step 1 — act as root in the CLI
```bash
source /etc/openbao/openbao.env && export BAO_TOKEN="$BAO_ROOT_TOKEN"
```
`openbao.env` sets `BAO_ADDR=https://127.0.0.1:8200` and `BAO_SKIP_VERIFY=true` (the CLI tolerates the
self-signed cert *from the box itself*) and holds the root token. The `bao` CLI reads `BAO_TOKEN` for
every command, so this logs the shell in as root. It lasts only for this shell session.

### Step 2 — a key-value store called `homelab`
```bash
bao secrets enable -path=homelab -version=2 kv
```
- **`kv` version 2:** the version history (§3). Overwrite a password by mistake and you can still read
  the old one with `bao kv get -version=N homelab/grafana`.
- **`-path=homelab`:** one mount for the whole homelab, one entry per app: `homelab/grafana`,
  `homelab/romm`, `homelab/karakeep`, … Each entry holds that app's keys, mirroring today's one-Secret-per-app layout.

### Step 3 — a read-only login for the cluster
```bash
bao policy write eso-read - <<'EOF'
path "homelab/data/*"     { capabilities = ["read"] }
path "homelab/metadata/*" { capabilities = ["read", "list"] }
EOF
bao auth enable approle
bao write auth/approle/role/eso token_policies=eso-read token_ttl=1h token_max_ttl=4h secret_id_ttl=0 secret_id_num_uses=0
```

**The policy `eso-read`.** Least privilege: ESO can read values (`data/*`) and list entries
(`metadata/*`), but never create, change or delete. If the cluster were ever compromised, the attacker
could read the homelab secrets (the cluster needs those anyway), but couldn't overwrite them or touch
anything outside `homelab/`.

**Why AppRole** for ESO, out of the options ESO supports:

| Option | Why not / why |
|---|---|
| a plain token | tokens expire. A non-expiring token means a root-made credential that never rotates, and ESO doesn't renew static tokens |
| `kubernetes` auth | the most "proper", but OpenBao must then call the k3s API to verify pod identities, so it needs a reviewer token, the cluster CA and network access to the API server. More moving parts across two machines, and it breaks on a cluster rebuild |
| **AppRole** ✅ | a machine username/password: **role-id** (not very secret, identifies the role) + **secret-id** (the secret). ESO logs in with them whenever it needs to and gets a **short-lived token**. One credential, created once, survives a cluster rebuild unchanged |

**The flags on the role:**
- `token_policies=eso-read`: every token ESO gets carries only the read-only policy.
- `token_ttl=1h` / `token_max_ttl=4h`: each login's token dies within hours. A leaked *token* is useless
  quickly; ESO simply logs in again.
- `secret_id_ttl=0` / `secret_id_num_uses=0`: the *secret-id* itself never expires and can be reused. That's
  a deliberate homelab choice: an expiring secret-id would silently stop secret delivery one day and need
  re-issuing. The trade is that the secret-id is a long-lived credential, which is why it lives only in
  your password manager and in one hand-made Kubernetes Secret.

### Step 4 — print the cluster's credentials
```bash
bao read -field=role_id auth/approle/role/eso/role-id; echo
bao write -f -field=secret_id auth/approle/role/eso/secret-id; echo
```
- The **role-id** is fixed for the role. You can re-read it any time.
- Each `write …/secret-id` **mints a new** secret-id (old ones keep working unless revoked). If you lose
  it, just mint another. To cut one off: `bao write auth/approle/role/eso/secret-id/destroy secret_id=…`.
- Save both in the password manager. They go into the cluster **once, by hand** (§7), the only
  hand-made secret in the whole design. That's the irreducible "secret zero": something has to prove
  the cluster is allowed in, and it can't come from OpenBao itself.

### Step 5 — an everyday admin login for you
```bash
bao policy write admin - <<'EOF'
path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
EOF
bao auth enable userpass
read -rs -p "New admin password: " PW; echo
bao write auth/userpass/users/william password="$PW" token_policies=admin; unset PW
```
- Using the root token day to day is like logging in as root for everything: it works, but there's no
  difference between "me" and "the master key". `userpass` gives you a normal username + password login.
  In the web UI, pick Method **Username**.
- `admin` grants everything, `sudo` included (some system paths require it). It's *your* account, so full
  power is the point; the difference from root is that it's a revocable, separate identity.
- `read -rs` asks for the password without echoing it, and keeps it out of shell history and the screen.
  `unset PW` clears it from the shell afterwards.

### Step 6 — find out what the TLS certificate covers
```bash
grep -A8 'listener' /etc/openbao/openbao.hcl
CERT=$(grep -oP 'tls_cert_file\s*=\s*"\K[^"]+' /etc/openbao/openbao.hcl)
openssl x509 -in "$CERT" -noout -subject -enddate -ext subjectAltName
hostname -I
```
ESO will connect to `https://<LXC-IP>:8200`. TLS verification passes only if the certificate
**names that IP** in its Subject Alternative Names (SANs) **and** ESO trusts the certificate. Step 6
shows the SANs and the expiry date:
- **SANs include the LXC's IP:** ESO is given this exact cert as its trust anchor (`caBundle`) and
  everything verifies.
- **They don't** (e.g. only `localhost`): we generate a replacement self-signed cert that includes the
  IP, point `openbao.hcl` at it, and restart. That's a one-off, documented here once done.
- **The expiry date** matters too: a self-signed cert that expires breaks ESO's connection on that date.
  We'll pick a long lifetime and add a Gatus certificate-expiry check.

---

## 6. Day-to-day (after the migration)

Add or change an app's secret. Either the web UI (Secrets → `homelab` → the entry → *Create new version*), or:
```bash
bao kv put  homelab/grafana admin-user=admin admin-password='…'   # replaces ALL keys in the entry
bao kv patch homelab/grafana admin-password='…'                   # changes one key, keeps the rest
bao kv get  homelab/grafana                                        # read (current version)
bao kv get  -version=2 homelab/grafana                             # read an older version
bao kv rollback -version=2 homelab/grafana                         # make version 2 current again
```
⚠️ `put` replaces the whole entry. Forgetting a key in a `put` deletes it from the new version (it's
still in history). Use `patch` to change one value.

ESO notices the change within its refresh interval (we'll set ~1h, with a forced refresh possible), and
updates the Kubernetes Secret. Pods that read the Secret as **env vars** need a restart to see it,
exactly as today.

---

## 7. The cluster side — External Secrets Operator (next, not done yet)

What gets added to the repo:
- **`kubernetes/apps/external-secrets/external-secrets/`**: ESO itself (Helm chart, pinned), a new Argo app.
- **A `ClusterSecretStore`**: "OpenBao is at `https://<LXC-IP>:8200`, KV v2 at `homelab`, log in with
  AppRole using the Secret `openbao-approle`, and trust this certificate."
- **The one hand-made Secret** (`openbao-approle` holding the role-id and secret-id), created once with
  `kubectl create secret …`. It's listed in `secrets.md` under "hand-created" with the rebuild steps.
- **Per app, an `ExternalSecret`** replacing `<app>-secret.enc.yaml` + `<app>-secret.sops.yaml`: "build
  the Secret `<app>-secret` from `homelab/<app>`". The resulting Secret has the **same name and keys** as
  today, so no Deployment changes.
- **Then removal:** the KSOPS repo-server patch, the `sops-age` secret, `.sops.yaml`, `scripts/secrets.sh`,
  and the SOPS checks in CI. Plus Gatus (OpenBao health + cert expiry) and a Homepage tile.

---

## 8. Backups & recovery

| Lose this | Recover with |
|---|---|
| the LXC (disk, accidental delete) | restore the Proxmox backup. It includes `openbao.env`, so it unseals itself |
| the LXC **and** its `openbao.env` | restore the data from backup, then unseal by hand with the `BAO_UNSEAL_KEY` from your password manager: `bao operator unseal <key>` |
| the unlock key everywhere | **the data is gone for good.** That's the point of encryption, and why it lives in the password manager |
| ESO's secret-id | mint a new one (§5 step 4), update the `openbao-approle` Secret |
| your admin password | log in with the root token (or regenerate one, §9) and reset it: `bao write auth/userpass/users/william password=…` |
| the whole k3s cluster | nothing to do on OpenBao. Re-create `openbao-approle`, Sync ESO, and every app's Secret comes back |

---

## 9. Optional hardening (later)

- **Revoke the root token** once setup is done: `bao token revoke "$BAO_ROOT_TOKEN"`, and delete the line
  from `openbao.env`. When you need root again, generate a fresh one from the unlock key with
  `bao operator generate-root`. Since the unlock key is on the box anyway, this mostly protects against
  casual misuse, not a determined attacker.
- **Audit log:** `bao audit enable file file_path=/var/log/openbao/audit.log` records who read or changed
  what. Free in OpenBao (paid in Infisical).
- **A real certificate** (e.g. through NPMplus as `vault.williampring.ca`) so the browser stops warning.
  Not needed for the cluster.

---

## 10. Troubleshooting

| Symptom | Check |
|---|---|
| UI/CLI says "Vault is sealed" | `bao status`. If sealed, the auto-unseal drop-in didn't run: `systemctl status openbao`, `journalctl -u openbao`, or unseal by hand with the key |
| `permission denied` in the CLI | the shell's token lacks a policy for that path. Re-run step 1 (root), or log in as yourself: `bao login -method=userpass username=william` |
| `x509: certificate signed by unknown authority` (from ESO) | ESO doesn't have the cert in `caBundle`, or the cert was regenerated. See §5 step 6 |
| `x509: certificate is valid for …, not <IP>` | the cert's SANs don't include the IP ESO connects to. Regenerate it (§5 step 6) |
| ESO: `invalid role or secret ID` | wrong or destroyed secret-id in `openbao-approle`. Mint a new one (§5 step 4) |
| a value changed in OpenBao but the app still has the old one | ESO hasn't refreshed yet (wait, or annotate the ExternalSecret to force it), and env-var consumers need a pod restart |
