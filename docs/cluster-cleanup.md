# Cluster cleanup — orphans left behind by things removed from git

Deleting something from the repo does not delete it from the cluster (Argo apps have no
finalizer, and some things were never in Argo). This is the list of what is believed to be
still running or lying around, with a **LOOK** step before every **DELETE** step.

Run everything on the **master** as `sudo k3s kubectl …`. Do the LOOK block for an item,
compare with what the text says to expect, then run its DELETE block. Skip any item whose LOOK
shows nothing. Tick the box when done.

```bash
# convenience for this session
alias k='sudo k3s kubectl'
```

---

## 1. Old monitoring stack (kube-prometheus-stack, Loki, Alloy, Grafana) — removed Sept 2026

**LOOK**
```bash
k get ns monitoring
k get all,pvc,secret,certificate,ingress -n monitoring
k get crd | grep -E 'monitoring.coreos.com|grafana.integreatly.org'
k get clusterrole,clusterrolebinding | grep -iE 'prometheus|grafana|loki|alloy|kube-state|node-exporter'
k get mutatingwebhookconfiguration,validatingwebhookconfiguration | grep -i prometheus
```
Expect: a `monitoring` namespace with Loki PVC(s), the `grafana-admin` secret, maybe a
`grafana-tls` cert, plus `*.monitoring.coreos.com` CRDs and some cluster-scoped RBAC.

**DELETE**
```bash
k delete ns monitoring                                          # takes the PVCs + grafana-admin with it
k get crd -o name | grep monitoring.coreos.com | xargs -r sudo k3s kubectl delete
k get clusterrole,clusterrolebinding -o name | grep -iE 'prometheus|grafana|loki|alloy|kube-state|node-exporter' | xargs -r sudo k3s kubectl delete
k get mutatingwebhookconfiguration,validatingwebhookconfiguration -o name | grep -i prometheus | xargs -r sudo k3s kubectl delete
```
- [ ] done

## 2. nitter — removed Sept 2026

**LOOK**
```bash
k get ns nitter
k get all,pvc,secret,ingress -A | grep -i nitter
k get certificate -A | grep -i nitter
```
**DELETE**
```bash
k delete ns nitter 2>/dev/null
# if nitter lived in a shared namespace instead, delete by label/name from the LOOK output, e.g.:
# k delete deploy,svc,ingress,pvc,secret -n apps -l app=nitter
```
- [ ] done

## 3. Immich's old PostgreSQL 14 volume — PG16 has been in use since Aug 2026

**LOOK**
```bash
k get pvc -n media immich-postgres-data immich-postgres-data-v16
k get deploy -n media immich-postgres -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}'
```
Expect: both PVCs exist; the Deployment uses **`immich-postgres-data-v16`** (printed by the
second command). Only proceed if that is what it prints.

**DELETE**
```bash
k delete pvc -n media immich-postgres-data
```
Then remove the "keep the old PVC for rollback" note at the top of
`gitops/immich/prereqs/postgres.yaml`.
- [ ] done

## 4. Vaultwarden — removed from the repo Oct 2026

⚠️ **Export your vault first** (Bitwarden client → Export) if you have not already.

**LOOK**
```bash
k get application -n argocd vaultwarden
k get all,ingress,pvc -n apps -l app.kubernetes.io/instance=vaultwarden
k get secret -n apps vaultwarden-db vaultwarden-admin vault-tls
k get certificate -n apps
```
**DELETE**
```bash
k delete application -n argocd vaultwarden                     # Argo record only (no finalizer)
k delete all,ingress,pvc -n apps -l app.kubernetes.io/instance=vaultwarden
k delete secret -n apps vaultwarden-db vaultwarden-admin vault-tls
k delete certificate -n apps vault-tls 2>/dev/null             # ingress-shim named it after the TLS secret
```
Also, by hand:
- Cloudflare DNS: delete the `vault` A record.
- Postgres LXC (192.168.68.7): the `vaultwarden` database and role are **left in place as the
  backup**. When you are sure: `su postgres -c "psql -c 'DROP DATABASE vaultwarden;' -c 'DROP ROLE vaultwarden;'"`
  and remove its `pg_hba.conf` line. Keep the B2 backups until then.
- [ ] done

## 5. Argo Applications that exist in the cluster but not in git

**LOOK**
```bash
k get applications -n argocd -o name | sed 's|application.argoproj.io/||' | sort > /tmp/live.txt
ls gitops/apps/*.yaml | xargs -n1 basename | sed 's/\.yaml$//' | sort > /tmp/git.txt   # run from the repo
comm -23 /tmp/live.txt /tmp/git.txt                             # live but NOT in git
```
Expect: `vaultwarden` (until item 4), nothing else. Anything else listed is a leftover.

**DELETE** (per name from the output)
```bash
k delete application -n argocd <name>
```
- [ ] done

## 6. Stale TLS secrets / certificates for hostnames that no longer exist

**LOOK**
```bash
k get certificate -A
k get ingress -A
```
Every Certificate should correspond to an Ingress host that still exists. Candidates:
`grafana-tls`, `nitter-tls`, `vault-tls` (covered above).

**DELETE** (per leftover)
```bash
k delete certificate -n <ns> <name>
k delete secret -n <ns> <name>
```
- [ ] done

## 7. Repo-side leftovers (your laptop / Arch box)

```bash
git stash list                      # expect: stash@{0}: On main: stash kube pro stk  (old homepage + monitoring files)
git stash drop stash@{0}
```
- [ ] done

---

## After the cleanup
```bash
k get ns                                              # no monitoring / nitter
k get pvc -A                                          # only claims that belong to current apps
k get applications -n argocd                          # exactly the files in gitops/apps/
k get certificate -A                                  # all READY, one per live hostname
```
Then delete this file, or keep it as the template for the next removal.
