# How This Would Look in Production ("The Professional Way")

A teaching doc: how a professional/prod Kubernetes setup differs from this homelab,
what you're *already* doing right, and a concrete path to evolve toward it.

> Big idea: **homelab ≠ prod, and that's fine** — some simplifications here are correct
> choices, not mistakes. But knowing the professional target teaches you the *why*.

---

## What you're already doing RIGHT (this maps to real practice)
- **Infrastructure as Code** — the whole setup is in Git, repeatable. ✅
- **Declarative manifests** — you describe desired state, not steps. ✅
- **Config management with Ansible** — the standard tool for node provisioning. ✅
- **Roles / reusability** — DRY, composable. ✅
- **Namespaces by function** + **secrets awareness** (vault plan) + **Helm for heavy apps**. ✅

So you're not a beginner flailing — you've built legitimate IaC. The gaps below are the
"next levels," not corrections of mistakes.

---

## The professional reference architecture

```
PROVISIONING   Terraform/OpenTofu (infra)  +  immutable nodes (Talos / cloud-init / preseed)
CLUSTER        HA control plane (3+ nodes, embedded etcd)   ← not a single master
CONFIG         Ansible (minimal) — or NONE with an immutable OS like Talos
APP DELIVERY   GitOps: Argo CD or Flux   ← the cluster PULLS state from Git (not push)
PACKAGING      Helm charts + Kustomize overlays (per-environment)
SECRETS        SOPS+age / Sealed Secrets / External Secrets Operator + Vault
INGRESS/TLS    Ingress controller + cert-manager + ExternalDNS (auto DNS records)
OBSERVABILITY  Prometheus + Grafana + Loki (logs) + Alertmanager
STORAGE        Real CSI (Longhorn/Ceph) + Velero (backup/DR) + volume snapshots
SECURITY       RBAC + NetworkPolicies + Pod Security + Kyverno/OPA + Trivy scanning
CI             PR → lint/test/build/scan → registry → GitOps auto-deploys
```

### The professional *flow* (the key difference)
```
Engineer edits YAML  →  opens a Pull Request
     →  CI validates (lint, kubeconform, policy, image scan)
     →  merge to main
     →  Argo CD / Flux DETECTS the git change and SYNCS it to the cluster
     →  observability confirms healthy;  rollback = `git revert`
```
**Nobody runs `kubectl apply` by hand.** The cluster continuously reconciles itself to
match Git. Git is the single source of truth and the audit log.

---

## Current setup vs professional

| Concern | Your homelab (now) | Professional |
|---------|--------------------|--------------|
| **App delivery** | Ansible runs `kubectl apply` (push) | **GitOps** — cluster pulls from Git (Argo CD/Flux) |
| **Node provisioning** | Hand-installed Debian + Ansible | Automated (preseed/cloud-init) or **immutable OS (Talos)** |
| **Control plane** | Single master (SPOF) | **HA** — 3+ control-plane nodes |
| **Secrets** | plaintext `changeme` → ansible-vault | **SOPS / Sealed Secrets / External Secrets** (encrypted in Git) |
| **Ingress/TLS/DNS** | NodePort, manual certs | Ingress + **cert-manager** + **ExternalDNS** |
| **Observability** | Beszel/Uptime Kuma (planned) | **Prometheus + Grafana + Loki + Alertmanager** |
| **Storage** | local-path / mergerfs / restic | **CSI (Longhorn/Ceph) + Velero** |
| **Security/policy** | minimal | RBAC, NetworkPolicies, **Kyverno**, Trivy |
| **CI** | none | lint/test/build/scan pipeline |
| **Environments** | one cluster | dev/staging/prod (overlays or clusters) |
| **Node fixes** | manual SSH (sudo, disk, join) | **never** — nodes are reproducible/immutable |

---

## The #1 shift to learn: GitOps (push → pull)

This is the single biggest professional practice you're missing, and it's the most
worth learning:

- **Now:** you push changes *to* the cluster (`ansible-playbook` → `kubectl apply`).
- **Prod:** the cluster pulls its desired state *from* Git. You change Git; **Argo CD**
  notices and reconciles. Benefits: drift detection & auto-correction, full history,
  one-click rollback, a UI showing exactly what's deployed vs what Git says.

**Clean separation that results:**
```
Ansible  → provisions the MACHINES + cluster   (nodes, Tailscale, k3s, host services)
Argo CD  → manages the APPS inside the cluster  (everything in Layer 2)
```
Your Ansible stays — it just stops deploying *apps* and sticks to *infrastructure*.

---

## The prod answer to your node-provisioning PAIN: immutable OS (Talos)

All the friction you hit — no sudo, no python, tiny `/var`, hand-editing configs, SSH
fixes — **doesn't exist in professional k8s**, because prod nodes are **not hand-installed
and never SSHed into to fix**. Two approaches:

1. **Automated install** (preseed / cloud-init) — every node comes up identical. (The
   preseed file I mentioned.)
2. **Immutable Kubernetes OS — Talos Linux** ⭐ — a minimal OS built *only* to run k8s:
   - **No SSH, no shell, no package manager, no apt/sudo** — managed entirely by an API.
   - Nodes are declared in a config file; reproducible and disposable.
   - Eliminates the *entire class* of problems you've been fighting.

Talos is the modern "professional homelab" way to run bare-metal k8s. Worth knowing —
it's the antidote to the Debian papercuts.

---

## What's FINE to keep simple (homelab ≠ prod)
Don't over-engineer. These simplifications are correct for a homelab:
- **Single control-plane node** — HA (3 masters) is overkill at home.
- **local-path / mergerfs storage** — Ceph/Longhorn is heavy; your DAS+restic is fine.
- **Light monitoring** (Beszel/Uptime Kuma) — a full Prometheus stack is a lot to run.
- **One cluster, no staging** — you don't need dev/staging/prod at home.
- **Tailscale instead of a real LB/VPN stack** — perfect for a homelab.

The skill is knowing *which* prod practices are worth adopting vs which are enterprise
overkill for your scale.

---

## Evolution roadmap: from here → prod-grade (keeps everything you built)

1. **Keep Ansible for nodes only.** Tailscale + k3s + Samba + storage. (Already correct.)
2. **Adopt GitOps (Argo CD).** Move app manifests out of Ansible-apply into a Git repo
   Argo watches. *This is the big lesson.* Ansible installs Argo; Argo does the rest.
3. **Real secrets** — **SOPS+age** or **Sealed Secrets**, so encrypted secrets live in the
   GitOps repo (works with Argo). Replaces plaintext/ansible-vault for app secrets.
4. **Ingress + TLS + DNS** — finish **cert-manager**, add **ExternalDNS** (auto Cloudflare
   records). Move apps off NodePort onto real hostnames.
5. **Observability** — **kube-prometheus-stack** (Prometheus + Grafana + Alertmanager) +
   **Loki** for logs. Real dashboards and alerts.
6. **CI checks** — `ansible-lint`, `kubeconform`, `trivy` in a pipeline before merge.
7. **(Advanced, optional)** HA control plane, Longhorn CSI, Velero DR, Kyverno policies,
   Talos for immutable nodes.

Do them **in that order** — each is one new professional concept, and each builds on a
stable base. GitOps (step 2) is the highest-leverage thing to learn next.

---

## One-paragraph summary
Professionally, you'd **split responsibilities**: IaC/Terraform + an immutable OS (Talos)
or automated installs provision the **machines**; **GitOps (Argo CD/Flux)** continuously
delivers the **apps** from Git; **cert-manager + ExternalDNS** handle ingress/TLS/DNS;
**Prometheus/Grafana/Loki** give observability; **SOPS/Sealed Secrets** handle secrets in
Git; and a **CI pipeline** validates changes. Nobody hand-runs `kubectl` or SSHes in to fix
nodes. Your homelab already nails IaC and declarative config — the biggest professional
leap to learn next is **GitOps**, and the antidote to your node pain is an **immutable OS**.
