# freebsd_failover

Dual-WAN failover for a FreeBSD 15 router with pf: a fiber primary and a 5G backup, switched by a small controller fed by four `dpinger` probes. Built and run on a real home router; human-directed and AI-assisted, with every change reviewed and tested on the box.

All addresses in this repo are documentation placeholders (RFC 5737 IPv4, `2001:db8::/32` IPv6, `00:00:5e:00:53:xx` MACs), and ISP, carrier, vendor, VPN-provider names and forwarded ports are generic (`PRIMARY`/`pri` = the fiber uplink, `BACKUP`/`bak` = the 5G one). Substitute your own; `docs/DESIGN.md` explains each one. The repo is a generated export of a private working tree; the export tool itself stays private (it needs the private substitution map).

## How it works

| routing table (FIB) | purpose | default route |
|---|---|---|
| 0 | real traffic | primary normally, backup when failed over |
| 1 | primary probe table | primary's gateway, always |
| 2 | backup probe table | backup's gateway, always |

- **Each uplink is probed through its own FIB** (`setfib 1|2 dpinger …` to off-net targets), so the primary keeps being measured while traffic is on the backup; that is what makes failback safe.
- **Only the controller (`router/usr/local/sbin/wan-failover`) decides FIB 0's default.** The dhclient hooks (`router/etc/dhclient-scripts/`) keep each uplink's own FIB current, record its address, and touch FIB 0 only when `/var/run/wan_state` says that uplink is active.
- **pf is never flushed or reloaded on failover.** Each uplink has a static NAT rule to a pf table (`<pri_addr>`, `<bak_addr>`) that the hooks keep at the current lease address, so whichever interface the route picks NATs correctly. (Not `(if:0)`: a management alias configured in rc.conf becomes the interface's first address after boot.)
- **Decision rules:** a probe is down at ≥ 40 % loss and clear at ≤ 10 %. Fail over when both primary probes are down and the backup is at least partly up; fail back after the primary has been clear for 120 s (or at once if the backup dies). Anti-flap, startup grace, `lockf` serialisation, a cron safety net, and a reconcile of FIB 0's default every run.
- **FIB 0 holds exactly one default route, and the controller checks.** FreeBSD 13+ ships with `net.route.multipath=1`, where `route add default <gw>` beside a default with another gateway does not fail: it builds an equal-weight group and splits traffic across both uplinks. The controller adds the wanted route, deletes every other path by gateway and reads the table back with `netstat` (`route get` shows only the first path); the dhclient hooks do the same after a lease event on the active uplink. This was found the hard way: the first real failover left FIB 0 load-balancing across both uplinks.
- **Transition alerts go out over IPv4 only, with time limits, and a failed send is logged** (`router/usr/local/libexec/wan-notify`). While the primary is down the router's IPv6 default still points at it, so a client that tries IPv6 first hangs.
- **The router's own IPv6 source address is pinned by policy** (`router/etc/ip6addrctl.conf`). The backup interface autoconfigures a global address even with `no_radr`; without a policy the kernel can pick it for traffic that leaves the primary, which the primary ISP drops.
- The backup in this build is a 5G carrier reached through a 5G CPE: IPv6-only to the SIM with 464XLAT, so IPv4 is CGNAT/NAT64 and nothing inbound is possible. Two findings worth knowing if you have a similar link: the 5G carrier's NAT64 drops **zero-byte** ICMP echoes (dpinger's default) and drops echo to some networks entirely, so the probes send a 16-byte payload to targets that answer.

## Layout

- `router/` — files installed on the router (paths mirror `/`): dhclient hooks and shared `wan-lib.sh`, `set_gateway_entries.sh` (atomic `/etc/hosts` update for the gateway names smokeping uses), `pf.conf`, the controller, its rc.d script and cron entry, the `wan-notify` sender, the IPv6 address-selection policy, a newsyslog entry for the event log, smokeping helper wrappers.
- `scripts/` — the phase installers (P0 cleanup, P1 FIBs + hooks, P2 pf, P3 controller), each with a dry run that touches nothing, a timestamped backup and verification; `p3_fixes.sh` (the fixes from the first real failover: single default route, notifications, IPv6 source selection, atomic hosts update, log rotation); `rollback.sh`; `p3_panic.sh` (stop the controller and force the primary, independent of the controller); `smokeping_fixes.sh` (patch for smokeping 2.9's rrdtool version check, plus log rotation); discovery/diagnostic scripts; `leak_scan.py` (the leak scanner CI runs, with `--self-test`).
- `tests/` — `test_hooks.sh` (runs the real `/sbin/dhclient-script` functions with our hooks against stubs), `test_failover.sh` (decision table, end-to-end dry runs, and a mutation pass: deliberately broken copies of the controller must fail the suite), `test_radvd_detector.sh` (runs P2's LAN IPv6 leak detector on its own), `test_fixes.sh` (one default route in every starting state, notification failure handling, the sender; with its own mutation pass), `test_gateway_entries.sh` (the hosts update against a scratch file) and `test_route_live.sh` (root only, not run in CI: the route logic against the real routing table on a scratch TEST-NET-2 prefix, because the unprivileged suites can only check which `route` commands the controller prints, not what the kernel does with them).
- `examples/smokeping-uplinks.conf` — probes that graph each uplink through its own FIB, and a TraceroutePing target for a carrier first hop that ignores echo (install the wrappers from `router/usr/local/libexec/` and merge the excerpt into your config by hand).
- `docs/DESIGN.md` — the full design and phase plan.
- `legacy/` — the 2020 single-script version this replaces.

## Install order

Run each phase's dry run first (`sudo ./scripts/pN_….sh`), read the diff, then `--apply`:

1. `p0_cleanup.sh` — backups, remove old failover cruft.
2. `p1_fibs_hooks.sh` — `net.fibs=3`, dhclient hooks, management aliases.
3. `p2_pf.sh` — pf ruleset (auto-reverts if outbound NAT or internet breaks).
4. `p3_failover.sh` — controller, rc.d service, cron.
5. `p3_fixes.sh` — the post-failover fixes; runs `test_route_live.sh` first and installs nothing if it fails.

Panic button: `sudo ./scripts/p3_panic.sh` stops and disables the controller and puts FIB 0 back on the primary.

## Status

Steady state verified on the router. One real failover and failback has happened (a brief primary loss, not a planned test); it exposed the two-default-route fault and the lost alerts described above, and `p3_fixes.sh` is the result. The fixes are verified on the box in steady state and by the live route test, but no failover has run on the fixed code yet, and the pulled-fiber test plan (`docs/DESIGN.md`, P6) is still to do. Hopefully nothing else surprising turns up there, but until it has run it is unproven.

The controller and `pf.conf` contain hooks for a companion piece that is not published yet (the router acting as its own CLAT towards the carrier's NAT64 while on the backup). The controller skips the helper when it is not installed, but its default backup probe path (`BACKUP_PROBE_PATH=nat64`) needs that piece: until it is published, set `BACKUP_PROBE_PATH=clat4` to probe the backup over IPv4 from its lease address, which is how the router described here runs today.
