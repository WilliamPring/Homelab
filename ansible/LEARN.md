# Learning Ansible — with your homelab as the textbook

You're a strong software engineer, so this skips programming basics and focuses on
the **Ansible-specific mental model**. Every concept is tied to a real file in this
project so you can jump between "the idea" and "where I actually used it."

Read top-to-bottom once. Come back to individual sections as reference later.

---

## 1. The one-sentence mental model

> Ansible is a way to describe the **desired end state** of a set of machines as
> code, and a tool that connects over SSH and makes reality match that description.

Two consequences fall out of that sentence, and they explain almost everything:

1. **Agentless** — Ansible runs on *your* machine (the "control node"). It SSHes in,
   pushes small Python programs (modules), runs them, collects results, and
   disconnects. The target nodes have *nothing* installed for Ansible. That's why
   setup here is just "install Ansible on your Arch control node + be able to SSH in."

2. **Idempotency** — because you describe *end state*, not *steps*, running a
   playbook twice is safe. A well-written task checks "am I already in the desired
   state?" and does nothing if so. This is the single most important habit to
   internalize. It's why our workflow is literally "run it, fix a thing, run it
   again" — reruns are free.

The mindset shift from your bash scripts (`rock4b-setup.sh`): those are a *sequence
of commands*. If you run one twice, it might error or double-apply. Ansible tasks
are *assertions about state* that converge.

---

## 2. The pieces, and where each one lives

Ansible has a small vocabulary. Here's all of it, mapped to this repo:

| Term | What it is | In this project |
|------|-----------|-----------------|
| **Control node** | The machine you run Ansible *from* | Your Arch Linux machine |
| **Inventory** | The list of managed machines + how they're grouped | `inventory.ini` |
| **Group** | A named set of hosts you target together | `[master]`, `[workers]`, `[k3s_cluster]` |
| **Play** | "Apply these roles to this group of hosts" | The 3 blocks in `site.yml` |
| **Playbook** | An ordered list of plays | `site.yml` |
| **Task** | One unit of work (calls one module) | Each `- name:` in `roles/*/tasks/main.yml` |
| **Module** | The actual worker (`systemd`, `command`, `slurp`…) | `ansible.builtin.systemd`, etc. |
| **Role** | A reusable, self-contained bundle of tasks | `roles/tailscale`, `roles/k3s_server`, `roles/k3s_agent` |
| **Variable** | A value you can reference/override | `group_vars/all.yml` |
| **Fact** | A variable *discovered at runtime* | `k3s_node_token` (set on the master) |
| **Handler** | A task triggered only when something changed | (not used yet — see §7) |

If you understand those 11 rows, you understand this project.

---

## 3. Inventory — who gets managed (`inventory.ini`)

```ini
[master]
homelab-master ansible_host=192.168.68.200 ansible_user=debian

[workers]

[k3s_cluster:children]
master
workers
```

- `homelab-master` is the **inventory hostname** — Ansible's internal name for the
  box. `ansible_host`/`ansible_user` tell it where to actually SSH.
- `[workers]` empty = single-node cluster. Play 3 targets an empty group and is
  simply skipped. No special-casing needed.
- `[k3s_cluster:children]` is a **group of groups** — the `:children` suffix means
  "made of other groups." It lets Play 1 say "install Tailscale on *every* node"
  with one target.

> Why INI and not YAML inventory? Both exist. INI is the least-typing format and
> perfect for a handful of hosts. You can switch to `inventory.yml` later if you
> want richer per-host structure.

**Try it:** `ansible all -m ping` — this uses the inventory to reach every host and
run the `ping` module (an SSH+Python reachability check, not ICMP).

---

## 4. The playbook and plays (`site.yml`)

A **playbook** is the top-level thing you run. It contains **plays**, each of which
binds a **group of hosts** to a **list of roles**:

```yaml
- name: Install and connect Tailscale on all nodes
  hosts: k3s_cluster      # WHO
  become: true            # run as root via sudo
  roles:
    - tailscale           # WHAT
```

- Plays run **top-to-bottom**. That ordering is deliberate: Tailscale first, then
  the master (which produces a token), then workers (which consume it).
- Within a play, all matched hosts are configured **in parallel**.
- `become: true` = "sudo to root for these tasks." Our roles touch systemd and
  `/var/lib/rancher`, so they need root.

---

## 5. Roles — the reusable unit (`roles/<name>/tasks/main.yml`)

A role is just a **convention-based folder**. When a play says `roles: [tailscale]`,
Ansible automatically runs `roles/tailscale/tasks/main.yml`. (Roles can also hold
`handlers/`, `templates/`, `defaults/`, `vars/`, `files/` — we only need `tasks/`
for now.)

Why roles instead of dumping all tasks in `site.yml`? **Composability.** Adding a
future service becomes "write a role, add one line to a play." That's the
extensibility you asked for, built in from day one.

### Anatomy of a task (from the Tailscale role)

```yaml
- name: Check whether the tailscale binary is already installed
  ansible.builtin.command: which tailscale
  register: tailscale_installed   # save the result into a variable
  changed_when: false             # this is a read; it never "changes" the system
  failed_when: false              # "not found" is an answer, not a failure

- name: Install Tailscale via the official script
  ansible.builtin.shell:
    cmd: curl -fsSL https://tailscale.com/install.sh | sh
  when: tailscale_installed.rc != 0   # only if the check above found nothing
```

Four ideas that show up everywhere:

- **`register`** captures a task's output (exit code `.rc`, `.stdout`, etc.) into a
  variable for later tasks to branch on.
- **`when`** is a conditional — the task runs only if the expression is true. This
  is how we get idempotency out of a raw `command`/`shell`.
- **`changed_when: false`** tells Ansible "this task never changes state," so it
  reports *ok* instead of a misleading *changed*. Cosmetic but important for trust.
- **`failed_when: false`** stops a non-zero exit from aborting the play when
  non-zero is a legitimate result.

> **`command` vs `shell`:** `command` runs a program directly (no shell, so no
> pipes/`|`, redirects, or `&&`). `shell` runs through `/bin/sh` so pipes work —
> that's why the installer tasks use `shell` (they pipe `curl … | sh`).

### `become` and idempotent installs

We don't have a native "install tailscale" module, so we emulate idempotency:
check-then-install. Native modules (like `ansible.builtin.systemd` below) are
idempotent *for free* — you declare the desired state and the module figures out
whether it needs to act:

```yaml
- name: Ensure the tailscaled daemon is enabled and running
  ansible.builtin.systemd:
    name: tailscaled
    enabled: true      # start on boot
    state: started     # running now
```

Run this on an already-running service → Ansible reports **ok** (no change). That's
the whole philosophy in one task.

---

## 6. Variables and facts — passing data around

### Static variables (`group_vars/all.yml`)

Files under `group_vars/<group>.yml` are auto-loaded for hosts in that group. The
special group `all` applies to everyone. This is where your **knobs** live:

```yaml
k3s_channel: "stable"
k3s_server_args: ""        # empty = vanilla k3s; add flags to change behaviour
tailscale_up_args: "--accept-dns=false"
```

Referenced in tasks with Jinja2 templating: `{{ k3s_channel }}`. Override at runtime
without editing files: `ansible-playbook site.yml -e k3s_channel=v1.30`.

### Facts — runtime-discovered variables

Sometimes a value only exists *after* a task runs. The k3s join-token is the classic
example: it doesn't exist until the server installs. We capture it, then **publish**
it so another host can read it:

```yaml
# On the master (roles/k3s_server):
- ansible.builtin.slurp:
    src: /var/lib/rancher/k3s/server/node-token
  register: k3s_token_file

- ansible.builtin.set_fact:
    k3s_node_token: "{{ k3s_token_file.content | b64decode | trim }}"
```

```yaml
# On a worker (roles/k3s_agent) — reach across to the master's facts:
- ansible.builtin.set_fact:
    k3s_token: "{{ hostvars[groups['master'][0]].k3s_node_token }}"
```

- `slurp` reads a remote file (base64-encoded); `| b64decode | trim` are **Jinja2
  filters** that clean it up.
- `hostvars` is the global bag of every host's variables. `groups['master'][0]` is
  "the first host in the master group." Together: "read the master's token." This
  cross-host data flow is *why* the plays are ordered master-before-workers.

### Waiting for reality to catch up

```yaml
- ansible.builtin.command: k3s kubectl get nodes
  register: k3s_nodes
  until: "' Ready' in k3s_nodes.stdout"
  retries: 20
  delay: 6
```

`until/retries/delay` = "re-run this task up to 20 times, 6s apart, until the
condition holds." The declarative way to say "wait for the node to be Ready"
instead of a blind `sleep`.

---

## 7. The concept reference — everything worth knowing

The core loop (inventory → playbook → plays → roles → tasks → modules, plus
variables/facts and idempotency) is above. This section is the **rest of Ansible**,
grouped by what it's *for*. Each entry is tagged **[used here]** (already in this
project) or **[next]** (you'll meet it as you grow). Skim now, return as reference.

### A. Running & connecting

- **Control node vs managed node** — [used here] You run Ansible on the *control
  node* (your Arch machine); it SSHes into *managed nodes* (the Debian cluster). Nothing is
  installed on the targets — **agentless**. (See the diagram we walked through.)
- **Push model** — [used here] Ansible *pushes* changes out over SSH on demand.
  (Contrast: Puppet/Chef *pull* on a schedule from a central server.)
- **Ad-hoc commands** — [used here, lightly] One-off, no playbook:
  `ansible all -m ping` or `ansible master -m command -a "uptime"`. Great for
  quick checks. Playbooks are for anything you want to repeat.
- **Connection plugins** — [next] *How* Ansible reaches a host. Default is `ssh`;
  others include `local` (run on the control node) and `docker`/`kubectl` (exec
  into a container/pod). Set with `ansible_connection`.
- **`become` (privilege escalation)** — [used here] Run tasks as another user,
  usually root via `sudo`. `become: true` in a play; `--ask-become-pass` if sudo
  needs a password. You can also escalate per-task.

### B. Control flow inside tasks

- **`when` (conditionals)** — [used here] Run a task only if an expression is true.
  Our idempotency gates (`when: k3s_installed.rc != 0`) are exactly this.
- **`loop` (iteration)** — [next] Repeat a task over a list. The declarative
  replacement for a bash `for`:
  ```yaml
  - name: Install packages
    ansible.builtin.package: { name: "{{ item }}", state: present }  # apt on Debian
    loop: [curl, iptables]
  ```
- **`register` + `until/retries/delay`** — [used here] Capture a task's result,
  and optionally retry until a condition holds (our "wait for node Ready" loop).
- **`changed_when` / `failed_when`** — [used here] Override how Ansible decides a
  task "changed" something or "failed." Essential for making raw `command`/`shell`
  tasks report honestly.
- **`run_once`** — [next] Run a task a single time on one host even though the play
  targets many (e.g., "generate a token once, not per-node").
- **`serial` (rolling updates)** — [next] Process hosts in batches instead of all
  at once — e.g. `serial: 1` to upgrade one worker at a time so the cluster stays
  up. A production-flavored concept.

### C. Reuse & organization

- **Roles** — [used here] The reusable unit (`roles/<name>/…`). A role can contain
  `tasks/`, `handlers/`, `templates/`, `files/`, `defaults/`, `vars/`, `meta/` —
  each auto-discovered by convention. We use just `tasks/` so far.
- **`import_*` vs `include_*`** — [next] Two ways to pull in extra task files/roles.
  `import_` is resolved **statically** at parse time; `include_` is **dynamic** at
  run time (needed when what you include depends on a variable/loop).
- **Handlers + `notify`** — [next] A task that runs **only when notified by a
  change**, batched to the *end* of the play. The canonical "restart the service
  only if its config actually changed":
  ```yaml
  tasks:
    - name: Write k3s config
      ansible.builtin.template: { src: config.yaml.j2, dest: /etc/rancher/k3s/config.yaml }
      notify: Restart k3s
  handlers:
    - name: Restart k3s
      ansible.builtin.systemd: { name: k3s, state: restarted }
  ```
- **Tags** — [next] Label tasks/roles to run a subset:
  `ansible-playbook site.yml --tags tailscale` or `--skip-tags k3s`.
- **Collections & Galaxy** — [next] Collections are installable bundles of extra
  modules/roles (e.g. `kubernetes.core` to talk to the k8s API, `community.general`).
  Declared in a `requirements.yml`, installed with `ansible-galaxy collection install`.
- **FQCN (fully-qualified collection name)** — [used here] The full module name like
  `ansible.builtin.systemd`. `builtin` ships with Ansible; others read as
  `<namespace>.<collection>.<module>`. Using the full name avoids ambiguity.

### D. Variables, data & templating (deeper)

- **Variable precedence** — [next, but important] The same variable can be set in
  ~20 places (role defaults, `group_vars`, `host_vars`, `-e` on the CLI, `set_fact`…)
  and there's a **strict priority order**. Rough rule: *the more specific / later /
  command-line wins*. `-e` (extra-vars) beats almost everything. Know this exists —
  it's the #1 source of "why is my variable not what I set?".
- **`defaults/` vs `vars/` in a role** — [next] `defaults/main.yml` = lowest
  priority (easy to override — put a role's knobs here). `vars/main.yml` = high
  priority (hard to override — put constants here).
- **Gathered facts** — [next] At play start (unless disabled) Ansible collects
  `ansible_facts` about each host — OS, IPs, memory, CPU arch, etc. Reference them
  like `ansible_facts.default_ipv4.address` or `ansible_architecture` (handy for
  your arm64 boards). Toggle with `gather_facts: true/false`.
- **`set_fact`** — [used here] Create a variable at runtime (our join-token). Unlike
  gathered facts, you set these yourself.
- **`hostvars` / `groups`** — [used here] Read any host's variables / list a group's
  members — the cross-host data bridge (workers reading the master's token).
- **Jinja2 templating & filters** — [used here] `{{ ... }}` expressions and pipe
  filters like `| b64decode`, `| trim`, `| default('x')`, `| to_json`. It's a full
  templating language (conditionals, loops) used both in tasks and in `.j2` files.
- **Templates (`.j2` files)** — [next] Render a file with variables filled in and
  copy it to the node (`ansible.builtin.template`). How you'd generate a k3s config
  or a Kubernetes manifest per host.

### E. Safety & error handling

- **Check mode (`--check`) + `--diff`** — [used here] Dry-run: show what *would*
  change without doing it; `--diff` shows the actual file changes. Always your
  first move on a new/edited playbook.
- **Idempotency** — [used here] The property that re-running changes nothing once
  you're in the desired state. The goal of every task. A second run reporting
  "changed" is a bug to hunt.
- **`block` / `rescue` / `always`** — [next] Try/catch/finally for tasks. Group
  tasks in a `block`, handle failures in `rescue`, run cleanup in `always`.
- **`ignore_errors` / `any_errors_fatal`** — [next] Continue past a failed task, or
  conversely abort the *whole play across all hosts* the moment any host fails.
- **`delegate_to` / `local_action`** — [discussed] Run a specific task on a
  *different* host than the play targets — e.g. `delegate_to: localhost` to do
  something on your Arch control node (fetch a file, hit an API) mid-play.

### F. Secrets

- **ansible-vault** — [next] Encrypts a file (or a single value) with a password so
  secrets can be committed to git safely. Workflow:
  ```bash
  ansible-vault create group_vars/all/vault.yml   # make an encrypted file
  ansible-vault edit   group_vars/all/vault.yml   # edit it later
  ansible-playbook site.yml --ask-vault-pass      # decrypt at run time
  ```
  You'll want this the moment we add the Mullvad key / Cloudflare token.

### G. Tooling & quality

- **`ansible.cfg`** — [used here] Project config (inventory path, SSH behaviour,
  output format). Ours lives next to the playbooks so it auto-applies.
- **Static vs dynamic inventory** — [used here: static] `inventory.ini` is a static
  file. **Dynamic inventory** is a script/plugin that generates the host list from a
  live source (a cloud provider's API, Tailscale, etc.) — useful when hosts come and
  go. Overkill for a fixed homelab, good to know exists.
- **`ansible-lint`** — [next] A linter that flags anti-patterns and style issues.
  Run it before committing once the project grows.
- **Molecule** — [next] A framework for *testing* roles in throwaway containers/VMs.
  Serious-project territory; mentioned so the name isn't a mystery later.

> **How to use this list:** don't try to memorize it. The three you'll reach for
> *soon* are **handlers** (restart-on-change), **templates** (generate config), and
> **ansible-vault** (secrets) — all needed the moment you deploy real apps. The rest
> you'll pull in as a specific need appears. §8 sequences them for you.

---

## 8. Growing this (your roadmap)

The project is deliberately shaped so each of these is *additive*, not a rewrite:

1. **Add worker nodes** → add lines under `[workers]` in `inventory.ini`, re-run.
   Play 3 wakes up and joins them. Nothing else changes.
2. **Switch to your real Tailscale networking** → set `k3s_server_args` /
   `k3s_agent_args` in `group_vars/all.yml` to include
   `--flannel-iface=tailscale0 --node-ip=<ts-ip>`. (You'll add a small task to
   discover each node's Tailscale IP into a fact first — good next exercise.)
3. **Deploy cluster apps** (cert-manager, Traefik, the VPN stack) → add a
   `cluster_apps` role that applies your existing `k3s/*.yaml` manifests, and a
   4th play in `site.yml`. This is where templates + vault come in for the secrets.
4. **Move the control plane to new hardware** → change `ansible_host` for
   `homelab-master`. The automation doesn't care what the box is.

Each step teaches one new concept from §7. That's the plan.

---

## 9. Command cheat-sheet

```bash
ansible all -m ping                     # reachability check across the inventory
ansible-playbook site.yml --check       # DRY RUN — show changes, touch nothing
ansible-playbook site.yml --diff        # show file-level diffs of what changed
ansible-playbook site.yml --list-tasks  # print every task, run nothing
ansible-playbook site.yml -v            # verbose (-vvv for very verbose/debug)
ansible-playbook site.yml --ask-become-pass   # prompt for the sudo password
ansible-playbook site.yml --limit master      # only the master host
ansible-inventory --graph               # visualize your groups
```

Golden rule while learning: **`--check` first, then run for real, then re-run to
confirm it's green with zero changes.** If a second run reports "changed", a task
isn't truly idempotent — that's your bug to find.
