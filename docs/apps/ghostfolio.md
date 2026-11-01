# Ghostfolio — portfolio tracker (stocks, ETFs, crypto)

Self-hosted dashboard for what you own and how it's doing, across every brokerage, in CAD.

**It has no bank or brokerage sync.** No Plaid, no Flinks, no account linking — that capability
doesn't exist in the software. You enter transactions or import a broker CSV. That's the point.

```
you ──► https://portfolio.williampring.ca (Tailscale) ──► Traefik ──► ghostfolio :3333
                                                                        │
                                                 Postgres LXC .7 ◄──────┤  all your data
                                                 ghostfolio-valkey ◄────┤  quote cache + job queue
                                                 Yahoo Finance ◄────────┘  outbound, quotes only
```

| Argo app | Path | Deploys |
|---|---|---|
| `ghostfolio` | `kubernetes/apps/apps/ghostfolio` | Deployment, a dedicated Valkey, ClusterIP Service, Ingress, SOPS secret |

| Thing | Where |
|---|---|
| Database | **the shared Postgres LXC `192.168.68.7`**, db/role `ghostfolio` |
| Cache | a **dedicated** Valkey pod — *not* the shared `.103`, see below |
| Storage | none. No PVC, no NFS — every byte of state is in Postgres |
| LAN NodePort | **none, deliberately** (service.yaml explains) |

---

## ⚠️ Why a dedicated Valkey and not the shared one

Ghostfolio builds its Redis connection in `apps/api/src/helper/redis.helper.ts` as:

```
redis://:password@host:port/db        ← empty username
```

There is no `REDIS_USERNAME` anywhere in its source. An empty username authenticates as Redis's
built-in **`default`** user — and `platform/redis.md` deliberately turns that user off
(`ACL SETUSER default off`) because every other app here uses a named ACL user.

The options were:

| | |
|---|---|
| Re-enable `default` on the shared Valkey | one leaked password would reach **every** app's keys. Rejected — one app's limitation shouldn't weaken a cluster-wide control |
| Give Ghostfolio its own | ~30MB of RAM. Chosen |

Its contents are a quote cache and a BullMQ job queue, both rebuilt on demand, so it uses
`emptyDir` rather than a PVC. Losing it costs one re-fetch of quotes.

---

## Setup

👉 **First time? Use the walkthrough instead:**
[`../runbooks/deploy-ghostfolio.md`](../runbooks/deploy-ghostfolio.md) — the same steps with the
*why* at each one, expected output, and a checklist. What follows here is the short reference.

### 1. Postgres role (on the LXC, once)
```bash
# copy scripts/postgres-ghostfolio-setup.sh to 192.168.68.7, then as root:
sh postgres-ghostfolio-setup.sh
```
It prints the password and the exact `DATABASE_URL` to use next.

### 2. Secrets — **on the Arch box** (it has the age key)
```bash
./scripts/secrets.sh set ghostfolio REDIS_PASSWORD=- ACCESS_TOKEN_SALT=- JWT_SECRET_KEY=-
./scripts/secrets.sh set ghostfolio DATABASE_URL='postgresql://ghostfolio:<PG_PASS>@192.168.68.7:5432/ghostfolio?connect_timeout=300'
./scripts/secrets.sh encrypt ghostfolio
```
`-` generates a strong random value. ⚠️ **Do not fill these in on a machine that cannot
encrypt** — this repo is public and a plaintext push is permanent.

`REDIS_PASSWORD` is used twice on purpose: the Valkey pod starts with `--requirepass` from it and
Ghostfolio connects with it. One value, two consumers.

### 3. DNS
Cloudflare → `ghostfolio` → A → the master's Tailscale IP, **grey cloud** (DNS-only).

### 4. Sync
Push → Argo registers it → Sync. First boot runs Prisma migrations, which is why there's a
`startupProbe` allowing 5 minutes before Kubernetes gives up.

```bash
sudo k3s kubectl get pods -n apps -l app=ghostfolio -w
sudo k3s kubectl logs -n apps deploy/ghostfolio --tail=50
curl -s https://portfolio.williampring.ca/api/v1/health
```

### 5. First login
Ghostfolio has no password — it issues a **security token** on account creation.
⚠️ **Save it in your password manager immediately.** There is no reset: lose it and the account
is gone, because `ACCESS_TOKEN_SALT` is what hashes it.

---

## Canadian specifics

### Tickers
Yahoo Finance symbols need the exchange suffix:

| Exchange | Suffix | Example |
|---|---|---|
| TSX | `.TO` | `VFV.TO`, `XEQT.TO`, `T.TO` |
| TSX Venture | `.V` | |
| CSE | `.CN` | |
| US | none | `AAPL` |
| Crypto | — | CoinGecko data source |

**Base currency is `BASE_CURRENCY` in `deployment.yaml`, not a UI setting** — there is no dropdown
for it in the app. It is set to `CAD`. ⚠️ Upstream documents it as **not changeable later**, so
changing it means starting from an empty database. The currency dropdown you *can* find under
My Ghostfolio is a per-user display preference, not this.

### ⚠️ This is not your tax number

Ghostfolio is a dashboard. It does **not** compute Canadian adjusted cost base, and three CRA
rules make that gap real for non-registered accounts:

1. **Pooling.** ACB is calculated as if all your accounts at all brokerages were one account.
   Ghostfolio shows per-account cost basis. If you hold the same stock at Computershare *and*
   TD, every per-account number is wrong.
2. **CAD at transaction-date rates.** A US holding's ACB uses the Bank of Canada rate on each
   trade date, not today's. Converting for display gets the dashboard right and the tax number
   wrong.
3. **Superficial loss rule.** 30 days either side, and it includes your spouse — stricter than
   the US wash-sale rule.

**For the filing number use [`tsiemens/acb`](https://github.com/tsiemens/acb)** — a Rust CLI built
for exactly this. It pulls Bank of Canada daily rates, applies the superficial loss rule, handles
multiple affiliated accounts (which is what pooling needs), and has converters for Questrade and
RBC Direct Investing exports. Run it once a year, not daily.

None of this applies to TFSA/RRSP/FHSA holdings — they're sheltered, you report nothing.

### Importing
| Source | Export |
|---|---|
| TD Direct Investing | CSV — the Export icon in WebBroker |
| Wealthsimple | CSV export |
| Computershare | likely PDF statements only — check Investor Centre. If so, hand-entry |

💡 **Start from today's positions, not from history.** Reconstructing years of DRIP purchases is
where this kind of project dies. Enter current holdings with a book value and let it accumulate.

---

## Mobile

A **PWA** — open the site on your phone and "Add to Home Screen". No official native app;
*Scaryfolio* on iOS is an unofficial third-party client.

⚠️ A PWA **pulls**, so it must reach the server to load. The hostname is Tailscale-only, so
Tailscale has to be up — the same thing that made ntfy unusable. There's no push fallback here
the way Bark has one.

---

## Day to day

| Want | Do |
|---|---|
| Add a transaction | Activities → + |
| Import a CSV | Activities → ⋮ → Import |
| Force a quote refresh | Admin Control → Data gatherer |
| Change a secret | `./scripts/secrets.sh edit ghostfolio` → Sync → `rollout restart` |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod never Ready, logs show Prisma errors | DB unreachable or wrong `DATABASE_URL`. Test from the node: `nc -zv 192.168.68.7 5432`. Check `pg_hba` has the `ghostfolio` line |
| `NOAUTH` / `WRONGPASS` in logs | `REDIS_PASSWORD` differs between the Valkey pod and Ghostfolio — they read the **same** secret key, so re-sync both and `rollout restart` |
| Killed during startup | migrations exceeded the `startupProbe` budget (5 min). Raise `failureThreshold`, don't lower the probe |
| Quotes blank / "no data" | wrong ticker symbol — Canadian listings need `.TO` / `.V` / `.CN` |
| Lost the security token | unrecoverable by design. New user, re-import. `ACCESS_TOKEN_SALT` hashes it |
| Logged out after a deploy | `JWT_SECRET_KEY` changed — harmless, log back in |
| Mutual funds won't resolve | Yahoo's coverage of Canadian mutual funds is patchy. Use the `MANUAL` data source and enter prices yourself |

## Quick reference
```
URL        https://portfolio.williampring.ca   (Tailscale only, no NodePort)
namespace  apps          image  ghostfolio/ghostfolio
DB         192.168.68.7  db/user ghostfolio     Cache  ghostfolio-valkey (in-cluster)
health     /api/v1/health
secret     ghostfolio-secret → DATABASE_URL, REDIS_PASSWORD, ACCESS_TOKEN_SALT, JWT_SECRET_KEY
```
