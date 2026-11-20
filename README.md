# Hardening and Observing a Self-Hosted Ghost Blog

A set of guides for a small Linux server that runs a self-hosted [Ghost](https://ghost.org) blog behind a Cloudflare Tunnel, reached over Tailscale, and watched with Prometheus and Grafana. The steps were worked through and tested on one Raspberry Pi 5 running Ubuntu Server 24.04. Your setup will differ, so treat every step as something to check against your own system.

> [!NOTE]
> These guides were written with Claude (Haiku 5.5) in a vibe-coding session. The author ran and checked every step on their own machine, and the guides describe what was actually done there. Read them critically, test each step, and keep a way back in before you change SSH or the firewall.

## The guides

| Part | Document | What it covers |
|------|----------|----------------|
| 1 | [Host hardening](./01-host-hardening.md) | SSH, Tailscale and its ACL, fail2ban, removing unneeded services, file-integrity monitoring with AIDE, malware scanning with ClamAV, and backups of the whole machine |
| 2 | [Ghost](./02-ghost.md) | Database credentials, secret files, the Cloudflare Tunnel and Access, mail, staff device verification, login protection, and Ghost backups |
| 3 | [Observability](./03-observability.md) | Running Prometheus as its own user, exporters and Grafana bound to loopback, and publishing Grafana through Tailscale Serve |

Work through the parts in order. Part 1 is the base, and Parts 2 and 3 assume it.

## Files in this folder

- `env.template`: every variable the guides use. Copy it to `env.local`, fill it in, and never publish `env.local`.
- `verify-state.sh`: a read-only check that prints the state of the machine. It reads `env.local`. Its output contains addresses and URLs from your system, so review it before you share it.

## Prerequisites

This guide assumes a working system. It hardens what's there; it doesn't build it from scratch.

| Item | Notes |
|------|-------|
| Linux server | Tested on Ubuntu Server 24.04 LTS, on a Raspberry Pi 5. Other releases and hardware are untested |
| Admin account | A non-root user in the `sudo` group, with SSH key login working |
| Ghost via ghost-cli | Installed in `$GHOST_DIR`, backed by a local MySQL database, listening on `$GHOST_PORT` |
| Cloudflare Tunnel | `cloudflared` routing `$PUBLIC_DOMAIN` to `http://localhost:$GHOST_PORT` |
| Tailscale | Installed and logged in on the server, with MagicDNS enabled |
| Monitoring (Part 3 only) | Prometheus, node_exporter, nut_exporter (optional), and Grafana, installed and scraping |
| Accounts | Cloudflare (with Zero Trust), Tailscale admin console access, and a Mailgun or other SMTP account with a verified sending domain |

Standard Ubuntu tools are assumed. You'll also need `openssl`, `python3`, `curl`, and `scp`.

## Before you begin

- **Keep a way back in.** Keep one SSH session open at all times. Several steps change SSH, the firewall, and bind addresses.
- **Know where your console is.** A keyboard and monitor on the machine are the last resort if SSH is lost.
- **Take a copy of your configuration first.** Back up `/etc`, your Ghost directory, and your Prometheus configuration.
- **Fill in your variables.** Copy `env.template` to `env.local`, set every value, and load it with `set -a; source env.local; set +a` in each shell you use.
- **Record a baseline.** Run `verify-state.sh` before you start, and keep the output for comparison.

## Reading the commands

- Commands that start with `sudo` need a real terminal, because `sudo` asks for a password. Automated shells can't answer that prompt.
- A `<PLACEHOLDER>` in a config file must be replaced with a real value. A `$VARIABLE` in a shell command is expanded from `env.local`. Systemd units and AIDE rules don't expand variables, so write the real value into those files.

## Verification

Run `verify-state.sh` after each part, and compare the result with your baseline. Each part also lists the checks that matter for it.

## Acknowledgements

Thanks to the people whose tools and documentation these guides lean on: the Ghost, Tailscale, Cloudflare, Prometheus, Grafana, AIDE, and ClamAV projects. The Claude (Haiku 5.5) session that helped write these guides also deserves a note: it did a lot of the tedious checking and cross-referencing, and it made some mistakes along the way that the author corrected on the machine itself. Where a step was wrong, the guides now say so.
