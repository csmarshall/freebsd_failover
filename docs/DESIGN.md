# router WAN failover: PRIMARY fiber (ixl0) → BACKUP 5G (ix0), plus the VPN provider SSH backdoor

Status: APPROVED 2026-10-29. P0–P3 applied and verified (2026-10-30; P3 failover is live but not yet exercised, see P6). P4–P6 to do; P5 blocked on the VPN provider details.

## Naming convention

The two uplinks are **PRIMARY** (primary) and **BACKUP** (backup) everywhere: prose uses `PRIMARY`/`BACKUP`, identifiers use lowercase (`pri_if`, `bak_if`, `/var/db/pri_router`, `/var/db/bak_router`, dpinger `pri_cf`/`bak_cf`, `wan_state` values `pri`/`bak`, `gateway-pri.localhost`/`gateway-bak.localhost`). Any remaining "the old ISP" or "the 5G carrier"/"carrier" identifiers are renamed to PRIMARY/BACKUP.

## Target design

- **PRIMARY** = `ixl0`, the fiber ISP fiber, public 203.0.113.32/23, gw 203.0.113.1, DHCPv6-PD /60.
- **BACKUP** = `ix0`, 5G CPE 5G (the 5G carrier-based SIM), 5G CPE in NAT mode on 192.168.12.0/24 (gw 192.168.12.1), carrier CGNAT behind it. Unlimited data.
- **wg0** = WireGuard to one the VPN provider server, always up, endpoint pinned out BACKUP. the VPN provider forwards port 40222 → router, pf redirects it to sshd. Out-of-band SSH works whether PRIMARY is up or down.

Routing tables (FIBs):

| FIB | Purpose | Default route |
|---|---|---|
| 0 | real traffic | PRIMARY normally, BACKUP when failed over |
| 1 | PRIMARY probe only | 203.0.113.1 via ixl0, always |
| 2 | BACKUP probe only | 192.168.12.1 via ix0, always |

Principles:

1. **pf is never flushed or reloaded on failover.** Both uplinks have static NAT rules to pf tables that the dhclient hooks keep at the current lease address (`nat on $pri_if … -> <pri_addr>`, `nat on $bak_if … -> <bak_addr>`; not `(if:0)`, which after boot is the rc.conf management alias); a packet is NATed by whichever interface the route sends it out. Failover = `route change default` in FIB 0 + kill stale LAN states. fail2ban, `ip6_gua_*`, miniupnpd tables all survive.
2. **Each WAN is probed through its own FIB** (`setfib 1 dpinger …`, `setfib 2 dpinger …`) to off-net targets (1.1.1.1, 8.8.8.8), not the PRIMARY first hop. PRIMARY keeps being probed while traffic is on BACKUP, which is what makes failback work. No host routes leak into FIB 0.
3. **Only the failover script decides FIB 0's default.** dhclient hooks for both WANs only maintain their own FIB (1/2) and record their gateway in `/var/db/{pri,bak}_router`; the PRIMARY hook touches FIB 0 only when state is `pri`.
4. **IPv6 keeps working on BACKUP** via a static NAT66 rule on ix0 (LAN the fiber ISP GUAs and ULAs → ix0's global v6). Only matches traffic that actually leaves ix0, so it can sit in the ruleset permanently. Exact form depends on what 5G CPE hands out (P1 discovery).

## ⚠ Do NOT plug the 5G CPE into ix0 until P1 is applied

With today's config, link-up on ix0 will: (a) start dhclient with the broken legacy ix0 hooks, which add stale 192.168.5.x aliases/routes and collide with the static 192.168.12.2/24 alias; (b) because `net.inet6.ip6.rfc6204w3=1` is global and ix0 has `accept_rtadv`, the 5G CPE's RA would install a **second IPv6 default router in FIB 0**, sending LAN v6 out ix0 un-NATed → intermittent IPv6 breakage for the whole house.

## Phases (each is a script the admin runs; each takes a timestamped backup first and has a rollback script)

### P0 — Backup + cleanup (no behaviour change while ix0 is unplugged)
- Tarball `/etc/rc.conf /etc/pf /etc/dhclient* /etc/dhclient-scripts /etc/dpinger /etc/rc.local /etc/sysctl.conf /boot/loader.conf` to `/root/failover-backups/<ts>-<phase>.tgz` (`scripts/rollback.sh` restores one).
- Stop the current (non-functional) dpinger; comment out its `rc.local` line.
- Remove legacy ix0 cruft: ix0 alias 192.168.12.2, `route_ltemodem`, 192.168.5.x alias/route in hook, `reject 192.168.100.1`.
- Archive `failover_oldisp`, `startup_script`, `start_dpinger_backup.sh`, `start_dpinger.sh`, `failover` to `/etc/dpinger/attic/`.
- Disable the old dpinger line in `rc.local` (its `2>&1 >>` redirect order was also wrong).
- ix0 `media autoselect` (old forced `media 10Gbase-T` would give no link to a 1G/2.5G 5G CPE port).
- `ifconfig_ix0_ipv6="inet6 accept_rtadv no_radr"`: take an address, never a default router, on ix0.

### P1 — FIBs + dhclient hooks, then plug in and discover
- `net.fibs=3` in loader.conf and at runtime (`sysctl net.fibs=3`; hopefully runtime increase works on 15.1, the script checks and reports).
- `/etc/dhclient-enter-hooks` **sources** (not executes) `/etc/dhclient-scripts/dhclient-${interface}-enter-hooks`, so function overrides work.
- `dhclient-ix0-enter-hooks` (BACKUP): override `add_new_routes`/`delete_old_routes`/`is_default_interface` → write default only into FIB 2 (`route -n add -fib 2 …`, with `-iface` gateway route), write `/var/db/bak_router`, `/var/db/bak_ip`; never touch FIB 0.
- `dhclient-ixl0-enter-hooks` (PRIMARY): same for FIB 1; pass through to stock FIB 0 behaviour only when `/var/run/wan_state` is `pri` (or absent).
- Both exit hooks: if IP changed, restart that WAN's dpinger.
- **Then plug in 5G CPE** and run `p1_discover_bak.sh` (read-only): lease contents, FIB 2 route, `ping` via `setfib 2`, RA contents (`ndp -p`, `ndp -r`, rtsol -d), whether 5G CPE offers DHCPv6-PD, path MTU over 5G. Results decide P4's exact NAT66 form.

### P2 — pf
- Rename macros: `pri_if="ixl0"`, `bak_if="ix0"`, `bak_modem="192.168.12.1"` (drop `was`/`ext_if0/1` naming; the old ISP → PRIMARY everywhere).
- Replace `nat on egress` with two static NAT rules to tables `<pri_addr>`/`<bak_addr>` (loaded from `/var/db/{pri,bak}_ip`, updated by wan-lib.sh on every lease; `(if:0)` is unsafe because after boot the rc.conf mgmt alias is the first address); `egress` group stays permanently on ixl0 (no more moving it). `rdr`/`pass in` for game ports and `wan_in_tcp` bound to `$pri_if` explicitly.
- BACKUP modem admin NAT `-> ($bak_if:0)`; drop all inbound passes on `$bak_if` (CGNAT: nothing can arrive anyway).
- (Moved to P5, when wg0 exists:) wg0: `rdr on wg0 proto tcp to (wg0) port 40222 -> 127.0.0.1 port 22`, `pass in on wg0 … reply-to (wg0)` with the same overload/fail2ban limits as WAN ssh; block everything else in on wg0; no NAT out wg0.
- ICMPv6 + DHCPv6 client rules extended to `$bak_if`.
- **LAN IPv6 isolation invariant (the admin, 2026-10-29): nothing from BACKUP's IPv6 (3fff:b0::/32 GUA, fd00:db8:1::/48 ULA, its RDNSS) may ever reach LAN devices.** Passing ICMPv6 ND/RA in on `$bak_if` gives router itself SLAAC addresses on ix0 only. LAN clients keep PRIMARY PD + `fd00:1234:5678::/48` and reach BACKUP via NAT66. P2 apply script verifies: `radvd.conf` contains only `2001:db8:` and `fd00:1234:5678:` prefixes and `127.0.0.1`/router RDNSS; no ix0 bridge; no FIB 0 v6 default via ix0.
- Validate with `pfctl -nvf` before load; load once with `pfctl -f` (not `-F all`).

### P3 — dpinger + failover controller
- Four dpinger instances, each with `-u` status socket: `pri_cf` / `pri_gg` (FIB 1 → 1.1.1.1 / 8.8.8.8), `bak_cf` / `bak_gg` (FIB 2). Alert command for all = `/usr/local/sbin/wan-failover evaluate`.
- `wan-failover evaluate` reads all four sockets and decides:
  - PRIMARY **down** = both PRIMARY probes in alarm. Fail over only if at least one BACKUP probe is healthy.
  - PRIMARY **up** = both PRIMARY probes clear for `FAILBACK_HOLD_S` (default 120s, single named constant) → fail back.
  - Lockfile + `MIN_TRANSITION_S` anti-flap kept from the old script; correct arg parsing.
- Transition actions (PRIMARY→BACKUP, reverse is symmetric): `route change default` (v4) in FIB 0; v6: `ifconfig ixl0 inet6 no_radr` + replace v6 default with BACKUP's router (failback: drop it, `-no_radr`, rtsol ixl0); kill LAN-sourced states; restart miniupnpd with `ext_ifname` swapped; `unbound-control flush_infra all`; Pushover + blink(1) LED + `/var/log/network_failover.log`.
- Boot: an rc.d service `wan_failover` (replaces rc.local lines) starts the dpingers and runs one `evaluate` after 60s, so booting with PRIMARY down still ends up on BACKUP. Plus a cron `evaluate` every minute as a safety net.

### P4 — IPv6 over BACKUP
- Per P1 discovery. Expected (BACKUP typical): 5G CPE gives ix0 a SLAAC /64, no PD → `nat on $bak_if inet6 from { <ip6_gua_all>, $ula_all } to any -> ($bak_if:0)` with a guard that `:0` resolves to the global, not link-local, address. If 5G CPE does offer PD, prefer NPTv6-style `binat` per /64.

### P5 — the VPN provider WireGuard
- the admin: in the VPN provider client area, generate a WireGuard config for one specific server, forward port **40222** (local port 40222), set the DDNS name. Drop the config at `/root/vpn-wg.conf`.
- Script: strip `Address`/`DNS`/`AllowedIPs` wg-quick-isms → `/usr/local/etc/wireguard/wg0.conf`, rc.conf `cloned_interfaces="wg0"`, `ifconfig_wg0="inet <vpn tunnel ip>/32"`, rc hook `wg setconf wg0 …`. AllowedIPs stays 0.0.0.0/0 inside wg but **no routes are installed** from it.
- Endpoint pinning: FIB 0 host route `<vpn server ip> 192.168.12.1`, maintained by the BACKUP exit hook (and re-checked by `evaluate`). PersistentKeepalive 25 to hold the CGNAT mapping.

### P6 — Test plan (with the admin at the box, console on IPMI/serial as a lifeline)
1. Steady state: `setfib 1 ping 1.1.1.1`, `setfib 2 ping 1.1.1.1`, LAN v4+v6 browsing, `ssh -p 40222 <vpn ddns>` from phone off-wifi.
2. Pull fiber at the ONT → confirm failover within ~20s, LAN v4 + v6 work, log + Pushover fire, SSH via 40222 still works.
3. Restore fiber → failback after `FAILBACK_HOLD_S`, IPv6 PD addresses route again.
4. Flap test: pull/restore fiber 3× in 60s → at most one transition each way.
5. Reboot with fiber unplugged → comes up on BACKUP.
6. Pull BACKUP while on PRIMARY → no failover, alert only.

Passing these proves the paths work on the day; it does not prove behaviour under failure modes we did not simulate (e.g. PRIMARY up but upstream blackholing only some prefixes, carrier IPv6 changes).

## Follow-ups (after P3)
- **Smokeping per-uplink probes** (the admin asked 2026-10-30): graph PRIMARY and BACKUP side by side, whichever is carrying traffic. Two FPing probes whose `binary` is a small wrapper (`exec setfib 1 /usr/local/sbin/fping "$@"` / `setfib 2`); unprivileged setfib works on router. Targets must be IP literals (1.1.1.1, 8.8.8.8, ...) because FIB 1/2 have no lo0 route, so names don't resolve inside them. Keep fping's payload non-zero: 0-byte echoes are dropped 33–75% by BACKUP's NAT64. Do it with the smokeping rename chore (gateway-carrier/gateway-oldisp targets → PRIMARY/BACKUP).
- **Alert when BACKUP dies while on PRIMARY** (P6 step 6 expects an alert): the controller currently only logs the health; add a rate-limited Pushover on BACKUP down/up transitions.

## Parked
- **DNS** (the admin: "come back to me on the DNS"): Route53 / `update-route53.sh` and `first_hop_entry.sh` behaviour on failover. Not wired into P3 until discussed.
