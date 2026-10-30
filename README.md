# freebsd_failover

Dual-WAN failover for a FreeBSD 15 router with pf: a fiber primary and a 5G backup, switched by a small controller fed by four `dpinger` probes. Built and run on a real home router; human-directed and AI-assisted, with every change reviewed and tested on the box.

All addresses in this repo are documentation placeholders (RFC 5737 IPv4, `2001:db8::/32` IPv6, `00:00:5e:00:53:xx` MACs). Substitute your own; `docs/DESIGN.md` explains each one.

## How it works

| routing table (FIB) | purpose | default route |
|---|---|---|
| 0 | real traffic | primary normally, backup when failed over |
| 1 | primary probe table | primary's gateway, always |
| 2 | backup probe table | backup's gateway, always |

- **Each uplink is probed through its own FIB** (`setfib 1|2 dpinger …` to off-net targets), so the primary keeps being measured while traffic is on the backup; that is what makes failback safe.
- **Only the controller (`router/usr/local/sbin/wan-failover`) decides FIB 0's default.** The dhclient hooks (`router/etc/dhclient-scripts/`) keep each uplink's own FIB current, record its address, and touch FIB 0 only when `/var/run/wan_state` says that uplink is active.
- **pf is never flushed or reloaded on failover.** Each uplink has a static NAT rule to a pf table (`<att_addr>`, `<tmo_addr>`) that the hooks keep at the current lease address, so whichever interface the route picks NATs correctly. (Not `(if:0)`: a management alias configured in rc.conf becomes the interface's first address after boot.)
- **Decision rules:** a probe is down at ≥ 40 % loss and clear at ≤ 10 %. Fail over when both primary probes are down and the backup is at least partly up; fail back after the primary has been clear for 120 s (or at once if the backup dies). Anti-flap, startup grace, `lockf` serialisation, a cron safety net, and a reconcile of FIB 0's default every run.
- The backup in this build is T-Mobile 5G through a Teltonika TRB501: IPv6-only to the SIM with 464XLAT, so IPv4 is CGNAT/NAT64 and nothing inbound is possible. Two findings worth knowing if you have a similar link: T-Mobile's NAT64 drops **zero-byte** ICMP echoes (dpinger's default) and drops echo to some networks entirely, so the probes send a 16-byte payload to targets that answer.

## Layout

- `router/` — files installed on the router (paths mirror `/`): dhclient hooks and shared `wan-lib.sh`, `pf.conf`, the controller, its rc.d script and cron entry, smokeping helper wrappers.
- `scripts/` — the phase installers (P0 cleanup, P1 FIBs + hooks, P2 pf, P3 controller, smokeping), each with a dry run that touches nothing, a timestamped backup and verification; `rollback.sh`; `p3_panic.sh` (stop the controller and force the primary, independent of the controller); discovery/diagnostic scripts; `leak_scan.py` and `export_public.py`.
- `tests/` — `test_hooks.sh` (runs the real `/sbin/dhclient-script` functions with our hooks against stubs) and `test_failover.sh` (decision table, end-to-end dry runs, and a mutation pass: deliberately broken copies of the controller must fail the suite).
- `examples/smokeping-uplinks.conf` — probes that graph each uplink through its own FIB, and a TraceroutePing target for a carrier first hop that ignores echo.
- `docs/DESIGN.md` — the full design and phase plan.
- `legacy/` — the 2020 single-script version this replaces.

## Install order

Run each phase's dry run first (`sudo ./scripts/pN_….sh`), read the diff, then `--apply`:

1. `p0_cleanup.sh` — backups, remove old failover cruft.
2. `p1_fibs_hooks.sh` — `net.fibs=3`, dhclient hooks, management aliases.
3. `p2_pf.sh` — pf ruleset (auto-reverts if outbound NAT or internet breaks).
4. `p3_failover.sh` — controller, rc.d service, cron.

Panic button: `sudo ./scripts/p3_panic.sh` stops and disables the controller and puts FIB 0 back on the primary.

## Status

Steady state verified on the router; a pulled-fiber failover test is still to do (see `docs/DESIGN.md`, P6). Hopefully nothing surprising turns up there, but until it has run it is unproven.
