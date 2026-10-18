# debug/ — outputs of the read-only diagnostic scripts

Workflow (no copy/paste between machines — git is the courier):

```bash
make diag HOST=sysadmin@192.168.68.93      # copies scripts/debug/argocd-diag.sh to the master, runs it with sudo,
                                           # fetches the result into debug/argocd-diag.txt
git add debug/argocd-diag.txt && git commit -m "debug: argocd diag" && git push
```
Then whoever is helping reads `debug/argocd-diag.txt` from the repo. The script prints **no secret
values** (only names, statuses, versions, error messages, log lines). Overwrite it each run; delete
it when the issue is solved.
