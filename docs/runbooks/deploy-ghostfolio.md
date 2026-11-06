# Deploying Ghostfolio — a step-by-step walkthrough

The first app you've added that needs **three** things outside the cluster: a database role, a
set of secrets, and a DNS record. This walks through all of it in order, explaining what each
step is for, so the next app that needs a database is something you can do without a guide.

Reference for the app itself: [`../apps/ghostfolio.md`](../apps/ghostfolio.md).

**Roughly 25 minutes**, most of it waiting for a certificate.

```
 ⓪  this machine         can it reach OpenBao? (preflight)
 ①  Postgres LXC .7      create a role + database        ← the only place your data lives
 ②  Redis                nothing to do (see why)
 ③  OpenBao              put the secrets in               ← whichever box passed ⓪
 ④  Cloudflare           one A record
 ⑤  push                 Argo notices the directory
 ⑥  Argo UI              Sync
 ⑦  browser              create the account, SAVE THE TOKEN
```

**Where each command runs** — this trips people up more than anything else:

| Step | Where | How you get there |
|---|---|---|
| ① | inside the **Postgres LXC** | Proxmox console, or `ssh root@192.168.68.7` |
| ③ | a machine **logged in to OpenBao** | `bao login -method=userpass username=william` (LAN or Tailscale) |
| ⑥ | the **master** / Argo web UI | `sudo k3s kubectl …` |

---

## ⓪ The machine you're working from

**What you're doing:** proving this machine can finish the job *before* you start, so you don't
discover halfway through step ③ that you can't reach OpenBao.

Secrets no longer live in git at all — they live in **OpenBao** (`https://192.168.68.91:8200`, LAN/Tailscale
only), and External Secrets copies them into the cluster. So any machine with the `bao` CLI and a login can do
step ③; nothing secret is ever written into the repo. Full background:
[`../platform/openbao.md`](../platform/openbao.md).

```bash
git clone git@github.com:WilliamPring/Homelab.git    # or git pull, if it's already there
cd Homelab
bao login -method=userpass username=william          # BAO_ADDR / CA set up as in platform/openbao.md
bao kv list homelab                                   # the preflight
```

You want a list of app names (`ghostfolio`, `romm`, …). **If it fails:** no `bao` CLI, wrong `BAO_ADDR`,
not on the LAN/Tailscale, or OpenBao is sealed — [`../platform/openbao.md`](../platform/openbao.md) covers each.

You'll also want, on this machine:

| Need | Check | Used in |
|---|---|---|
| ssh to the Postgres LXC | `ssh root@192.168.68.7 true` | ① |
| git push access | `git push --dry-run` | ⑤ |
| Tailscale up | `tailscale status` | ⑥, ⑦ |

- [ ] ⓪ `bao kv list homelab` works

---

## ① Postgres — a role and a database

**What you're doing:** Ghostfolio stores everything — holdings, transactions, users — in
Postgres. You already run one Postgres LXC shared by several apps, and the house rule is **one
role and one database per app**, so a compromised or buggy app can only reach its own data.

Copy the script to the LXC and run it as root:

```bash
# from your laptop
scp scripts/postgres-ghostfolio-setup.sh root@192.168.68.7:/tmp/

# then, inside the LXC
sh /tmp/postgres-ghostfolio-setup.sh
```

**What it does**, so the output isn't mysterious:

1. creates the role `ghostfolio` with a random 32-char password
2. creates the database `ghostfolio` owned by it
3. appends one line to `pg_hba.conf` allowing `ghostfolio@192.168.68.0/24` with `scram-sha-256`
4. reloads Postgres (a reload, not a restart — nothing else is disturbed)

It is **idempotent**: safe to re-run, but re-running *resets the password*, so you'd have to
redo step ③.

**Expect** it to end with a block like:

```
============================================================
 Postgres ready for Ghostfolio
   host 192.168.68.7 · port 5432 · db ghostfolio · user ghostfolio
   PASSWORD: aB3dE...
 >>> Ghostfolio takes ONE connection URL, not separate fields. On the Arch box:
   ./scripts/secrets.sh set ghostfolio \
     DATABASE_URL='postgresql://ghostfolio:aB3dE...@192.168.68.7:5432/ghostfolio?connect_timeout=300'
============================================================
```

📋 **Copy that whole `DATABASE_URL` value now.** You need it in step ③, and the password is not
recoverable — re-running the script issues a new one. (The script still prints the old
`./scripts/secrets.sh` command around it; ignore that and use step ③'s `bao` command.)

**Verify** (still in the LXC):

```bash
su postgres -c "psql -tAc \"SELECT datname FROM pg_database WHERE datname='ghostfolio'\""
# → ghostfolio
```

- [ ] ① done, DATABASE_URL copied

> **Why a URL and not separate host/user/password fields?** Most apps here take them separately
> (see RomM's `DB_HOST`, `DB_USER`, `DB_PASSWD`). Ghostfolio only accepts one connection string.
> Since that string contains the password, the whole thing has to be a secret — which is why
> `deployment.yaml` has no database host written in it at all.

---

## ② Redis — nothing to do

**What you're doing:** confirming you can skip a step, and why.

Every other app that needs Redis uses the shared Valkey at `192.168.68.103` with its own ACL
user. **Ghostfolio can't.** Its source builds the connection as:

```
redis://:password@host:port/db        ← no username, ever
```

An empty username authenticates as Redis's built-in `default` user, and
[`../platform/redis.md`](../platform/redis.md) deliberately turns that user **off** so every app
must use a named one.

Rather than weaken that for one app, Ghostfolio gets its own small Valkey **inside the cluster**
(`valkey.yaml`). It deploys with the app — no host, no ACL, nothing to configure. Its contents
are a quote cache and a job queue, both rebuilt on demand, which is why it has no PVC.

- [ ] ② nothing to do — move on

> **If you'd rather use the shared Valkey**, it's possible but you'd be accepting that the
> `default` user (with `~*`) can read every app's keys, and you'd need `REDIS_DB: "3"` so
> Ghostfolio's "Flush cache" button can't wipe Immich's queue. The trade-off is written up in
> [`../apps/ghostfolio.md`](../apps/ghostfolio.md).

---

## ③ Secrets — into OpenBao

**What you're doing:** putting four values into OpenBao at `homelab/ghostfolio`. They never go into
git — `kubernetes/apps/apps/ghostfolio/externalsecret.yaml` (already in the repo) tells External Secrets
to copy exactly these four keys into the `ghostfolio-secret` Secret.

⚠️ **This step needs the machine that passed step ⓪** (logged in to OpenBao). **Never paste these
values into a file in the repo** — it is public, and a plaintext push is permanent.

Fill in the values:

```bash
# three self-contained secrets (random) + the database URL from step ①
# (single quotes on the URL: the password may contain shell characters)
bao kv put homelab/ghostfolio \
  REDIS_PASSWORD="$(openssl rand -hex 32)" \
  ACCESS_TOKEN_SALT="$(openssl rand -hex 32)" \
  JWT_SECRET_KEY="$(openssl rand -hex 32)" \
  DATABASE_URL='postgresql://ghostfolio:PASTE_PASSWORD@192.168.68.7:5432/ghostfolio?connect_timeout=300'
```

⚠️ `bao kv put` **replaces every key** at that path with only the ones on the command line — right for
this first fill (all four at once), wrong for changing one later. To change a single value, always use
`bao kv patch homelab/ghostfolio KEY=…`.

**What these four are:**

| Key | What it does | If you change it later |
|---|---|---|
| `DATABASE_URL` | connection string **incl. the password** | must match Postgres — change it there first |
| `REDIS_PASSWORD` | used **twice**: the Valkey pod starts with `--requirepass` from it, Ghostfolio connects with it | both read the same key, so they can't drift |
| `ACCESS_TOKEN_SALT` | hashes your login token | ⚠️ **invalidates every token** — you'd lose the account |
| `JWT_SECRET_KEY` | signs session cookies | harmless, just logs you out |

**Verify:**

```bash
bao kv get homelab/ghostfolio
```

Expect exactly four keys, no `REPLACE_ME`. After the Sync in step ⑥, External Secrets builds the
Secret within seconds (and re-reads OpenBao every hour). If you change a value later, force it with
`sudo k3s kubectl -n apps annotate externalsecret ghostfolio-secret force-sync=$(date +%s) --overwrite`
and `rollout restart` — env vars are read at start.

- [ ] ③ four values in `homelab/ghostfolio`

> **Why key names are in git but values aren't:** `externalsecret.yaml` lists the key *names* (which
> OpenBao property becomes which Secret key). That's deliberate — it's how `make conventions` can check
> that every `secretKeyRef` points at a key that exists, with no access to OpenBao in CI. Adding a new key
> later means both: the value in OpenBao **and** a new entry in `externalsecret.yaml`.

---

## ④ DNS — one record

**What you're doing:** pointing a hostname at the cluster, before the cert is requested.

Cloudflare → `williampring.ca` → DNS → **Add record**:

| Field | Value |
|---|---|
| Type | `A` |
| Name | `ghostfolio` |
| IPv4 | the **master's Tailscale IP** (same as your other apps) |
| Proxy status | **DNS only** (grey cloud) ⚠️ |

⚠️ **The grey cloud is not optional.** Orange-cloud proxying would route through Cloudflare's
network to a Tailscale IP they cannot reach, and it breaks the DNS-01 certificate challenge.

**Verify:**

```bash
dig +short portfolio.williampring.ca
# → the master's Tailscale IP (100.x.x.x), nothing else
```

- [ ] ④ A record created, grey cloud, resolves

---

## ⑤ Push — Argo registers the app

**What you're doing:** nothing manual. This is the step people expect to be hard.

```bash
git add -A
git commit -m "feat: ghostfolio"
git push
```

The ApplicationSet watches `kubernetes/apps/*/*`. A new directory becomes a new Application on
its own — **you never write an Application file and never `kubectl apply` a new app.**

⚠️ **The push is the trigger**, not the commit. The generator reads the repo on GitHub, not your
working tree. An unpushed commit is the usual reason an app never shows up.

Within ~3 minutes:

```bash
sudo k3s kubectl -n argocd get applications | grep ghostfolio
# → ghostfolio   OutOfSync   Missing
```

Impatient? Force a re-scan:

```bash
sudo k3s kubectl annotate applicationset apps -n argocd \
  argocd.argoproj.io/application-set-refresh=true --overwrite
```

- [ ] ⑤ `ghostfolio` appears in Argo

---

## ⑥ Sync

**What you're doing:** the one deliberate "deploy" action. Nothing in this homelab deploys itself.

Argo UI → `ghostfolio` → read the diff (it's the whole app the first time) → **Sync**, nothing
ticked.

Then watch it come up:

```bash
sudo k3s kubectl get pods -n apps -l app=ghostfolio -w
```

⚠️ **The first start is slow — this is normal.** Ghostfolio runs database migrations against the
empty database before it answers anything. That's why `deployment.yaml` has a `startupProbe`
allowing **5 minutes** before Kubernetes gives up. Expect `0/1 Running` for a minute or two
before it flips to `1/1`.

Watch the migrations if you're curious:

```bash
sudo k3s kubectl logs -n apps deploy/ghostfolio -f
```

Then the certificate (1–2 minutes, issued over DNS-01):

```bash
sudo k3s kubectl get certificate -n apps ghostfolio-tls
# → READY True
```

**Verify end to end**, from a Tailscale-connected device:

```bash
curl -s https://portfolio.williampring.ca/api/v1/health
# → {"status":"ok"}
```

That endpoint returns 200 only when **both** Postgres and the Valkey are reachable — one check
covering all three pieces. It's the same URL Gatus monitors.

Your phone should also get a Bark push: **"ghostfolio: deployed"**.

- [ ] ⑥ pod `1/1`, cert READY, health returns ok

---

## ⑦ First login — and the thing you must not lose

Open <https://portfolio.williampring.ca> → **Get Started** → create your account.

🔑 **Ghostfolio has no password. It gives you a security token — a long random string — and that
is the only way back in.**

**Save it in your password manager before you click anything else.**

There is no reset, no recovery email, no admin override. `ACCESS_TOKEN_SALT` is what hashes it,
so even you can't reverse it from the database. Lose the token and the account is gone; you'd
create a new one and re-enter your data.

Then set your base currency:

**Settings → Base currency → CAD.** Do this before entering anything, so US holdings convert
consistently from the start.

- [ ] ⑦ account created, **token saved**, base currency CAD

---

## ⑧ Your first holding

Activities → **+** → add one you know well:

| Field | Example |
|---|---|
| Symbol | `VFV.TO` ⚠️ the `.TO` matters |
| Type | BUY |
| Date / Quantity / Unit price | from your statement |
| Currency | CAD |

Canadian tickers need the exchange suffix or Yahoo won't resolve them:

| Exchange | Suffix |
|---|---|
| TSX | `.TO` — `VFV.TO`, `XEQT.TO`, `T.TO` |
| TSX Venture | `.V` |
| CSE | `.CN` |
| US | none — `AAPL` |

If the price stays blank, the symbol is wrong. Search it on finance.yahoo.com and use exactly
what's shown.

💡 **Enter today's positions, not your full history.** Reconstructing years of Computershare DRIP
purchases is where this kind of project dies at 40% done. Enter what you hold now with a
reasonable book value and let it accumulate forward.

- [ ] ⑧ one holding showing a live price

---

## When something is wrong

| Symptom | Where to look |
|---|---|
| Pod `CrashLoopBackOff`, logs mention Prisma or `ECONNREFUSED` | DB unreachable. From the master: `nc -zv 192.168.68.7 5432`. Then check the `pg_hba` line from step ① exists |
| Logs say `NOAUTH` / `WRONGPASS` | the Valkey pod and Ghostfolio disagree on `REDIS_PASSWORD`. They read the *same* secret key, so re-Sync and `rollout restart deploy/ghostfolio -n apps` |
| Pod killed after ~5 min of starting | migrations exceeded the `startupProbe` budget. Raise `failureThreshold` in `deployment.yaml` — don't shorten the probe |
| Pod `CreateContainerConfigError`: `secret "ghostfolio-secret" not found` | External Secrets couldn't build it — a key missing in `homelab/ghostfolio`, or OpenBao sealed/unreachable. `sudo k3s kubectl -n apps describe externalsecret ghostfolio-secret`, then redo step ③ |
| Certificate stuck `READY False` | orange cloud on the DNS record, or the record is missing. `kubectl describe certificate ghostfolio-tls -n apps` |
| Site loads on laptop, not phone | Tailscale is off on the phone. This is a PWA — it has to *reach* the server, unlike Bark which is pushed |
| Prices blank for everything | the data gatherer hasn't run. Admin Control → Data gatherer → refresh |

Full troubleshooting table: [`../apps/ghostfolio.md`](../apps/ghostfolio.md).

---

## What you just learned (reusable)

- **One role + one database per app** on the shared Postgres LXC, created by a small idempotent
  script. Copy `scripts/postgres-ghostfolio-setup.sh` for the next one.
- **Secret values go into OpenBao, never into git.** The repo only carries an `externalsecret.yaml`
  naming which keys to copy; External Secrets does the rest.
- **A new directory is a new app.** No Application file, no `kubectl apply` — but the *push* is
  what triggers it.
- **Sync is always manual**, and the first sync of a database-backed app is slow because of
  migrations.
- When an app can't fit a shared service's security model, **give it its own** rather than
  loosening the shared one.

## Afterwards

- ACB for tax is a *separate* tool — see the Canadian section of
  [`../apps/ghostfolio.md`](../apps/ghostfolio.md). Ghostfolio's numbers are not filing numbers.
- Renovate will open PRs for the image. Ghostfolio is in the **db-migration** group: it runs
  migrations on every start, so it never rides in a batch — read the release notes, merge, Sync.
