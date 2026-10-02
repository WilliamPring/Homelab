# Homelab Ansible — cluster + infra only

Ansible builds the **cluster and the infrastructure the apps depend on**: Tailscale, k3s,
and the few out-of-git Secrets, node labels and Ingresses the GitOps apps still reference.

**Ansible deploys no apps.** Every app lives in `../gitops/` and is deployed by Argo CD.
Nothing here uses Helm, and the project needs no Ansible collections.

> New to Ansible? Read **[LEARN.md](LEARN.md)** first — it explains every concept used here,
> mapped to this project. This README is only the how-to-run.

---

## What `site.yml` does (6 plays, top to bottom)

| # | Play | Hosts | Role / tasks | Toggle |
|---|------|-------|--------------|--------|
| 1 | Tailscale | all k3s nodes | `tailscale` — install, start, verify login, report the 100.x IP | always |
| 2 | k3s server | master | `k3s_server` — install control plane, nfs-common, capture the join-token | always |
| 3 | k3s agents | workers | `k3s_agent` — install agent, nfs-common, join, wait for Ready | always |
| 4 | Immich infra | master | `immich` — `media` namespace, `immich-db` Secret, `immich-node=true` label on the 32GB worker | `immich_enabled` |
| 5 | App secrets | master | inline tasks — `apps` namespace, `vaultwarden-db` Secret (Postgres URI) | `vaultwarden_db_password` set |
| 6 | Ingresses | master | `tls_ingress` — the Vaultwarden + Immich Ingress objects (cert-manager + ClusterIssuer are on Argo) | `tls_enabled` |

Plays 4–6 exist only because Argo cannot create things that must stay out of git (DB
passwords) or that belong to the node (labels). Everything else about an app is in `gitops/`.

---

## One-time setup

Ansible runs from your **control node** (the Arch box) and SSHes into the nodes. Nothing is
installed on the targets ahead of time.

```bash
# control node
sudo pacman -S ansible

# key-based SSH to every node as a sudo-capable user
ssh <user>@<node-ip>              # no password prompt = good
ssh-copy-id <user>@<node-ip>      # if it did prompt
```

Debian targets need only SSH + Python 3 (both default). If a node is unusually minimal:
`sudo apt install -y python3 curl`.

### Secrets Ansible needs (never committed)
```bash
cp vars/secrets.example.yaml vars/secrets.local.yaml   # *.local.yaml is gitignored
$EDITOR vars/secrets.local.yaml                        # vaultwarden_db_password, immich_db_password
```
Plays 4 and 5 read this file and create the matching k8s Secrets. Without it they are skipped.
The Cloudflare token for cert-manager is created by hand once (see `docs/tls.md`).

---

## Configure

- **`inventory.ini`** — the machines. Today: one master + one worker (the 32GB box).
- **`group_vars/all.yml`** — the knobs: `k3s_channel`, `tailscale_up_args`, `immich_enabled`, `tls_enabled`.

---

## Run

```bash
cd ansible
ansible-playbook site.yml --syntax-check          # parses?
ansible-playbook site.yml --check                 # dry run — shows what WOULD change
ansible-playbook site.yml --ask-become-pass       # for real
```

### The Tailscale login step (first run only)
The first run **stops** on Play 1 with "not logged in yet". On that node:
```bash
sudo tailscale up --accept-dns=false
```
Open the printed URL, approve the machine, re-run the same `ansible-playbook` command. It
skips what is already done and continues. "Re-run until green" is the Ansible mindset.

### Re-running later
Safe at any time — every task is idempotent. Typical reasons: a rebuilt worker (needs the
Immich label + nfs-common again) or a lost `immich-db` / `vaultwarden-db` Secret.

---

## Verify

```bash
sudo k3s kubectl get nodes -o wide                              # all Ready
sudo k3s kubectl get node -l immich-node=true                   # the 32GB worker is labelled
sudo k3s kubectl get secret immich-db -n media vaultwarden-db -n apps 2>&1 | head -3
```
After this, follow `../docs/argocd.md` to bring up Argo CD, then `../docs/tls.md` for cert-manager.

---

## Useful commands

```bash
ansible all -m ping                        # reach every node?
ansible-playbook site.yml --list-tasks     # every task, without running
ansible-playbook site.yml --limit workers  # only one group
ansible-playbook site.yml --start-at-task "Copy the Ingress manifest to the master"
```

---

## Layout

```
ansible/
├── ansible.cfg              # inventory path, ssh behaviour, yaml output, ansible.log
├── inventory.ini            # the machines: [master], [workers], [k3s_cluster:children]
├── site.yml                 # the playbook — 6 plays, run this
├── group_vars/
│   └── all.yml              # knobs: k3s_channel, tailscale args, immich_enabled, tls_enabled
├── vars/
│   └── secrets.example.yaml # template → copy to vars/secrets.local.yaml (gitignored)
├── roles/
│   ├── tailscale/           # Play 1
│   ├── k3s_server/          # Play 2
│   ├── k3s_agent/           # Play 3
│   ├── immich/              # Play 4 — immich-db Secret + node label (Immich itself is on Argo)
│   └── tls_ingress/         # Play 6 — the two Ingresses still owned here (Vaultwarden, Immich)
├── README.md                # you are here
└── LEARN.md                 # the teaching guide
```

## Planned changes
- Move the Vaultwarden and Immich Ingress objects out of `tls_ingress` into their gitops
  app directories, so one app owns everything about itself.
- Ansible's end state: Tailscale, k3s, and the out-of-git Secrets/labels. Nothing else.
