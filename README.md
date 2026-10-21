# Cloud-Setup

Small, self-contained Bash scripts for setting up and checking Debian/Ubuntu servers.
Each script is standalone: copy it to the server and run it as root.

## Requirements

- Debian, Ubuntu, or a Debian derivative with APT (`update-alloy.sh` also supports DNF/YUM and Zypper)
- Root privileges (`sudo`)
- Bash 4+

## Getting the scripts

```bash
git clone https://github.com/purzel149/cloud-setup.git
cd cloud-setup
```

All scripts are executable. If not: `chmod +x *.sh`.

> **Keep a second SSH session open** while running `ssh-hardening.sh` or `ufw-baseline.sh`,
> so a mistake cannot lock you out.

## Overview

| Script | Purpose | Interactive | Changes system |
| --- | --- | --- | --- |
| `ssh-hardening.sh` | Optional SSH hardening via a drop-in config | yes | yes |
| `ufw-baseline.sh` | Baseline UFW firewall (deny in / allow out, SSH allowed) | yes | yes |
| `fail2ban-ssh.sh` | Fail2ban with the `sshd` jail only | no | yes |
| `unattended-upgrades.sh` | Automatic daily security updates | no | yes |
| `unattended-upgrades-interactive.sh` | Same, but prompts for each value | yes | yes |
| `lynis-check.sh` | Lynis security audit with score summary | no | installs Lynis only |
| `server-health-report.sh` | Quick/Full health report | menu or flags | no (read-only) |
| `security-log-summary.sh` | Summary of SSH failures, bans, severe journal events | no | no (read-only) |
| `update-alloy.sh` | Check for / install Grafana Alloy updates | menu or flags | yes |

Scripts that change the system back up the files they touch to
`/root/cloud-setup-backups/<script>/<timestamp>/` first.

## Usage

### `ssh-hardening.sh`

```bash
sudo ./ssh-hardening.sh
```

Asks yes/no for each hardening option (pubkey auth, disable root login, disable
password login, disable X11 forwarding, `MaxAuthTries`, `LoginGraceTime`,
`AllowUsers`, custom port, matching UFW rule). Settings are written to
`/etc/ssh/sshd_config.d/99-cloud-setup-hardening.conf`, validated with `sshd -t`,
and only then reloaded. Key-only login is refused if no usable `authorized_keys`
file is found.

### `ufw-baseline.sh`

```bash
sudo ./ufw-baseline.sh
# non-interactive answers for HTTP/HTTPS and the SSH port
sudo SSH_PORT=2222 ALLOW_HTTP=yes ALLOW_HTTPS=yes ./ufw-baseline.sh
```

Installs UFW if missing, sets the defaults, allows SSH first, optionally allows
HTTP/HTTPS, and shows the rules before enabling the firewall.

| Variable | Default | Description |
| --- | --- | --- |
| `SSH_PORT` | auto-detected | SSH port to allow |
| `ALLOW_HTTP` | `ask` | Allow port 80 |
| `ALLOW_HTTPS` | `ask` | Allow port 443 |

### `fail2ban-ssh.sh`

```bash
sudo ./fail2ban-ssh.sh
sudo MAXRETRY=3 BANTIME=24h FINDTIME=10m ./fail2ban-ssh.sh
```

| Variable | Default | Description |
| --- | --- | --- |
| `MAXRETRY` | `5` | Failures before a ban |
| `FINDTIME` | `10m` | Window in which failures are counted |
| `BANTIME` | `1h` | Ban duration |
| `SSH_PORT` | `ssh` | SSH port/service name |
| `LOG_TARGET` | `/var/log/fail2ban.log` | Ban log (rotated weekly, 8 weeks kept) |

Check afterwards: `sudo fail2ban-client status sshd`

### `unattended-upgrades.sh`

```bash
sudo ./unattended-upgrades.sh
sudo ENABLE_AUTOMATIC_REBOOT=false ./unattended-upgrades.sh
sudo REBOOT_TIME=04:00 LOGROTATE_DAYS=14 ./unattended-upgrades.sh
```

| Variable | Default | Description |
| --- | --- | --- |
| `ENABLE_AUTOMATIC_REBOOT` | `true` | Reboot when required |
| `REBOOT_TIME` | `03:30` | Reboot time (`HH:MM`) |
| `UPGRADE_ONCALENDAR` | `*-*-* 00:00` | systemd timer schedule |
| `RANDOM_DELAY_SEC` | `900` | Random timer delay |
| `AUTOCLEAN_INTERVAL_DAYS` | `7` | APT autoclean interval |
| `LOGROTATE_DAYS` | `30` | Days of logs to keep |
| `APT_LOCK_TIMEOUT_SEC` | `120` | Wait for the APT lock |
| `APT_NETWORK_TIMEOUT_SEC` | `30` | APT network timeout |
| `DRYRUN_TIMEOUT_SEC` | `600` | Timeout for the validation dry run |

Existing blacklists are preserved (a separate config file is used).

### `unattended-upgrades-interactive.sh`

```bash
sudo ./unattended-upgrades-interactive.sh
```

Prompts for each value; press Enter to keep the default shown in brackets.
The same variables (without `ENABLE_AUTOMATIC_REBOOT` and `DRYRUN_TIMEOUT_SEC`,
plus `APT_COMMAND_TIMEOUT_SEC`, default `900`) can be pre-set in the environment.

### `lynis-check.sh`

```bash
sudo ./lynis-check.sh
sudo REPORT_DIR=/root/lynis AUDITOR="My Name" ./lynis-check.sh
```

Installs Lynis if needed, runs a read-only audit, and prints the hardening score,
warnings and suggestions. Reports are saved to `/var/log/cloud-setup/lynis`
(override with `REPORT_DIR`).

### `server-health-report.sh`

```bash
sudo ./server-health-report.sh                 # interactive Quick/Full menu
sudo ./server-health-report.sh --quick --no-color
sudo ./server-health-report.sh --full --since "7 days ago" --output /root/health.txt
```

| Option | Description |
| --- | --- |
| `--quick` | Fast, local-only summary |
| `--full` | Quick summary plus detailed diagnostics |
| `--output FILE` | Also save a private report (mode `0600`) |
| `--sanitize` | Redact hostnames, user names, and IP addresses (safe to share) |
| `--since TIME` | Log window for full mode (default `24 hours ago`) |
| `--no-color` | Disable colors |

Thresholds can be set via `DISK_WARN`/`DISK_CRITICAL` (80/90), `MEMORY_WARN`/`MEMORY_CRITICAL`
(85/95), `SWAP_WARN`/`SWAP_CRITICAL` (50/80), and `CERT_WARN_DAYS` (30).

The script never installs packages or changes configuration; without root some
results may be incomplete.

### `security-log-summary.sh`

```bash
sudo ./security-log-summary.sh
sudo ./security-log-summary.sh --since "7 days ago" --output /root/security-log-summary.txt
sudo ./security-log-summary.sh --sanitize --output ./security-log-summary.txt
```

| Option | Description |
| --- | --- |
| `--since TIME` | Log window (default `24 hours ago`) |
| `--output FILE` | Also save a private report (mode `0600`) |
| `--sanitize` | Redact hostnames, user names, and IP addresses |
| `--no-color` | Disable colors |

Exit codes: `0` no findings, `1` warnings, `2` critical findings, which makes it
usable in cron or monitoring.

### `update-alloy.sh`

```bash
sudo ./update-alloy.sh           # interactive Update/Check menu
sudo ./update-alloy.sh --check   # check only, no update or restart
sudo ./update-alloy.sh --yes     # update without the confirmation prompt
```

Updates an existing Grafana Alloy installation installed via APT, DNF/YUM, or
Zypper. Standalone binaries and containers are detected and reported but never
replaced automatically.

## Recommended order for a new server

1. `sudo ./unattended-upgrades.sh`
2. `sudo ./ufw-baseline.sh`
3. `sudo ./ssh-hardening.sh`
4. `sudo ./fail2ban-ssh.sh`
5. `sudo ./lynis-check.sh`
6. `sudo ./server-health-report.sh --quick`

## Development

- Shell scripts are linted by the `check-shell-scripts` GitHub workflow.
- The `Manual root integration test` workflow can run `fail2ban-ssh.sh`,
  `lynis-check.sh`, or `unattended-upgrades.sh` on a disposable Ubuntu runner.
- `test_reload.sh` is a small helper that reloads (or restarts) the SSH service.

## License

See [LICENSE](LICENSE).
