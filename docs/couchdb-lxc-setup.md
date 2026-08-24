# CouchDB LXC — Obsidian LiveSync (self-hosted notes sync)

CouchDB in its own LXC (like Postgres), reachable at `https://couchdb.williampring.ca`
over Tailscale, so the Obsidian LiveSync plugin (Mac + iPhone) can sync through it.

Pattern: **CouchDB** (localhost) + **nginx** (TLS proxy) + **acme.sh** (Let's Encrypt via
Cloudflare DNS-01, like Pi-hole) + **Tailscale** (so the iPhone reaches it anywhere).

---

## 1. Create the LXC (on pve-a — has the free RAM)
```
Hostname:  couchdb
Template:  debian-12-standard
Disk:      10 GB · local-lvm
CPU:       1 core
Memory:    1024 MB · swap 512
Network:   vmbr0 · Static 192.168.68.8/24 · gw 192.168.68.1
Unprivileged ✅ · Start at boot ✅
```
(Ping `192.168.68.8` first — free?)

### Enable TUN for Tailscale (on the Proxmox HOST)
Edit `/etc/pve/lxc/<CTID>.conf`, add:
```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```
Then `pct restart <CTID>`.

---

## 2. Install CouchDB (in the container console)
```bash
apt update && apt install -y curl gnupg apt-transport-https lsb-release
curl -fsSL https://couchdb.apache.org/repo/keys.asc \
  | gpg --dearmor -o /usr/share/keyrings/couchdb-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/couchdb-archive-keyring.gpg] https://apache.jfrog.io/artifactory/couchdb-deb/ $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/couchdb.list
apt update && apt install -y couchdb
```
At the install prompts:
- Configuration type: **standalone**
- Bind interface address: **127.0.0.1**  ← localhost only; nginx will front it
- Admin username: `admin` · set a strong **password** (remember it)

---

## 3. CouchDB config — CORS + LiveSync settings (REQUIRED)
Without these the Obsidian app can't connect. Create `/opt/couchdb/etc/local.d/10-livesync.ini`:
```ini
[couchdb]
single_node = true
max_document_size = 50000000

[chttpd]
require_valid_user = true
max_http_request_size = 4294967296

[chttpd_auth]
require_valid_user = true

[httpd]
enable_cors = true

[cors]
credentials = true
origins = app://obsidian.md,capacitor://localhost,http://localhost
headers = accept, authorization, content-type, origin, referer
methods = GET, PUT, POST, HEAD, DELETE
```
```bash
systemctl restart couchdb
curl http://admin:PASSWORD@127.0.0.1:5984/         # sanity: returns CouchDB welcome JSON
```

---

## 4. TLS — nginx reverse proxy + acme.sh cert (Cloudflare DNS-01)
```bash
apt install -y nginx
mkdir -p /etc/nginx/certs

# acme.sh cert (same as Pi-hole)
curl https://get.acme.sh | sh -s email=william.pring@telus.com
read -rs CF_Token; export CF_Token           # paste your Cloudflare "Edit zone DNS" token
~/.acme.sh/acme.sh --issue --dns dns_cf -d couchdb.williampring.ca
~/.acme.sh/acme.sh --install-cert -d couchdb.williampring.ca \
  --key-file  /etc/nginx/certs/couchdb.key \
  --fullchain-file /etc/nginx/certs/couchdb.crt \
  --reloadcmd "systemctl reload nginx"
```
`/etc/nginx/sites-available/couchdb`:
```nginx
server {
    listen 443 ssl;
    server_name couchdb.williampring.ca;
    ssl_certificate     /etc/nginx/certs/couchdb.crt;
    ssl_certificate_key /etc/nginx/certs/couchdb.key;
    location / {
        proxy_pass http://127.0.0.1:5984;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffering off;
    }
}
```
```bash
ln -s /etc/nginx/sites-available/couchdb /etc/nginx/sites-enabled/couchdb
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
```

---

## 5. Tailscale (so the iPhone reaches it anywhere)
```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
tailscale ip -4        # note the 100.x IP
```

## 6. Cloudflare DNS
```
Cloudflare → williampring.ca → DNS → Add A record:
  couchdb → A → <the CouchDB LXC's 100.x Tailscale IP>   (grey cloud / DNS only)
```

---

## 7. Create the vault database
```bash
curl -X PUT https://admin:PASSWORD@couchdb.williampring.ca/obsidiannotes
```

## 8. Obsidian — Self-hosted LiveSync plugin
On the **Mac** first: Community plugins → install **Self-hosted LiveSync** → Setup:
```
URI:       https://couchdb.williampring.ca
Username:  admin
Password:  <couchdb password>
Database:  obsidiannotes
E2E passphrase: <set one — end-to-end encrypts your notes>
```
→ Test connection → enable LiveSync.
On the **iPhone**: same plugin → use the desktop's **"Copy setup URI"** to import settings.

---

## Notes
- **Data durability:** each device holds a full copy of the vault, so if the CouchDB
  LXC dies you just re-sync from a device. Still, it survives cluster rebuilds (it's
  outside k3s) — consistent with the Postgres-in-LXC choice.
- **Housekeeping:** LiveSync accumulates history; run CouchDB compaction occasionally.
- **acme.sh auto-renews** the cert (cron) + reloads nginx.
