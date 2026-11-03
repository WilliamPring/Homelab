# CI — the gate in front of git

Argo deploys whatever is on `main`. CI is the only thing that looks at a change *before* it
becomes "what Argo deploys". It never touches the cluster — it reads the repo and says yes or no.

```
you push / Renovate opens a PR
        │
        ▼
 ┌─ GitHub Actions ───────────────────────────────────────────────┐
 │ manifests    renders every app the way Argo will, schema-checks │
 │ conventions  the rules kustomize cannot see (this repo's own)   │
 │ lint         yamllint                                           │
 │ renovate     renovate.json still parses                         │
 │ render-diff  posts "here is what the cluster will change"       │
 └────────────────────────────────────────────────────────────────┘
        │  green
        ▼
 merge → Argo sees the new commit → OutOfSync → Bark → you click Sync
```

Everything also runs locally — **`make check`** is the whole gate in one command.

---

## The four gate jobs

### 1. `manifests` → `scripts/ci/validate.sh`
| # | Check | Catches |
|---|---|---|
| 1 | every `*.enc.yaml` is SOPS-encrypted, no `REPLACE_ME` — **WARN-only** (`STRICT_SECRETS: "0"`) | a plaintext secret template reaching `main` |
| 2 | every directory with a `kustomization.yaml` renders (KSOPS generator stripped) | bad patch targets, typos, the Argo "manifest generation error" class |
| 3 | plain manifest directories are valid YAML | broken indentation |
| 4 | chart-source `Application` files render via `helm template` | chart values-schema errors |
| 5 | kubeconform over everything rendered, with the CRD catalog | field names that render fine but the API server rejects |

It cannot decrypt anything (no age key in CI), or prove a secret's *value* is right.

> **⚠️ Check 4 was dead for a while.** It globbed `kubernetes/bootstrap/apps/*.yaml`, a directory
> of hand-written Application files that the `kubernetes/apps/<ns>/<app>` + ApplicationSet
> refactor deleted. The glob matched nothing, so it rendered zero charts — and still printed
> `PASS`. Coverage was never actually lost (Immich and cert-manager carry `helmCharts:` in their
> `kustomization.yaml`, so check 2 renders them), but the PASS was a lie for weeks.
>
> **The lesson is general: a check that cannot fail is worse than no check**, because it buys
> confidence it hasn't earned. When you add one, break something on purpose and watch it go red
> before you trust it.

### 2. `conventions` → `scripts/ci/check-conventions.sh`
The rules that live in `CLAUDE.md` and `adding-an-app.md` rather than in the Kubernetes schema.
Every one of these is *legal YAML that deploys fine and is still wrong here*:

| Check | Why it exists |
|---|---|
| **A. ApplicationSet depth** | the generator globs `kubernetes/apps/*/*`. A directory one level off is **silently ignored** — no error, in Argo or anywhere else. The app just never appears |
| **B. NodePorts** | unique + in 30000–32767. A clash fails at Sync with "already allocated", which reads like an Argo bug |
| **C. Image pinning** | no bare `:latest`. Renovate can only bump a number, and `latest` makes rollback impossible |
| **D. secretKeyRef ↔ Secret keys** | a `secretKeyRef` naming a key the Secret doesn't declare. The pod then hangs in `CreateContainerConfigError` long after Sync says Succeeded |
| **E. `REPLACE_ME` anywhere** | WARN. The `*.enc.yaml` check in `validate.sh` only looks at secret files — the Bark device key lives in a plain Deployment, so nothing could see it |
| **F. Ingress** | one host per hostname, each with TLS + the cluster-issuer annotation |
| **G. Workloads** | WARN: readiness probe + resource bounds. Argo health and Gatus both trust readiness — a container with no probe is reported "Healthy" the instant it starts, before it can serve |

**Check D is the interesting one.** SOPS with `encrypted_regex: ^(data|stringData)$` encrypts
*values* but leaves *key names* in cleartext:

```yaml
stringData:
  DEGOOG_SETTINGS_PASSWORDS: ENC[AES256_GCM,data:xmHCzr2...]
  ^^^^^^^^^^^^^^^^^^^^^^^^^ readable                ^^^^^^ not
```

So CI can verify every `secretKeyRef` points at a key that exists **without holding the age key
at all**. A secret-name/key typo is caught on the PR instead of at 11pm after a Sync.

### 3. `lint` — yamllint, pinned
### 4. `renovate-config` — `renovate.json` still parses under `--strict`

Runs a **pinned** Renovate (`RENOVATE_VERSION`) on the Node that Renovate's own `engines` field
allows (44.x: `^24.11.0`). ⚠️ Don't let that Node run ahead of Renovate. Unpinned, `npx renovate`
isn't "latest": npm picks the newest version whose engines accept the running Node. When Renovate
bumped this job to Node 26 (Nov 2026), npm installed Renovate 37.x from 2024, which rejected
`managerFilePatterns`, and the job went red. A `packageRules` entry in `renovate.json` now holds
this Node at 24; raise it once Renovate's engines move to the next Node major.

---

## `render-diff` — what the change does to the *cluster*

Not a gate; a reviewer aid, and the one job with a write permission (to post its comment).

The problem it solves: **a PR shows you source, Argo applies objects.** Renovate's diff is one
line —

```diff
-    version: 1.2.3
+    version: 1.3.0
```

— and the chart behind it can add a container, drop a volume, rename every object, or quietly
change a `securityContext`. You cannot review what you cannot see.

So the job renders every app at the PR's **base**, renders it at the **head**, and posts the diff
as a comment that updates in place on each push:

```diff
@@ -57,7 +57,7 @@
         env:
         - name: TZ
           value: America/Vancouver
-        image: finab/bark-server:v2.3.9
+        image: finab/bark-server:v2.4.0
```

- Secrets are absent from both sides (generators stripped), so it **cannot leak a secret value** —
  and equally cannot show you one changing.
- Fork PRs are skipped: they get a read-only token by design.
- Error output is normalised before diffing. kustomize puts a fresh random temp path in every
  error message, so an un-normalised failure **differs from itself on every run** — the comment
  would report a change on both sides of an unchanged, equally-broken app.

---

## ⚠️ CI does not block anything yet

`main` has **no branch protection**, so a red run still merges and direct pushes to `main` skip
PR checks entirely. Today CI is advice.

To make it a real gate, require the checks on `main`:

```bash
gh api -X PUT repos/{owner}/{repo}/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  -f 'required_status_checks[strict]=true' \
  -f 'required_status_checks[contexts][]=manifests (kustomize · helm · kubeconform · secrets)' \
  -f 'required_status_checks[contexts][]=conventions (applicationset · nodeports · secretrefs · pinning)' \
  -f 'required_status_checks[contexts][]=yamllint' \
  -F 'enforce_admins=false' \
  -F 'required_pull_request_reviews=null' \
  -F 'restrictions=null'
```

`enforce_admins=false` is deliberate: you are the only maintainer, and locking yourself out of
your own `main` at 2am during an outage is a worse failure than an unreviewed push.

Trade-off to decide with open eyes: protection means **work goes through a PR**. If you like
committing straight to `main`, the honest alternative is leaving it off and treating a red run as
something you actually stop for.

---

## Local

```bash
make check          # lint + validate + conventions — the whole gate
make conventions    # just this repo's rules (fast, no helm needed)
make validate       # render + schema-check everything (needs kubectl, helm, ruby, kubeconform)
make lint           # yamllint
make hooks          # install the pre-commit hooks, once per clone
```

Pre-commit runs the cheap checks on commit and the slow ones on push — **but only if you ran
`make hooks`, and only on your machine.** They are a convenience, not a gate. Anything that must
never reach `main` belongs in the workflow too.

## Supply chain

- Actions are pinned to major tags; Renovate's `github-actions` manager opens PRs for them.
- `kubeconform` is downloaded with a **pinned sha256** checked before extraction. Renovate bumps
  the version; you paste the new hash from the release's `CHECKSUMS` (both env vars, together).
- `yamllint` is version-pinned, so a new release cannot turn CI red on a commit that changed
  nothing.
- The Renovate validator is version-pinned too (`RENOVATE_VERSION`), and its Node is held to what
  Renovate supports; job 4 above explains why both matter.
- Workflow permissions are `contents: read` by default; only `render-diff` adds
  `pull-requests: write`, and `persist-credentials: false` keeps a push-capable token out of
  `.git/config` on every checkout.
