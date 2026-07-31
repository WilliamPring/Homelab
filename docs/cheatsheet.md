# Homelab Cheat Sheet

Everyday commands for this homelab — Ansible, k3s/kubectl, and node/OS.
Tip: `alias k='sudo k3s kubectl'` on the nodes to save typing.

---

## Ansible (run from your Arch laptop, in `ansible/`)

```bash
ansible all -m ping                       # can Ansible reach every node? (tests SSH+python+sudo)
ansible <host> -m ping                    # test one host
ansible-playbook site.yml -K              # run everything (-K = ask sudo password)
ansible-playbook site.yml -K --check      # DRY RUN (won't bootstrap a fresh node — see note)
ansible-playbook site.yml -K --limit master        # only the master
ansible-playbook site.yml -K --tags pihole         # only tagged tasks
ansible-playbook site.yml -K -vvv         # verbose (debug a failing task)
ansible-inventory --graph                 # show the group tree

# Bootstrap a fresh node without Python (raw needs no python on target):
ansible <host> -m raw -a "apt-get update && apt-get install -y python3 sudo curl" -K --become
```
> `--check` can't bootstrap a fresh box (shell/command tasks are skipped in check mode,
> so dependent steps fail). Use it only on an already-set-up cluster to detect drift.

---

## Cluster & nodes

```bash
sudo k3s kubectl get nodes -o wide                        # nodes, IPs, status, roles
sudo k3s kubectl describe node <name> | grep -A6 Conditions   # DiskPressure/MemoryPressure
```

## The single most useful debug command
```bash
sudo k3s kubectl get events -A --sort-by=.lastTimestamp | tail -30
# cluster-wide timeline: evictions, failed mounts, image-pull errors, scheduling fails
```

## Pods — status, why, logs
```bash
sudo k3s kubectl get pods -A -o wide             # everything + which node
sudo k3s kubectl get pods -n <ns> -o wide        # one namespace
sudo k3s kubectl describe pod -n <ns> <pod>      # WHY it's Pending/CrashLoop (events at bottom)
sudo k3s kubectl logs -n <ns> <pod>              # app logs
sudo k3s kubectl logs -n <ns> <pod> -f           # follow (live)
sudo k3s kubectl logs -n <ns> <pod> --previous   # logs from a CRASHED container
sudo k3s kubectl logs -n <ns> deploy/<name>      # by deployment (no pod name needed)
sudo k3s kubectl exec -it -n <ns> <pod> -- sh    # shell inside the container
```
**Status decoder:** `Pending`=can't schedule/mount→describe pod · `CrashLoopBackOff`=starts then dies→logs --previous · `ImagePullBackOff`=can't pull→describe pod · `Evicted`=node pressure→describe node

## Networking
```bash
sudo k3s kubectl get svc -n <ns>                 # ports / NodePort numbers
sudo k3s kubectl get endpoints -n <ns> <svc>     # empty = service not pointing at a pod
```

## Storage
```bash
sudo k3s kubectl get pvc -A                       # Bound vs Pending
sudo k3s kubectl get storageclass                 # is local-path the default?
sudo k3s kubectl describe pvc -n <ns> <name>      # why it won't bind
```

## Resource usage
```bash
sudo k3s kubectl top nodes                        # CPU/RAM per node
sudo k3s kubectl top pods -A --sort-by=memory     # biggest RAM hogs
```

## Fixing / poking
```bash
sudo k3s kubectl rollout restart deploy/<name> -n <ns>       # restart cleanly
sudo k3s kubectl rollout status  deploy/<name> -n <ns>       # wait until ready
sudo k3s kubectl scale deploy/<name> -n <ns> --replicas=0    # stop/park an app
sudo k3s kubectl delete all -l app=<name> -n <ns>            # nuke an app by label
sudo k3s kubectl delete pod -n <ns> --field-selector=status.phase=Failed   # sweep evicted pods
```

---

## k3s / node-level (below kubectl)

```bash
sudo systemctl status k3s            # master service   (workers: k3s-agent)
sudo journalctl -u k3s -f            # k3s logs (why a node won't start/join)
sudo journalctl -u k3s-agent -e      # worker join failures
sudo k3s crictl images               # images on THIS node + sizes (disk debugging)
sudo k3s crictl rmi --prune          # reclaim disk from unused images
sudo cat /var/lib/rancher/k3s/server/node-token    # worker join token (master)

# Uninstall (clean slate):
sudo /usr/local/bin/k3s-uninstall.sh          # server / master
sudo /usr/local/bin/k3s-agent-uninstall.sh    # worker / agent
```

---

## Node OS (Debian)

```bash
df -h /                 # disk usage (watch for DiskPressure)
lsblk                   # disks, partitions, LVM volumes, mount points
free -h                 # RAM

# Grow an LVM volume (fixes a too-small /var etc.):
sudo vgs                                        # free space in the volume group (VFree)
sudo lvs                                        # logical volumes + sizes
sudo lvextend -L +30G /dev/<vg>/<lv>            # grow the volume
sudo resize2fs /dev/<vg>/<lv>                   # grow the ext4 filesystem (xfs: xfs_growfs)

# User / sudo (Debian: group is 'sudo', not 'wheel'):
su -                                            # become root (root password)
usermod -aG sudo <user>                         # grant sudo (re-login to apply)

# Tailscale:
sudo tailscale up --accept-dns=false            # log in (prints a URL to click)
tailscale status                                # connection state
tailscale ip -4                                 # this node's tailnet IP
```

---

## Your personal top 5 (given what you've hit)
1. `sudo k3s kubectl get events -A --sort-by=.lastTimestamp` — what just happened
2. `sudo k3s kubectl describe node <n> | grep -A6 Conditions` — DiskPressure/evictions
3. `sudo k3s kubectl describe pod -n <ns> <pod>` — why a pod is stuck
4. `df -h /` + `sudo k3s crictl rmi --prune` — disk problems
5. `ansible all -m ping` — is the cluster reachable before a run

Install **`k9s`** on your Arch laptop — a terminal UI that does 90% of the above with arrow keys.
