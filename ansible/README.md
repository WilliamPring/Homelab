# Homelab Ansible — Barebones k3s + Tailscale

Automates the boring part of the homelab: install **Tailscale** and stand up a
**k3s** cluster (control plane + optional workers) with one command.

> New to Ansible? Read **[LEARN.md](LEARN.md)** first — it walks through every
> concept used here, mapped to *this* project. This README is just the how-to-run.

---

## What this does

| Play | Target | Action |
|------|--------|--------|
| 1 | all nodes | Install Tailscale, start the daemon, verify login |
| 2 | master | Install k3s control plane, capture the join-token |
| 3 | workers | Install k3s agent, join the cluster |

Currently **vanilla k3s over the LAN** — the simplest thing that works on a VM.
The Tailscale-as-flannel networking from your real homelab is behind variables in
`group_vars/all.yml` for when you move to real hardware (see LEARN.md → "Growing this").

---

## One-time setup

Ansible runs from your **control node** (your Arch Linux machine) and SSHes into
the nodes — nothing is installed on the targets ahead of time (it's *agentless*).

**On your Arch control node:**

```bash
# 1. Install Ansible
sudo pacman -S ansible

# 2. Make sure you can SSH into each node as a sudo-capable user, key-based:
ssh <user>@<node-ip>      # should log in without a password prompt
# If it asks for a password, copy your key first:  ssh-copy-id <user>@<node-ip>
```

**On the Debian nodes (master + workers):** Ansible needs almost nothing there —
just **SSH access + Python 3**, which Debian includes by default. The `curl` used
by the k3s installer is also standard on Debian. Nothing to pre-install in the
normal case; if a node is unusually minimal, `sudo apt install -y python3 curl`.

## Configure

Edit **one file** — `inventory.ini` — and point it at your VM:

```ini
[master]
homelab-master ansible_host=<YOUR_VM_IP> ansible_user=<YOUR_SSH_USER>
```

Leave `[workers]` empty for a single-node cluster.

## Run

```bash
cd ansible

# Dry run first — shows what WOULD change without touching anything.
ansible-playbook site.yml --check

# For real. Add --ask-become-pass if your SSH user needs a sudo password.
ansible-playbook site.yml --ask-become-pass
```

### The Tailscale login step

The first run will **stop** on the Tailscale play with a message like
"not logged in yet". That's expected. On the VM, run once:

```bash
sudo tailscale up --accept-dns=false
```

Open the printed URL, approve the machine, then **re-run the same command**:

```bash
ansible-playbook site.yml --ask-become-pass
```

This time it skips everything already done and finishes the k3s install. Getting
comfortable with "re-run until green" is the core Ansible mindset (see LEARN.md).

---

## Verify

```bash
# From the VM:
sudo k3s kubectl get nodes -o wide     # node should be Ready

# Grab the kubeconfig to use kubectl from your Arch control node (optional):
scp <user>@<vm-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/homelab.yaml
# then edit the `server:` line in that file to your VM's IP instead of 127.0.0.1
```

---

## Useful commands

```bash
ansible all -m ping                    # can Ansible reach every node?
ansible-playbook site.yml --check      # dry run (no changes)
ansible-playbook site.yml --list-tasks # show every task without running
ansible-playbook site.yml --tags ...   # (once you add tags) run a subset
```

---

## Layout

```
ansible/
├── ansible.cfg            # project config (inventory path, ssh behaviour)
├── inventory.ini          # THE file you edit: which machines, grouped by role
├── group_vars/
│   └── all.yml            # global knobs (k3s channel, install flags)
├── site.yml               # top-level playbook: 3 plays, run this
├── roles/
│   ├── tailscale/         # install + connect Tailscale
│   ├── k3s_server/        # control plane + join-token
│   └── k3s_agent/         # workers join the cluster
├── README.md              # you are here
└── LEARN.md               # the teaching guide
```
