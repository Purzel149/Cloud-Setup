# Cloud Setup Scripts

This repository contains a collection of system administration and security shell scripts for Debian and Ubuntu environments. These scripts automate common setup and security hardening tasks, including configuring fail2ban, running Lynis security audits, and setting up unattended upgrades.

## Prerequisites

- **OS:** Debian, Ubuntu, or Debian-derivatives
- **Package Manager:** APT (`apt-get`)
- **Init System:** systemd (required for most scripts)
- **Privileges:** Root access is required (run as `sudo bash <script>.sh`)

## Available Scripts

### 1. `fail2ban-ssh.sh`
An SSH-only Fail2ban setup script.
- Installs `fail2ban`.
- Enables only the `sshd` jail to protect against brute-force attacks on SSH.
- Keeps the configuration in a separate local override file (`/etc/fail2ban/jail.d/sshd.local`).

**Environment Variables:**
- `MAXRETRY` (default: `5`): Number of failures before an IP is banned.
- `FINDTIME` (default: `10m`): The time window during which the failures must occur.
- `BANTIME` (default: `1h`): The duration for which the IP is banned.
- `SSH_PORT` (default: `ssh`): The port number or service name for SSH.

**Usage:**
```bash
sudo bash fail2ban-ssh.sh
# Or with custom settings:
MAXRETRY=3 BANTIME=24h sudo -E bash fail2ban-ssh.sh
```

### 2. `lynis-check.sh`
Automates running a Lynis security audit.
- Installs `lynis` if it is not already installed.
- Runs a read-only system audit.
- Stores timestamped reports and logs.
- Prints a summary containing the hardening score, warnings, and suggestions.

**Environment Variables:**
- `REPORT_DIR` (default: `/var/log/cloud-setup/lynis`): Directory to store audit reports and logs.
- `AUDITOR` (default: `Cloud-Setup`): The name of the auditor recorded in the report.

**Usage:**
```bash
sudo bash lynis-check.sh
```

### 3. `unattended-upgrades.sh`
A universal setup script for `unattended-upgrades` to keep your system up-to-date automatically.
- Preserves existing package blacklists (uses a separate config file: `/etc/apt/apt.conf.d/52my-custom-upgrades`).
- Uses distribution defaults for security origins.
- Schedules daily upgrades using systemd timers with a randomized delay to avoid thundering herd problems.
- Schedules automatic reboots (if required by package updates).
- Configures `logrotate` for unattended-upgrades logs.

**Environment Variables:**
- `ENABLE_AUTOMATIC_REBOOT` (default: `true`): Whether to allow automatic reboots if required.
- `REBOOT_TIME` (default: `03:30`): Time to reboot if required (HH:MM).
- `UPGRADE_ONCALENDAR` (default: `*-*-* 00:00`): systemd OnCalendar expression for upgrade schedule.
- `RANDOM_DELAY_SEC` (default: `900`): Maximum random delay in seconds for the systemd timer.
- `AUTOCLEAN_INTERVAL_DAYS` (default: `7`): Days between `apt-get autoclean` runs.
- `LOGROTATE_DAYS` (default: `30`): Days to keep rotated logs.

**Usage:**
```bash
sudo bash unattended-upgrades.sh
```

### 4. `unattended-upgrades-interactive.sh`
An interactive variant of `unattended-upgrades.sh`.
- Prompts the user for key configuration values, with the option to press Enter to accept the defaults.
- Validates all manual user input.
- If the environment variables (listed above) are set, they are used as the default values in the prompts.

**Usage:**
```bash
sudo bash unattended-upgrades-interactive.sh
```

## License
Refer to the `LICENSE` file in the repository for details.
