#!/usr/bin/env bash
set -euo pipefail

# SSH-only Fail2ban setup for Debian/Ubuntu
# - Installs fail2ban
# - Enables only the sshd jail
# - Keeps the configuration in a separate local override file

MAXRETRY="${MAXRETRY:-5}"
FINDTIME="${FINDTIME:-10m}"
BANTIME="${BANTIME:-1h}"
SSH_PORT="${SSH_PORT:-ssh}"

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

echo "[1/4] Pakete installieren..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban

echo "[2/4] SSH-Jail konfigurieren..."
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = ${MAXRETRY}
findtime = ${FINDTIME}
bantime = ${BANTIME}
EOF

echo "[3/4] Fail2ban aktivieren und starten..."
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "[4/4] Konfiguration prüfen..."
fail2ban-client status sshd || true

echo
echo "Fertig."
echo "Konfiguration: /etc/fail2ban/jail.d/sshd.local"
echo "Parameter: port=${SSH_PORT}, maxretry=${MAXRETRY}, findtime=${FINDTIME}, bantime=${BANTIME}"
