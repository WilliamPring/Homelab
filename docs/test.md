Absolutely. Copy everything below into a file named:

tailscale-mullvad-proxmox-exit-node.md
# Tailscale → Mullvad Exit Node on Proxmox LXC


## Goal


Build this traffic path:


```text
iPhone
  │
  │ Tailscale
  ▼
Proxmox LXC: exit-node
  │
  │ Mullvad WireGuard
  ▼
Mullvad VPN
  │
  ▼
Internet

The LXC is both a Tailscale exit node and a Mullvad WireGuard client.

1. Current interfaces

The container has these relevant interfaces:

eth0       192.168.68.100/24   normal LAN interface
tailscale0 100.100.232.125/32  Tailscale interface
mullvad    10.66.174.179/32    Mullvad WireGuard interface

The iPhone's Tailscale address is:

100.78.220.105

Important: there is no wg0 interface.

The Mullvad WireGuard interface is named:

mullvad

because the configuration is named:

/etc/wireguard/mullvad.conf
2. Mullvad WireGuard

Mullvad was brought up with:

wg-quick up mullvad

Initially wg-quick failed because resolvconf was missing:

resolvconf: command not found

After resolving that issue, the Mullvad interface came up successfully.

Verify with:

ip a show mullvad
wg show mullvad

A connectivity test succeeded:

ping -I mullvad 8.8.8.8

Therefore the container itself can reach the Internet through Mullvad.

Mullvad routing

Mullvad's WireGuard configuration already created policy routing using table 51820 and fwmark 0xca6c.

Relevant routing rule:

32765: not from all fwmark 0xca6c lookup 51820

Relevant route:

default dev mullvad table 51820

Do not replace this with a new competing Mullvad routing table unless there is a specific reason.

3. Tailscale

Tailscale was installed and tailscaled was started.

The Tailscale interface is:

tailscale0

The exit node's Tailscale address is:

100.100.232.125

The iPhone is:

100.78.220.105

Tailscale reports:

100.100.232.125  exit-node  ...  linux  idle; offers exit node

This means the server is successfully advertising itself as a Tailscale exit node.

4. IP forwarding

Linux must be able to route packets between interfaces.

IPv4 forwarding was enabled with:

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-tailscale-mullvad.conf
sysctl -p /etc/sysctl.d/99-tailscale-mullvad.conf

Verify:

sysctl net.ipv4.ip_forward

Expected:

net.ipv4.ip_forward = 1

This is correct.

The setting is persistent because it is stored in:

/etc/sysctl.d/99-tailscale-mullvad.conf
5. Proxmox / TUN

Because exit-node is a Proxmox LXC, /dev/net/tun may be required for Tailscale.

However, the presence of:

tailscale0

proves that Tailscale successfully created its tunnel in the current setup.

Therefore, TUN is not currently the problem.

6. The routing test

A plain test:

ip route get 8.8.8.8 from 100.78.220.105

returned:

RTNETLINK answers: Network is unreachable

That wasn't a useful representation of a packet arriving from the iPhone because 100.78.220.105 is the iPhone's Tailscale address, not an address assigned locally to the LXC.

The correct test included the incoming interface:

ip route get 8.8.8.8 from 100.78.220.105 iif tailscale0

Result:

8.8.8.8 from 100.78.220.105 dev mullvad table 51820
    cache iif tailscale0
What this proves

Linux sees traffic:

source:      100.78.220.105
incoming:    tailscale0
destination: 8.8.8.8

and decides:

send it through mullvad
using routing table 51820

Therefore the Tailscale → Mullvad routing path is correct.

7. Unnecessary routing table 200

During troubleshooting, /etc/iproute2/rt_tables did not exist.

We created it and added:

200 mullvad

Then added:

ip route add default dev mullvad table mullvad

However, we later discovered that Mullvad already uses:

51820

Therefore table 200 is unnecessary.

To remove the custom entry:

sed -i '/^[[:space:]]*200[[:space:]]\+mullvad[[:space:]]*$/d' /etc/iproute2/rt_tables

If the custom table still contains a route:

ip route del default dev mullvad table 200 2>/dev/null || true

The real Mullvad routing table is:

51820
8. Current architecture
                         TAILSCALE
                    ┌─────────────────┐
                    │                 │
                 iPhone              exit-node
             100.78.220.105      100.100.232.125
                    │                 │
                    └──── tailscale ─┘
                                      │
                                      │ tailscale0
                                      ▼
                              ┌───────────────┐
                              │ Linux routing │
                              └───────┬───────┘
                                      │
                                      │ table 51820
                                      ▼
                              ┌───────────────┐
                              │    mullvad    │
                              │   WireGuard   │
                              └───────┬───────┘
                                      │
                                      ▼
                                  Mullvad VPN
                                      │
                                      ▼
                                   Internet
9. What is confirmed
Mullvad tunnel

Confirmed working:

ping -I mullvad 8.8.8.8
Tailscale

Confirmed working.

Interface:

tailscale0

Address:

100.100.232.125
iPhone connection

The iPhone appears as:

100.78.220.105
Exit node

Tailscale reports:

idle; offers exit node
IPv4 forwarding

Enabled:

net.ipv4.ip_forward = 1
Tailscale → Mullvad routing

Confirmed with:

ip route get 8.8.8.8 from 100.78.220.105 iif tailscale0

Result:

8.8.8.8 from 100.78.220.105 dev mullvad table 51820
10. What still needs final verification

Routing is confirmed.

However, complete operation also requires forwarding/firewall/NAT behavior so return traffic can reach the iPhone.

Inspect the firewall/NAT rules:

nft list ruleset

Check forwarding:

sysctl net.ipv4.ip_forward

Expected:

net.ipv4.ip_forward = 1
11. End-to-end iPhone test

On the iPhone:

Open Tailscale.
Select exit-node as the Exit Node.
Open Safari.
Check the public IP.

The public IP should be the Mullvad exit IP rather than the iPhone's normal cellular/Wi-Fi public IP.

A useful server-side test is:

wg show mullvad

Run it before and after browsing from the iPhone.

The transfer counters should increase if traffic is passing through the Mullvad tunnel.

For a live view:

watch -n 1 'wg show mullvad'
12. Useful diagnostic commands
Interfaces
ip a
ip addr show tailscale0
ip addr show mullvad
Tailscale
tailscale status
tailscale ip
Mullvad WireGuard
wg show mullvad
Routing
ip route
ip rule
ip route show table main
ip route show table 51820
ip route show table all
Test Tailscale-client routing
ip route get 8.8.8.8 from 100.78.220.105 iif tailscale0

Expected:

8.8.8.8 from 100.78.220.105 dev mullvad table 51820
Firewall/NAT
nft list ruleset
Forwarding
sysctl net.ipv4.ip_forward
13. Important warnings

Do not blindly add additional default routes or policy-routing tables.

Mullvad already has its own WireGuard policy routing.

Do not use:

wg0

in commands for this configuration.

The interface is:

mullvad

Do not remove the Mullvad fwmark/routing rules:

fwmark 0xca6c
table 51820

unless intentionally redesigning the setup.

Before changing NAT/firewall rules, save or inspect:

nft list ruleset

so existing Mullvad rules are understood.

14. Final target

The finished system should behave like:

                    ┌──────────────┐
                    │    iPhone    │
                    │100.78.220.105│
                    └──────┬───────┘
                           │
                       Tailscale
                           │
                           ▼
                  ┌─────────────────┐
                  │    exit-node    │
                  │ 192.168.68.100  │
                  │                 │
                  │   tailscale0   │
                  │       ↓         │
                  │    routing      │
                  │       ↓         │
                  │     mullvad     │
                  └────────┬────────┘
                           │
                       WireGuard
                           │
                           ▼
                    ┌─────────────┐
                    │   Mullvad   │
                    └──────┬──────┘
                           │
                           ▼
                       Internet

The key success criterion is:

When the iPhone selects exit-node as its Tailscale exit node, its public Internet IP should be the Mullvad exit IP.

Current status
Component	Status
Proxmox LXC	Working
Mullvad WireGuard	Working
mullvad interface	Working
Tailscale	Working
tailscale0	Working
iPhone connected	Working
Tailscale exit-node advertisement	Working
IPv4 forwarding	Enabled
Tailscale → Mullvad routing	Confirmed
NAT/firewall	Needs final verification
iPhone Internet via Mullvad	Needs end-to-end verification
Quick recovery / verification checklist

If you come back to this setup later, run:

ip a

You should see:

eth0
mullvad
tailscale0

Then:

tailscale status

You should see:

offers exit node

Then:

wg show mullvad

You should see a recent handshake.

Then:

sysctl net.ipv4.ip_forward

Expected:

net.ipv4.ip_forward = 1

Then:

ip route show table 51820

Expected:

default dev mullvad

Finally:

ip route get 8.8.8.8 from 100.78.220.105 iif tailscale0

Expected:

8.8.8.8 from 100.78.220.105 dev mullvad table 51820

If all of those look correct, the remaining thing to investigate is NAT/firewall behavior.