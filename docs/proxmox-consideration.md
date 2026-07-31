# Parked Decision: Proxmox vs. Bare-Metal k3s

Status: **DEFERRED / undecided.** Captured for consideration later.
Context: deciding whether to run a virtualization layer (Proxmox) under the homelab,
or keep running k3s directly on the hardware.

---

## The framing (important)
Proxmox and k3s are **not competitors at the same layer**:
- **Proxmox** virtualizes *machines* (a hypervisor OS).
- **k3s** orchestrates *containers*.

So the real choice is **k3s on bare metal** vs **k3s inside a Proxmox VM**. Proxmox
*adds a layer underneath* k3s — you still run k3s either way.

---

## What Proxmox adds (over bare-metal k3s)
| Capability | Why it matters |
|-----------|----------------|
| **Whole-machine snapshots + rollback** ⭐ | Break a VM → roll back the entire OS in seconds. Antidote to the "broke the node, must reinstall Debian + re-fix sudo/disk" pain we hit repeatedly |
| **Isolated environments on one box** | Stable "prod" VM + throwaway "lab" VM side by side |
| **Non-container workloads** | Full VMs of anything — TrueNAS, Home Assistant OS, Windows, pfSense/OPNsense firewall |
| **Whole-VM backups** | Back up/restore entire machine images (Proxmox Backup Server), not just app data |
| **Live migration + HA** (needs 2+ x86 nodes) | Move running VMs between hosts; auto-failover if one dies |
| **Machine-level GUI** | Create VMs / consoles from a browser (:8006) |

## What Proxmox costs
- **RAM overhead** — ~1.5 GB host + per-VM OS overhead (noticeable on 16 GB).
- **Complexity** — an extra layer to learn/maintain.
- **Still need k3s** — inside a VM; Proxmox hosts it, doesn't replace it.
- **Passthrough quirks** — USB (the DAS) / GPU passthrough to VMs can be fiddly.

---

## Our hardware reality (as of parking this)
- **1× HP 800 G5 Mini** (i5-9500T, 16 GB, x86) + **3× Rock 4B+** (2 GB, arm64).
- **Proxmox is x86-only** → the Rocks **cannot** be Proxmox nodes. They can only be a
  **QDevice** (quorum voter) or bare-metal k3s agents.
- **Clustering/HA needs 2+ x86 nodes** → NOT available with 1 HP. Only *single-node*
  Proxmox is possible today.

### Single-node Proxmox (what's actually on the table now)
- ✅ Gives: **snapshots/rollback** + **prod/lab isolation** + **run non-container VMs** +
  future-proofs for a 2nd HP (then it clusters).
- ❌ No clustering/HA (needs HP #2). Costs RAM overhead on 16 GB.

---

## Tailscale integration (if we go Proxmox)
- **Tailscale on the Proxmox host** → manage the web UI/SSH securely from anywhere.
- **Tailscale in each k3s VM** → reuse our existing `tailscale` role unchanged (a VM is
  just a Debian node). Matches our current per-node design.
- **Subnet router on the host** → optionally expose LXC containers without per-container
  Tailscale (LXC has a TUN-device gotcha; VMs don't).

---

## The decision, boiled down
| You want… | Choose |
|-----------|--------|
| Lean, simple, all RAM to workloads, "just run containers" | **Bare-metal k3s** |
| Snapshot/rollback safety net + run non-container stuff + lab isolation | **Proxmox** (single-node now) |

**Leaning:** given the repeated "broke it, had to reinstall" pain, the snapshot/rollback
safety net is the strongest argument *for* Proxmox — but it's a real trade against 16 GB
and simplicity. No wrong answer.

## Revisit this when…
- **HP #2 arrives** → clustering + HA + live migration become available (Proxmox's
  headline features). This is the natural trigger to seriously adopt Proxmox.
- **We want non-container workloads** (TrueNAS, Home Assistant OS, a firewall VM).
- **The "break it / rebuild" cycle gets painful enough** that rollback is worth the RAM.

## Adding a node later is EASY (so deferring is low-risk)
- Join a 2nd Proxmox node: GUI "Join Cluster" or `pvecm add` (~2 min; node must be empty).
- Add a k3s agent: Ansible re-run.
- The real bottleneck is consistent OS provisioning — fix once with a preseed/recipe.

Deferring costs nothing: bare-metal k3s now can be migrated into Proxmox VMs later, and
adding the hypervisor layer doesn't require throwing away the Ansible/k3s work.
