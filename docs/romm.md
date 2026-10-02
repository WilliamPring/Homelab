# RomM — ROM library + play in the browser

**RomM** scans your ROM collection, pulls metadata and artwork (IGDB, ScreenScraper, Hasheous…),
and lets you play most retro platforms directly in the browser via EmulatorJS. The emulator
runs **in your browser** (WebAssembly); the pod only serves files and keeps your saves/states.

---

## Architecture

```
https://roms.williampring.ca  (Tailscale)  ·  http://<node-ip>:30808  (LAN)
        │
        ▼
   romm pod  (media ns, pinned to the 32GB worker)
     ├─ Postgres  → 192.168.68.7:5432/romm           (external LXC — the shared Postgres)
     ├─ Valkey    → 192.168.68.103:6379, user romm   (external, same host as Immich/degoog)
     ├─ /romm/library   → NFS 192.168.68.50:/data/roms          ROMs + BIOS
     ├─ /romm/assets    → NFS 192.168.68.50:/data/romm-assets   saves, states, uploads  ← irreplaceable
     └─ /romm/resources → local-path PVC                        covers/screenshots cache ← re-fetchable
```

| Argo app | Path | Deploys |
|---|---|---|
| `romm` | `gitops/romm` | Deployment, NFS PV/PVCs, resources PVC, NodePort Service, Ingress, KSOPS secret |

**Why k3s and not an LXC:** RomM is a stateless web app whose state is a DB + files, and both
already live outside the cluster. Playing is client-side, so the pod does nothing heavy. See the
design principles in the README.

---

## Library layout (file server, `/data/roms`)

RomM's "Structure A": platforms under `roms/`, BIOS under `bios/`.

```
/data/roms/
├─ roms/
│  ├─ gba/      Metroid Fusion (USA).gba
│  ├─ snes/     Chrono Trigger (USA).sfc
│  ├─ n64/      ...
│  ├─ ps/       Final Fantasy VII (USA)/   ← multi-disc games can be a FOLDER of files
│  └─ psp/      ...
└─ bios/
   ├─ gba/      gba_bios.bin
   └─ ps/       scph5501.bin
```

- Platform folder names are RomM's slugs (mostly IGDB slugs): `gba`, `gbc`, `gb`, `snes`, `nes`,
  `n64`, `nds`, `ps`, `ps2`, `psp`, `genesis-slash-megadrive`, `saturn`, `dc`, `arcade`…
  Full list: Settings → Platforms in the UI, or https://docs.romm.app/latest/platforms/supported-platforms/
- A game may be a folder; subfolders `dlc/`, `update/`, `patch/`, `manual/`, `soundtrack/` are
  recognised and shown as tags.
- Browser play needs the platform's BIOS in `bios/<platform>/` for systems that require one
  (PS1, Saturn, GBA for some cores). The UI tells you which files are missing.

```bash
# on the file server, once:
mkdir -p /data/roms/roms /data/roms/bios /data/romm-assets
chown -R 1000:1000 /data/roms /data/romm-assets && chmod -R 775 /data/roms /data/romm-assets
```

---

## First-time setup (do these in order)

### 1. Database on the Postgres LXC (192.168.68.7)
```bash
# copy scripts/postgres-romm-setup.sh into the LXC and run it as root:
sh postgres-romm-setup.sh          # creates db+role `romm`, adds a pg_hba line, prints the PASSWORD
```
RomM runs its own migrations on first start — the DB just needs to exist.

### 2. Redis ACL user on the Valkey host (192.168.68.103)
Same pattern as Immich (`docs/redis.md`): a dedicated user, not the shared one.
```
ACL SETUSER romm on resetpass >ROMM_REDIS_PASSWORD ~* &* +@all
ACL SAVE
```

### 3. Secrets → SOPS (Arch box)
```bash
openssl rand -hex 32                                   # → ROMM_AUTH_SECRET_KEY
$EDITOR gitops/romm/romm-secret.enc.yaml               # fill auth key, DB_PASSWD (step 1), REDIS_PASSWORD (step 2)
sops --encrypt --in-place gitops/romm/romm-secret.enc.yaml
git diff gitops/romm/romm-secret.enc.yaml              # every value must be ENC[AES256_GCM,...]
```
Provider keys are optional. Hasheous and PlayMatch are free and already on. For box art on
retro systems make a free **ScreenScraper** account; for broad metadata make an **IGDB** (Twitch
dev) app. Add them to the secret any time → `sops` edit → push → sync → `rollout restart`.

### 4. DNS + deploy
```
Cloudflare DNS:  roms → A → <master's Tailscale IP>   (grey cloud / DNS only)
```
```bash
git add gitops/romm gitops/apps/romm.yaml scripts/postgres-romm-setup.sh && git commit -m "feat: romm" && git push
sudo k3s kubectl apply -f gitops/apps/romm.yaml       # Argo UI → romm → review → SYNC
sudo k3s kubectl get pods -n media -l app=romm -w     # Running + 1/1 Ready (migrations take ~1 min)
sudo k3s kubectl logs -n media deploy/romm --tail=50  # no DB / Redis connection errors
```

### 5. In the UI
1. Open https://roms.williampring.ca → create the **admin** account (first-run screen).
2. **Scan**: top-right → Scan → *Complete* for the first run. Watch progress in the task bar.
3. Click a game → **Play** → pick a core if asked. Saves/states land in `/data/romm-assets`.
4. Settings → **Platforms**: fix any folder RomM didn't recognise (it suggests slugs).

---

## Day-to-day

- **Adding games:** copy into `/data/roms/roms/<platform>/` → Scan → *Quick* (new files only).
- **Backups that matter:** the Postgres DB (library state, users, play stats) and
  `/data/romm-assets` (saves). `/romm/resources` and the Valkey data are caches.
  ```bash
  # from the Postgres LXC:
  pg_dump -U romm romm > romm-$(date +%F).sql
  ```
- **Upgrading:** bump `rommapp/romm:X.Y.Z` in `gitops/romm/deployment.yaml` (Renovate PRs it).
  RomM migrates the DB on start; `pg_dump` first on major versions.
- **Streaming (server-side emulation):** RomM has an opt-in webstation add-on that renders
  emulators on the server. It wants a GPU, is amd64-only and still marked development. If you ever
  want it, run it on a Proxmox VM/LXC with GPU passthrough — not in k3s. Normal browser play
  does not need it.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Pod CrashLoop, log `password authentication failed` | `DB_PASSWD` doesn't match the LXC → re-run `postgres-romm-setup.sh` and update the secret |
| Log `no pg_hba.conf entry for host` | pg_hba line missing → the script adds it; `SELECT pg_reload_conf()` |
| Log `NOAUTH` / `WRONGPASS` from Redis | ACL user `romm` missing or wrong password (step 2) |
| Pod `Pending` | worker not labelled `immich-node=true`, or NFS mount failed (`kubectl describe pod`) |
| Scan finds 0 games | wrong layout — files must be under `/data/roms/roms/<platform>/`, nothing loose |
| Platform shows as "unknown" | folder name isn't a known slug → rename, or map it in Settings → Platforms |
| Play button greyed / "BIOS missing" | put the BIOS files in `/data/roms/bios/<platform>/` and rescan |
| Game loads slowly / tab crashes | the whole ROM loads into browser memory (PS1 ≈ 700 MB, PSP 1–2 GB). Expected; use a desktop for big ISOs |
| `secret romm-secret not found` on sync | `romm-secret.enc.yaml` still plaintext or Argo can't decrypt → `docs/secrets.md` |

### Handy checks
```bash
sudo k3s kubectl get pods -n media -l app=romm -o wide
sudo k3s kubectl logs -n media deploy/romm -f
sudo k3s kubectl exec -n media deploy/romm -- ls /romm/library/roms /romm/library/bios
curl -s https://roms.williampring.ca/api/heartbeat | head -c 300
```

---

## Quick reference
```
Web:        https://roms.williampring.ca       (LAN: http://192.168.68.21:30808)
ROMs:       192.168.68.50:/data/roms/roms/<platform>/
BIOS:       192.168.68.50:/data/roms/bios/<platform>/
Saves:      192.168.68.50:/data/romm-assets/
DB:         192.168.68.7:5432/romm   (pg_dump -U romm romm)
Secrets:    sops gitops/romm/romm-secret.enc.yaml
```
