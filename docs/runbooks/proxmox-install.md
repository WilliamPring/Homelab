# Proxmox VE Install — pve-a (16GB box)

Screen-by-screen install for the homelab Proxmox hosts, with the **real network
values** for this LAN baked in. Written after a first attempt landed on a phantom
`192.168.100.x` subnet — the network screen is the one that matters.

## Real network facts (this LAN)
```
Subnet   : 192.168.68.0/24
Gateway  : 192.168.68.1        (the router)
Arch box : 192.168.68.74       (control node — do NOT reuse this IP)
Ignore   : 192.168.122.x       (libvirt VM-sandbox NAT on Arch, not the LAN)
```

## Host plan
| Host | FQDN | Static IP |
|------|------|-----------|
| 16GB box (this one) | `pve-a.home.arpa` | `192.168.68.10/24` |
| 32GB box (later)    | `pve-b.home.arpa` | `192.168.68.11/24` |

> Pick IPs OUTSIDE the router's DHCP pool if you can (check the router). If `.10`
> is ever taken, use a high one like `.240`.

---

## Make the USB (on Arch)
```bash
lsblk                                   # identify the USB — confirm by SIZE
sudo umount /dev/sdX*                    # unmount if auto-mounted
sudo dd if=~/Downloads/proxmox-ve_*.iso of=/dev/sdX bs=4M status=progress oflag=sync
sync
```
⚠️ `of=/dev/sdX` = the whole USB device (not a partition, not your system disk).

---

## Install screens

1. **Boot from USB** → `Install Proxmox VE (Graphical)`
2. **EULA** → *I agree*
3. **Target Disk** → pick the SSD → **Options → Filesystem: `ext4`**
   > ext4, NOT ZFS. On a 16GB box ZFS's ARC cache silently eats ~half the RAM.
4. **Location & Time Zone** → Country, `America/Toronto`, keyboard
5. **Admin Password** → root password (+ any email)
6. **Management Network** ⚠️ THE screen that broke last time — enter EXACTLY:
   | Field | Value |
   |-------|-------|
   | Hostname (FQDN) | `pve-a.home.arpa` |
   | IP Address (CIDR) | `192.168.68.10/24` |
   | Gateway | `192.168.68.1` |
   | DNS Server | `192.168.68.1` (or `1.1.1.1`) |
7. **Summary** → verify IP + disk → **Install** → ~10 min → reboot → **pull the USB**

---

## After install
1. Console prints: `https://192.168.68.10:8006`
2. From Arch (Firefox): open that URL → accept the self-signed cert warning
3. Login: user `root` · your password · realm **Linux PAM standard authentication**
4. Dismiss the **"No valid subscription"** popup (it's free)
5. Unplug the monitor/keyboard — everything's web-based now

## Sanity check (on the console, if anything's off)
```bash
ip a                        # vmbr0 must show 192.168.68.10
ping -c3 192.168.68.1       # gateway must REPLY (not "Destination Host Unreachable")
ping -c3 8.8.8.8            # internet
```
If `vmbr0` shows the wrong subnet, the network screen was mis-entered — fix
`/etc/network/interfaces` (address + gateway) + `/etc/hosts` (the FQDN line),
then `reboot`.

---

## Next: free "no-subscription" repo (so updates work)
```bash
# disable the enterprise repos (they 401 without a subscription):
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list 2>/dev/null
# add the free repo:
echo "deb http://download.proxmox.com/debian/pve $(. /etc/os-release; echo $VERSION_CODENAME) pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-no-subscription.list
apt update && apt -y full-upgrade
```

## Then: create the k3s VM
- Upload a Debian ISO (Datacenter → local → ISO Images → Upload)
- Create VM: **~13GB RAM / 4 vCPU / 60–80GB disk** (single-node for now)
- Install Debian → point the Ansible inventory at its IP → `ansible-playbook site.yml`
