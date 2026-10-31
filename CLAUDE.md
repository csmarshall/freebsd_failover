# CLAUDE.md — freebsd_failover

## Golden rules
- **This repo is public and is a generated export.** The real, deployable source lives in a private project dir; changes are made there, deployed to the router with the phase scripts, then exported here by a private export tool that applies a private substitution map and refuses to finish unless the leak scan and all test suites pass on the result.
- **Never commit real addresses, MACs, hostnames or names.** Use RFC 5737 IPv4, `2001:db8::/32` IPv6, `00:00:5e:00:53:xx` MACs. `scripts/leak_scan.py --self-test` and `scripts/leak_scan.py .` run in CI; they must stay green. When the scanner misses a leak, add the string to its MUST_FLAG list before fixing the rule.
- Don't hand-edit exported paths (`router/`, `scripts/`, `tests/`, `docs/DESIGN.md`, `examples/smokeping-uplinks.conf`): the next export overwrites them. Repo-only files (README, this file, CI, `.gitignore`, `legacy/`) are edited normally.
- Shell: `unset TMOUT`; `set -euo pipefail` where appropriate; no early-exiting consumer after a big producer under pipefail; dry runs touch nothing; every detector is validated against a known-bad input (the tests' mutation pass is how the controller suite proves it can fail).
- FreeBSD userland (BSD `sed -i ''`, `stat -f`); the tests need FreeBSD's `/sbin/dhclient-script`, so they run in a FreeBSD VM in CI.

## Flow
1. Issue first (`gh issue create`).
2. Branch in a git worktree outside any live tree.
3. PR with `Closes #n`; CI green is the gate.
4. Independent review of the diff, then the owner reviews.
5. Squash-merge; deploy deliberately from the private source.
