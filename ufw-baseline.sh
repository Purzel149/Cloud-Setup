#!/usr/bin/env bash
set -euo pipefail

# Interactive UFW baseline firewall for Debian/Ubuntu
# - Installs ufw if missing
# - Sets deny incoming / allow outgoing defaults
# - Allows SSH before enabling the firewall
# - Optionally allows HTTP and HTTPS
# - Shows rules before activation to reduce lockout risk

BACKUP_DIR="/root/cloud-setup-backups/ufw/$(date +%Y%m%d-%H%M%S)"
SSH_PORT="${SSH_PORT:-}"
ALLOW_HTTP="${ALLOW_HTTP:-ask}"
ALLOW_HTTPS="${ALLOW_HTTPS:-ask}"

yes_no() {
  local question="$1"
  local default="${2:-no}"
  local prompt answer

  case "$default" in
    yes) prompt="[Y/n]" ;;
    no) prompt="[y/N]" ;;
    *)
      echo "Internal error: invalid default for yes_no: ${default}" >&2
      exit 1
      ;;
  esac

  while true; do
    read -r -p "${question} ${prompt}: " answer
    answer="${answer:-$default}"
    case "$answer" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) echo "Bitte yes oder no eingeben." ;;
    esac
  done
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -ge 1 ]] && [[ "$value" -le 65535 ]]
}

validate_bool_or_ask() {
  local name="$1"
  local value="$2"

  case "$value" in
    true|false|ask) return 0 ;;
    *)
      echo "Ungueltiger Wert fuer ${name}: ${value}"
      echo "Erlaubt: true, false oder ask"
      exit 1
      ;;
  esac
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausfuehren: sudo bash $0"
    exit 1
  fi
}

check_platform() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Dieses Skript benoetigt ein APT-basiertes System (Debian/Ubuntu)."
    exit 1
  fi

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
      echo "Nicht unterstuetzte Distribution: ${PRETTY_NAME:-unbekannt}"
      echo "Unterstuetzt: Debian, Ubuntu und Debian-Derivate mit APT."
      exit 1
    fi
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

detect_ssh_port() {
  local detected=""

  if command -v sshd >/dev/null 2>&1; then
    detected="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
  elif [[ -x /usr/sbin/sshd ]]; then
    detected="$(/usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
  fi

  if [[ -z "$detected" && -r /etc/ssh/sshd_config ]]; then
    detected="$(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ { port=$2 } END { print port }' /etc/ssh/sshd_config)"
  fi

  echo "${detected:-22}"
}

prompt_ssh_port() {
  local detected="$1"
  local input

  if [[ -n "$SSH_PORT" ]]; then
    if ! validate_port "$SSH_PORT"; then
      echo "Ungueltiger Wert fuer SSH_PORT: ${SSH_PORT}"
      echo "Erlaubt: Port 1-65535"
      exit 1
    fi
    return
  fi

  while true; do
    read -r -p "SSH-Port erlauben [${detected}]: " input
    SSH_PORT="${input:-$detected}"
    if validate_port "$SSH_PORT"; then
      return
    fi
    echo "Bitte einen Port zwischen 1 und 65535 eingeben."
  done
}

should_allow() {
  local name="$1"
  local value="$2"
  local default="$3"

  case "$value" in
    true) return 0 ;;
    false) return 1 ;;
    ask) yes_no "${name} erlauben?" "$default" ;;
  esac
}

require_root
check_platform
validate_bool_or_ask "ALLOW_HTTP" "$ALLOW_HTTP"
validate_bool_or_ask "ALLOW_HTTPS" "$ALLOW_HTTPS"
prepare_backup_dir

echo "[1/6] UFW installieren falls noetig..."
if ! command -v ufw >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
else
  echo "UFW ist bereits installiert: $(command -v ufw)"
fi

echo "[2/6] Bestehende UFW-Konfiguration sichern..."
backup_file /etc/default/ufw
backup_file /etc/ufw/user.rules
backup_file /etc/ufw/user6.rules

echo "[3/6] SSH-Port bestimmen..."
detected_ssh_port="$(detect_ssh_port)"
prompt_ssh_port "$detected_ssh_port"
echo "SSH-Port: ${SSH_PORT}/tcp"

echo "[4/6] Baseline-Regeln setzen..."
ufw --force default deny incoming
ufw --force default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment "Cloud-Setup SSH"

if should_allow "HTTP (80/tcp)" "$ALLOW_HTTP" "no"; then
  ufw allow 80/tcp comment "Cloud-Setup HTTP"
fi

if should_allow "HTTPS (443/tcp)" "$ALLOW_HTTPS" "yes"; then
  ufw allow 443/tcp comment "Cloud-Setup HTTPS"
fi

echo "[5/6] Geplante Regeln:"
ufw status verbose
echo
echo "Wichtig: Stelle sicher, dass dein aktueller SSH-Zugang ueber ${SSH_PORT}/tcp funktioniert."

if ! yes_no "Firewall jetzt aktivieren?" "yes"; then
  echo "UFW wurde konfiguriert, aber nicht aktiviert."
  echo "Aktivierung spaeter mit: sudo ufw enable"
  echo "Backup-Verzeichnis: ${BACKUP_DIR}"
  exit 0
fi

echo "[6/6] UFW aktivieren..."
ufw --force enable
ufw status verbose

echo
echo "Fertig."
echo "Backup-Verzeichnis: ${BACKUP_DIR}"
