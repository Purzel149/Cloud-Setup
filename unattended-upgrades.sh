#!/usr/bin/env bash
set -euo pipefail

# Universal unattended-upgrades Script (Debian & Ubuntu compatible)
# - Preserves existing blacklists (uses separate config file)
# - Uses distro defaults for security origins
# - upgrades daily
# - reboot (if required) at 03:30
# - logs rotated & deleted after 30 days

# Optional env overrides:
#   REBOOT_TIME="03:30"
#   UPGRADE_ONCALENDAR="*-*-* 00:00"
#   RANDOM_DELAY_SEC="900"
#   AUTOCLEAN_INTERVAL_DAYS="7"
#   LOGROTATE_DAYS="30"

REBOOT_TIME="${REBOOT_TIME:-03:30}"
UPGRADE_ONCALENDAR="${UPGRADE_ONCALENDAR:-*-*-* 00:00}"
RANDOM_DELAY_SEC="${RANDOM_DELAY_SEC:-900}"
AUTOCLEAN_INTERVAL_DAYS="${AUTOCLEAN_INTERVAL_DAYS:-7}"
LOGROTATE_DAYS="${LOGROTATE_DAYS:-30}"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen: sudo bash $0"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Dieses Skript benötigt ein APT-basiertes System (Debian/Ubuntu)."
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Dieses Skript benötigt systemd (systemctl nicht gefunden)."
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
    echo "Nicht unterstützte Distribution: ${PRETTY_NAME:-unbekannt}"
    echo "Unterstützt: Debian, Ubuntu und Debian-Derivate mit APT + systemd."
    exit 1
  fi
fi

echo "[1/7] Pakete installieren…"
apt-get update
# -o Dpkg::Options::="--force-confold" sorgt dafür, dass bestehende Configs nicht kommentarlos überschrieben werden
DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" unattended-upgrades apt-listchanges needrestart logrotate

echo "[2/7] unattended-upgrades aktivieren…"
# Wir erzwingen hier keine Neukonfiguration, um Defaults der Distro zu wahren
systemctl enable unattended-upgrades

echo "[3/7] Auto-Upgrades aktivieren…"
# Diese Datei aktiviert den Timer. Hier ist überschreiben okay.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "${AUTOCLEAN_INTERVAL_DAYS}";
EOF

echo "[4/7] Custom-Config schreiben (Blacklists bleiben erhalten!)…"
# WICHTIG: Wir schreiben in '52my-custom...', damit '50unattended-upgrades' (wo die Blacklists und Origins liegen)
# nicht angefasst wird. Unsere Einstellungen überschreiben die Defaults nur dort, wo wir es wollen.
cat > /etc/apt/apt.conf.d/52my-custom-upgrades <<EOF
// Eigene Anpassungen - überschreibt Defaults aus 50unattended-upgrades
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";

Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";

// Falls du E-Mails willst, hier eintragen (Paket 'mailutils' o.ä. nötig):
// Unattended-Upgrade::Mail "admin@example.com";
Unattended-Upgrade::MailOnlyOnError "true";
EOF

echo "[5/7] systemd Timer anpassen (mit Random Delay)…"
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<EOF
[Timer]
OnCalendar=
OnCalendar=${UPGRADE_ONCALENDAR}
# Verhindert, dass alle Server exakt zur gleichen Sekunde updaten (0-15min Delay)
RandomizedDelaySec=${RANDOM_DELAY_SEC}
EOF

systemctl daemon-reload
systemctl enable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer >/dev/null
systemctl restart apt-daily.timer apt-daily-upgrade.timer

echo "[6/7] Logrotation konfigurieren…"
# Hier müssen wir die Datei überschreiben, da es keine "Include"-Logik für Logrotate-Konfigs gibt wie bei APT
cat > /etc/logrotate.d/unattended-upgrades <<EOF
/var/log/unattended-upgrades/*.log {
    daily
    rotate ${LOGROTATE_DAYS}
    missingok
    notifempty
    compress
    delaycompress
    create 640 root adm
}
EOF

# sofortige Prüfung
logrotate --debug /etc/logrotate.d/unattended-upgrades >/dev/null || true

echo "[7/7] Testlauf (Dry-Run)…"
# Zeigt an, welche Pakete kommen würden, installiert aber nichts
unattended-upgrade --dry-run --verbose || true

echo
echo "Fertig."
echo "Konfiguration: /etc/apt/apt.conf.d/52my-custom-upgrades"
echo "Original-Config (inkl. Blacklist): /etc/apt/apt.conf.d/50unattended-upgrades"
echo "Rebootzeit: ${REBOOT_TIME} (falls nötig)"

