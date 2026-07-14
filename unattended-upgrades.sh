#!/usr/bin/env bash
set -euo pipefail

# Universal unattended-upgrades Script (Debian & Ubuntu compatible)
# - Preserves existing blacklists (uses separate config file)
# - Uses distro defaults for security origins
# - upgrades daily
# - reboot (if required) at 03:30
# - logs rotated & deleted after 30 days

# Optional env overrides:
#   ENABLE_AUTOMATIC_REBOOT="true"
#   REBOOT_TIME="03:30"
#   UPGRADE_ONCALENDAR="*-*-* 00:00"
#   RANDOM_DELAY_SEC="900"
#   AUTOCLEAN_INTERVAL_DAYS="7"
#   LOGROTATE_DAYS="30"

ENABLE_AUTOMATIC_REBOOT="${ENABLE_AUTOMATIC_REBOOT:-true}"
REBOOT_TIME="${REBOOT_TIME:-03:30}"
UPGRADE_ONCALENDAR="${UPGRADE_ONCALENDAR:-*-*-* 00:00}"
RANDOM_DELAY_SEC="${RANDOM_DELAY_SEC:-900}"
AUTOCLEAN_INTERVAL_DAYS="${AUTOCLEAN_INTERVAL_DAYS:-7}"
LOGROTATE_DAYS="${LOGROTATE_DAYS:-30}"
BACKUP_DIR="/root/cloud-setup-backups/unattended-upgrades/$(date +%Y%m%d-%H%M%S)"

validate_bool() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]]
}

validate_reboot_time() {
  local value="$1"
  [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

validate_positive_int() {
  local value="$1"
  [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

validate_non_negative_int() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]]
}

validate_no_newline() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

validate_oncalendar() {
  local value="$1"
  if [[ -z "$value" ]] || ! validate_no_newline "$value"; then
    return 1
  fi

  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "$value" >/dev/null 2>&1
    return $?
  fi

  # Fallback without systemd-analyze: at least ensure a simple date/time-like pattern.
  [[ "$value" =~ ^[0-9\*]+-[0-9\*]+-[0-9\*]+[[:space:]]+[0-9\*]+:[0-9\*]+$ ]]
}

validate_settings() {
  if ! validate_bool "$ENABLE_AUTOMATIC_REBOOT"; then
    echo "Ungültiger Wert für ENABLE_AUTOMATIC_REBOOT: ${ENABLE_AUTOMATIC_REBOOT}"
    echo "Erlaubt: true oder false"
    exit 1
  fi

  if ! validate_no_newline "$REBOOT_TIME" || ! validate_reboot_time "$REBOOT_TIME"; then
    echo "Ungültiger Wert für REBOOT_TIME: ${REBOOT_TIME}"
    echo "Erlaubtes Format: HH:MM (24h), z.B. 03:30"
    exit 1
  fi

  if ! validate_oncalendar "$UPGRADE_ONCALENDAR"; then
    echo "Ungültiger Wert für UPGRADE_ONCALENDAR: ${UPGRADE_ONCALENDAR}"
    echo "Beispiel: *-*-* 00:00"
    exit 1
  fi

  if ! validate_no_newline "$RANDOM_DELAY_SEC" || ! validate_non_negative_int "$RANDOM_DELAY_SEC"; then
    echo "Ungültiger Wert für RANDOM_DELAY_SEC: ${RANDOM_DELAY_SEC}"
    echo "Erlaubt: ganze Zahl >= 0"
    exit 1
  fi

  if ! validate_no_newline "$AUTOCLEAN_INTERVAL_DAYS" || ! validate_positive_int "$AUTOCLEAN_INTERVAL_DAYS"; then
    echo "Ungültiger Wert für AUTOCLEAN_INTERVAL_DAYS: ${AUTOCLEAN_INTERVAL_DAYS}"
    echo "Erlaubt: ganze Zahl > 0"
    exit 1
  fi

  if ! validate_no_newline "$LOGROTATE_DAYS" || ! validate_positive_int "$LOGROTATE_DAYS"; then
    echo "Ungültiger Wert für LOGROTATE_DAYS: ${LOGROTATE_DAYS}"
    echo "Erlaubt: ganze Zahl > 0"
    exit 1
  fi
}

prepare_backup_dir() {
  install -d -m 0700 "$BACKUP_DIR"
}

backup_file() {
  local file="$1"
  local backup_file

  if [[ ! -e "$file" ]]; then
    return
  fi

  backup_file="${BACKUP_DIR}${file}"
  mkdir -p "$(dirname "$backup_file")"
  cp -a "$file" "$backup_file"
  echo "Backup erstellt: ${backup_file}"
}

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

validate_settings
prepare_backup_dir

echo "[1/7] Pakete installieren..."
apt-get update
# -o Dpkg::Options::="--force-confold" sorgt dafür, dass bestehende Configs nicht kommentarlos überschrieben werden
DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" unattended-upgrades apt-listchanges needrestart logrotate

echo "[2/7] unattended-upgrades aktivieren..."
# Wir erzwingen hier keine Neukonfiguration, um Defaults der Distro zu wahren
systemctl enable unattended-upgrades

echo "[3/7] Auto-Upgrades aktivieren..."
# Diese Datei aktiviert den Timer. Hier ist überschreiben okay.
backup_file /etc/apt/apt.conf.d/20auto-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "${AUTOCLEAN_INTERVAL_DAYS}";
EOF

echo "[4/7] Custom-Config schreiben (Blacklists bleiben erhalten!)..."
# WICHTIG: Wir schreiben in '52my-custom...', damit '50unattended-upgrades' (wo die Blacklists und Origins liegen)
# nicht angefasst wird. Unsere Einstellungen überschreiben die Defaults nur dort, wo wir es wollen.
backup_file /etc/apt/apt.conf.d/52my-custom-upgrades
cat > /etc/apt/apt.conf.d/52my-custom-upgrades <<EOF
// Eigene Anpassungen - überschreibt Defaults aus 50unattended-upgrades
Unattended-Upgrade::Automatic-Reboot "${ENABLE_AUTOMATIC_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";

Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";

// Falls du E-Mails willst, hier eintragen (Paket 'mailutils' o.ä. nötig):
// Unattended-Upgrade::Mail "admin@example.com";
Unattended-Upgrade::MailOnlyOnError "true";
EOF

echo "[5/7] systemd Timer anpassen (mit Random Delay)..."
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
backup_file /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf
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

echo "[6/7] Logrotation konfigurieren..."
# Hier müssen wir die Datei überschreiben, da es keine "Include"-Logik für Logrotate-Konfigs gibt wie bei APT
backup_file /etc/logrotate.d/unattended-upgrades
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
logrotate --debug /etc/logrotate.d/unattended-upgrades >/dev/null

echo "[7/7] Testlauf (Dry-Run)..."
# Zeigt an, welche Pakete kommen würden, installiert aber nichts
unattended-upgrade --dry-run --verbose || true

echo
echo "Fertig."
echo "Backup-Verzeichnis: ${BACKUP_DIR}"
echo "Konfiguration: /etc/apt/apt.conf.d/52my-custom-upgrades"
echo "Original-Config (inkl. Blacklist): /etc/apt/apt.conf.d/50unattended-upgrades"
echo "Automatischer Reboot: ${ENABLE_AUTOMATIC_REBOOT}"
echo "Rebootzeit: ${REBOOT_TIME} (falls nötig)"
