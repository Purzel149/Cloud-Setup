#!/usr/bin/env bash
set -euo pipefail

# Interactive SSH hardening for Debian/Ubuntu
# - Every hardening change is optional
# - Writes a dedicated drop-in config
# - Creates backups before changing SSH configuration
# - Validates sshd config before reload
# - Refuses key-only login unless a usable authorized_keys file is found

DROPIN_FILE="/etc/ssh/sshd_config.d/99-cloud-setup-hardening.conf"
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_DIR="/root/cloud-setup-backups/ssh/$(date +%Y%m%d-%H%M%S)"

ENABLE_PUBKEY_AUTH="no"
DISABLE_ROOT_LOGIN="no"
DISABLE_PASSWORD_LOGIN="no"
DISABLE_X11_FORWARDING="no"
SET_MAX_AUTH_TRIES="no"
MAX_AUTH_TRIES="3"
SET_LOGIN_GRACE_TIME="no"
LOGIN_GRACE_TIME="30s"
SET_ALLOW_USERS="no"
ALLOW_USERS=""
SET_CUSTOM_PORT="no"
CUSTOM_PORT=""
ALLOW_UFW_PORT="no"
KEY_CHECK_USER=""

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

prompt_with_default() {
  local label="$1"
  local current="$2"
  local input

  read -r -p "${label} [${current}]: " input
  if [[ -z "$input" ]]; then
    printf '%s\n' "$current"
  else
    printf '%s\n' "$input"
  fi
}

validate_no_newline() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -ge 1 ]] && [[ "$value" -le 65535 ]]
}

validate_max_auth_tries() {
  local value="$1"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] && [[ "$value" -le 10 ]]
}

validate_login_grace_time() {
  local value="$1"
  [[ "$value" =~ ^[1-9][0-9]*[smh]?$ ]]
}

validate_user_list() {
  local users="$1"
  local user

  validate_no_newline "$users" || return 1
  [[ -n "$users" ]] || return 1

  for user in $users; do
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || return 1
    getent passwd "$user" >/dev/null || return 1
  done
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

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "Dieses Skript benoetigt systemd (systemctl nicht gefunden)."
    exit 1
  fi

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
      echo "Nicht unterstuetzte Distribution: ${PRETTY_NAME:-unbekannt}"
      echo "Unterstuetzt: Debian, Ubuntu und Debian-Derivate mit APT + systemd."
      exit 1
    fi
  fi
}

ensure_openssh_server() {
  if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
    return
  fi

  echo "openssh-server/sshd wurde nicht gefunden."
  if yes_no "openssh-server jetzt installieren?" "yes"; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
  else
    echo "Abbruch: Ohne sshd kann die Konfiguration nicht sicher geprueft werden."
    exit 1
  fi
}

detect_ssh_service() {
  if systemctl list-unit-files --no-legend ssh.service 2>/dev/null | grep -q '^ssh\.service'; then
    echo "ssh"
  elif systemctl list-unit-files --no-legend sshd.service 2>/dev/null | grep -q '^sshd\.service'; then
    echo "sshd"
  else
    echo "ssh"
  fi
}

has_dropin_include() {
  [[ -r "$SSHD_CONFIG" ]] &&
    grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' "$SSHD_CONFIG"
}

ensure_dropin_include() {
  mkdir -p /etc/ssh/sshd_config.d

  if has_dropin_include; then
    return
  fi

  echo
  echo "Hinweis: ${SSHD_CONFIG} bindet /etc/ssh/sshd_config.d/*.conf aktuell nicht ein."
  echo "Damit die Cloud-Setup-Konfiguration getrennt bleibt, muss eine Include-Zeile ergaenzt werden."
  if yes_no "Include-Zeile in ${SSHD_CONFIG} hinzufuegen?" "yes"; then
    backup_file "$SSHD_CONFIG"
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_CONFIG"
  else
    echo "Abbruch: Ohne Include wuerde die Drop-in-Konfiguration nicht geladen."
    exit 1
  fi
}

authorized_keys_has_entries() {
  local file="$1"
  [[ -r "$file" ]] && grep -Eq '^[[:space:]]*(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)' "$file"
}

check_key_login_safety() {
  local user="$1"
  local home ssh_dir keys_file home_mode ssh_mode keys_mode

  if ! getent passwd "$user" >/dev/null; then
    echo "Fehler: User existiert nicht: ${user}"
    return 1
  fi

  home="$(getent passwd "$user" | cut -d: -f6)"
  ssh_dir="${home}/.ssh"
  keys_file="${ssh_dir}/authorized_keys"

  if [[ ! -d "$home" ]]; then
    echo "Fehler: Home-Verzeichnis fehlt: ${home}"
    return 1
  fi

  if [[ ! -d "$ssh_dir" ]]; then
    echo "Fehler: SSH-Verzeichnis fehlt: ${ssh_dir}"
    return 1
  fi

  if ! authorized_keys_has_entries "$keys_file"; then
    echo "Fehler: Keine SSH Public Keys in ${keys_file} gefunden."
    return 1
  fi

  home_mode="$(stat -c '%a' "$home")"
  ssh_mode="$(stat -c '%a' "$ssh_dir")"
  keys_mode="$(stat -c '%a' "$keys_file")"

  if [[ "${home_mode: -2:1}" =~ [2367] ]] || [[ "${home_mode: -1}" =~ [2367] ]]; then
    echo "Fehler: ${home} ist fuer Gruppe/Andere schreibbar (Mode ${home_mode})."
    return 1
  fi

  if [[ "${ssh_mode: -2:1}" =~ [2367] ]] || [[ "${ssh_mode: -1}" =~ [2367] ]]; then
    echo "Fehler: ${ssh_dir} ist fuer Gruppe/Andere schreibbar (Mode ${ssh_mode})."
    return 1
  fi

  if [[ "${keys_mode: -2:1}" =~ [2367] ]] || [[ "${keys_mode: -1}" =~ [2367] ]]; then
    echo "Fehler: ${keys_file} ist fuer Gruppe/Andere schreibbar (Mode ${keys_mode})."
    return 1
  fi

  echo "Key-Login Check erfolgreich fuer User '${user}'."
  echo "Gefunden: ${keys_file}"
}

current_default_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
  elif [[ -n "${USER:-}" && "${USER}" != "root" ]]; then
    echo "$USER"
  else
    echo ""
  fi
}

ask_options() {
  local default_user value

  echo "Interaktive SSH-Hardening-Konfiguration"
  echo "Alle Aenderungen sind optional. Enter uebernimmt den vorgeschlagenen Wert."
  echo

  if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]; then
    echo "Hinweis: Du bist vermutlich gerade per SSH verbunden."
    echo "Dieses Skript prueft die Konfiguration vor dem Reload, aber eine zweite offene SSH-Session ist empfohlen."
    echo
  fi

  if yes_no "Public-Key-Authentifizierung explizit aktivieren?" "yes"; then
    ENABLE_PUBKEY_AUTH="yes"
  fi

  if yes_no "Root-Login per SSH deaktivieren?" "yes"; then
    DISABLE_ROOT_LOGIN="yes"
  fi

  if yes_no "Passwort-Login deaktivieren und nur Key-Login erlauben?" "no"; then
    DISABLE_PASSWORD_LOGIN="yes"
    default_user="$(current_default_user)"
    while true; do
      KEY_CHECK_USER="$(prompt_with_default "User fuer Key-Login-Sicherheitscheck" "${default_user:-}")"
      if [[ -n "$KEY_CHECK_USER" ]] && check_key_login_safety "$KEY_CHECK_USER"; then
        break
      fi
      echo
      echo "Passwort-Login wird erst deaktiviert, wenn dieser Check erfolgreich ist."
      if ! yes_no "Anderen User pruefen?" "yes"; then
        echo "Abbruch: Key-only Login ohne gueltigen Key-Check waere lockout-gefaehrlich."
        exit 1
      fi
    done
  fi

  if yes_no "X11-Forwarding deaktivieren?" "yes"; then
    DISABLE_X11_FORWARDING="yes"
  fi

  if yes_no "MaxAuthTries setzen?" "yes"; then
    SET_MAX_AUTH_TRIES="yes"
    while true; do
      value="$(prompt_with_default "MaxAuthTries" "$MAX_AUTH_TRIES")"
      if validate_max_auth_tries "$value"; then
        MAX_AUTH_TRIES="$value"
        break
      fi
      echo "Ungueltiger Wert. Erlaubt: ganze Zahl 1-10."
    done
  fi

  if yes_no "LoginGraceTime setzen?" "yes"; then
    SET_LOGIN_GRACE_TIME="yes"
    while true; do
      value="$(prompt_with_default "LoginGraceTime" "$LOGIN_GRACE_TIME")"
      if validate_login_grace_time "$value"; then
        LOGIN_GRACE_TIME="$value"
        break
      fi
      echo "Ungueltiger Wert. Beispiele: 30s, 1m, 2m."
    done
  fi

  if yes_no "SSH-Zugriff auf bestimmte User begrenzen (AllowUsers)?" "no"; then
    SET_ALLOW_USERS="yes"
    while true; do
      value="$(prompt_with_default "AllowUsers Liste, mit Leerzeichen getrennt" "${KEY_CHECK_USER:-}")"
      if validate_user_list "$value"; then
        ALLOW_USERS="$value"
        break
      fi
      echo "Ungueltige User-Liste. Alle User muessen lokal existieren."
    done
  fi

  if yes_no "SSH-Port aendern?" "no"; then
    SET_CUSTOM_PORT="yes"
    while true; do
      value="$(prompt_with_default "Neuer SSH-Port" "22")"
      if validate_port "$value"; then
        CUSTOM_PORT="$value"
        break
      fi
      echo "Ungueltiger Port. Erlaubt: 1-65535."
    done

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
      echo "UFW ist aktiv. Der neue SSH-Port muss erlaubt werden, bevor SSH neu geladen wird."
      if yes_no "UFW-Regel fuer Port ${CUSTOM_PORT}/tcp hinzufuegen?" "yes"; then
        ALLOW_UFW_PORT="yes"
      else
        echo "Abbruch: Portwechsel ohne Firewall-Regel kann dich aussperren."
        exit 1
      fi
    fi
  fi
}

write_dropin() {
  local tmp_file
  tmp_file="$(mktemp)"

  {
    echo "# Managed by Cloud-Setup ssh-hardening.sh"
    echo "# Remove this file and reload SSH to undo these overrides."
    echo

    if [[ "$ENABLE_PUBKEY_AUTH" == "yes" ]]; then
      echo "PubkeyAuthentication yes"
    fi

    if [[ "$DISABLE_ROOT_LOGIN" == "yes" ]]; then
      echo "PermitRootLogin no"
    fi

    if [[ "$DISABLE_PASSWORD_LOGIN" == "yes" ]]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      echo "ChallengeResponseAuthentication no"
    fi

    if [[ "$DISABLE_X11_FORWARDING" == "yes" ]]; then
      echo "X11Forwarding no"
    fi

    if [[ "$SET_MAX_AUTH_TRIES" == "yes" ]]; then
      echo "MaxAuthTries ${MAX_AUTH_TRIES}"
    fi

    if [[ "$SET_LOGIN_GRACE_TIME" == "yes" ]]; then
      echo "LoginGraceTime ${LOGIN_GRACE_TIME}"
    fi

    if [[ "$SET_ALLOW_USERS" == "yes" ]]; then
      echo "AllowUsers ${ALLOW_USERS}"
    fi

    if [[ "$SET_CUSTOM_PORT" == "yes" ]]; then
      echo "Port ${CUSTOM_PORT}"
    fi
  } > "$tmp_file"

  if [[ "$(grep -vc '^#\|^$' "$tmp_file")" -eq 0 ]]; then
    rm -f "$tmp_file"
    echo "Keine Aenderungen ausgewaehlt. Nichts zu tun."
    exit 0
  fi

  install -m 0644 "$tmp_file" "$DROPIN_FILE"
  rm -f "$tmp_file"
}

test_sshd_config() {
  local sshd_bin

  sshd_bin="$(command -v sshd || true)"
  if [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]]; then
    sshd_bin="/usr/sbin/sshd"
  fi

  if [[ -z "$sshd_bin" ]]; then
    echo "Fehler: sshd wurde nicht gefunden."
    return 1
  fi

  "$sshd_bin" -t
}

apply_changes() {
  local ssh_service dropin_backup=""
  ssh_service="$(detect_ssh_service)"

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"

  ensure_dropin_include

  if [[ "$ALLOW_UFW_PORT" == "yes" ]]; then
    ufw allow "${CUSTOM_PORT}/tcp"
  fi

  if [[ -f "$DROPIN_FILE" ]]; then
    dropin_backup="${BACKUP_DIR}${DROPIN_FILE}"
    backup_file "$DROPIN_FILE"
  fi

  echo
  echo "Schreibe Konfiguration: ${DROPIN_FILE}"
  write_dropin

  echo "Pruefe SSH-Konfiguration..."
  if ! test_sshd_config; then
    echo "Fehler: sshd -t ist fehlgeschlagen. Stelle vorherige Drop-in-Konfiguration wieder her."
    if [[ -n "$dropin_backup" ]]; then
      cp -a "$dropin_backup" "$DROPIN_FILE"
    else
      rm -f "$DROPIN_FILE"
    fi
    exit 1
  fi

  echo "Lade SSH neu..."
  systemctl reload "$ssh_service"

  echo
  echo "Fertig."
  echo "Konfiguration: ${DROPIN_FILE}"
  echo "Backup-Verzeichnis: ${BACKUP_DIR}"
  echo "SSH-Service: ${ssh_service}"

  if [[ "$SET_CUSTOM_PORT" == "yes" ]]; then
    echo "Neuer SSH-Port: ${CUSTOM_PORT}"
    echo "Wichtig: Bestehende Sessions offen lassen und neuen Login separat testen."
  fi

  if [[ "$DISABLE_PASSWORD_LOGIN" == "yes" ]]; then
    echo "Passwort-Login wurde deaktiviert. Getesteter Key-User: ${KEY_CHECK_USER}"
    echo "Wichtig: Bestehende Sessions offen lassen und Key-Login separat testen."
  fi
}

require_root
check_platform
ensure_openssh_server
ask_options
apply_changes
