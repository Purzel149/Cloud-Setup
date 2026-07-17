#!/usr/bin/env bash
set -euo pipefail

# SSH-only Fail2ban setup for Debian/Ubuntu
# - Installs fail2ban
# - Enables only the sshd jail
# - Keeps the configuration in a separate local override file
# - Logs bans to /var/log/fail2ban.log
# - Rotates logs weekly and keeps 8 weeks

MAXRETRY="${MAXRETRY:-5}"
FINDTIME="${FINDTIME:-10m}"
BANTIME="${BANTIME:-1h}"
SSH_PORT="${SSH_PORT:-ssh}"
LOG_TARGET="${LOG_TARGET:-/var/log/fail2ban.log}"
BACKUP_DIR="/root/cloud-setup-backups/fail2ban-ssh/$(date +%Y%m%d-%H%M%S)"

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

echo "[1/5] Pakete installieren..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban logrotate

echo "[2/5] Logging und SSH-Jail konfigurieren..."

if ! [[ "$MAXRETRY" =~ ^[0-9]+$ ]]; then
  echo "Fehler: MAXRETRY ungueltig (Security)." >&2
  exit 1
fi

if ! [[ "$FINDTIME" =~ ^[0-9]+[a-zA-Z]*$ ]]; then
  echo "Fehler: FINDTIME ungueltig (Security)." >&2
  exit 1
fi

if ! [[ "$BANTIME" =~ ^-?[0-9]+[a-zA-Z]*$ ]]; then
  echo "Fehler: BANTIME ungueltig (Security)." >&2
  exit 1
fi

if ! [[ "$SSH_PORT" =~ ^[a-zA-Z0-9,]+$ ]]; then
  echo "Fehler: SSH_PORT ungueltig (Security)." >&2
  exit 1
fi

if [[ "$LOG_TARGET" == *$'\n'* ]] || [[ "$LOG_TARGET" == *$'\r'* ]]; then
  echo "Fehler: LOG_TARGET darf keine Zeilenumbrueche enthalten (Security)." >&2
  exit 1
fi

if [[ "$LOG_TARGET" != /* ]]; then
  echo "Fehler: LOG_TARGET muss ein absoluter Pfad sein." >&2
  exit 1
fi

if [[ ! "$LOG_TARGET" =~ ^/[A-Za-z0-9._/+:-]+$ ]]; then
  echo "Fehler: LOG_TARGET darf nur einfache Pfadzeichen enthalten." >&2
  exit 1
fi

mkdir -p /etc/fail2ban/jail.d
prepare_backup_dir
backup_file /etc/fail2ban/fail2ban.local
backup_file /etc/fail2ban/jail.d/sshd.local
cat > /etc/fail2ban/fail2ban.local <<EOF
[Definition]
loglevel = INFO
logtarget = ${LOG_TARGET}
EOF

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = ${MAXRETRY}
findtime = ${FINDTIME}
bantime = ${BANTIME}
EOF

echo "[3/5] Logrotation konfigurieren..."
backup_file /etc/logrotate.d/fail2ban
cat > /etc/logrotate.d/fail2ban <<EOF
${LOG_TARGET} {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    create 640 root adm
    sharedscripts
    postrotate
        fail2ban-client flushlogs >/dev/null 2>&1 || true
    endscript
}
EOF

logrotate --debug /etc/logrotate.d/fail2ban >/dev/null

echo "[4/5] Fail2ban aktivieren und starten..."
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "[5/5] Konfiguration prüfen..."
fail2ban-client status sshd || true

echo
echo "Fertig."
echo "Backup-Verzeichnis: ${BACKUP_DIR}"
echo "Konfiguration: /etc/fail2ban/jail.d/sshd.local"
echo "Logging: ${LOG_TARGET}"
echo "Geblockte IPs im Log finden: grep ' Ban ' ${LOG_TARGET}"
echo "Logrotation: /etc/logrotate.d/fail2ban (weekly, rotate 8)"
echo "Parameter: port=${SSH_PORT}, maxretry=${MAXRETRY}, findtime=${FINDTIME}, bantime=${BANTIME}"
