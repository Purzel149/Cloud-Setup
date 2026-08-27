#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only Debian/Ubuntu server health report.
# - No arguments: interactive Quick/Full menu
# - --quick / --full: non-interactive automation modes
# - Never installs packages, refreshes repositories, restarts services, or changes configuration

MODE=""
OUTPUT_FILE=""
SANITIZE=false
NO_COLOR=false
SINCE="24 hours ago"
WARNINGS=0
CRITICALS=0
REPORT_FILE=""

DISK_WARN="${DISK_WARN:-80}"
DISK_CRITICAL="${DISK_CRITICAL:-90}"
MEMORY_WARN="${MEMORY_WARN:-85}"
MEMORY_CRITICAL="${MEMORY_CRITICAL:-95}"
SWAP_WARN="${SWAP_WARN:-50}"
SWAP_CRITICAL="${SWAP_CRITICAL:-80}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-30}"

usage() {
  cat <<'EOF'
Usage: ./server-health-report.sh [OPTIONS]

With no options, an interactive Quick/Full menu is shown.

Modes:
  --quick           Fast, local-only health summary
  --full            Quick summary plus detailed diagnostics

Options:
  --output FILE     Save a private (mode 0600) plain-text report
  --sanitize        Redact hostnames, local user names, and IP addresses
  --since TIME      Full-mode log window (default: "24 hours ago")
  --no-color        Disable colors in terminal output
  -h, --help        Show this help

Automation examples:
  sudo ./server-health-report.sh --quick --no-color
  sudo ./server-health-report.sh --full --since "7 days ago" --output /root/health.txt
  sudo ./server-health-report.sh --full --sanitize --output ./health-sanitized.txt

Exit codes:
  0  Healthy
  1  One or more warnings
  2  One or more critical findings
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

validate_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_settings() {
  local name value
  for name in DISK_WARN DISK_CRITICAL MEMORY_WARN MEMORY_CRITICAL SWAP_WARN SWAP_CRITICAL CERT_WARN_DAYS; do
    value="${!name}"
    validate_integer "$value" || die "${name} must be a non-negative integer."
  done

  (( DISK_WARN < DISK_CRITICAL && DISK_CRITICAL <= 100 )) || die "disk thresholds must satisfy WARN < CRITICAL <= 100."
  (( MEMORY_WARN < MEMORY_CRITICAL && MEMORY_CRITICAL <= 100 )) || die "memory thresholds must satisfy WARN < CRITICAL <= 100."
  (( SWAP_WARN < SWAP_CRITICAL && SWAP_CRITICAL <= 100 )) || die "swap thresholds must satisfy WARN < CRITICAL <= 100."
  [[ "$SINCE" != *$'\n'* && "$SINCE" != *$'\r'* && -n "$SINCE" ]] || die "--since must be a non-empty single-line value."
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --quick|--full)
        [[ -z "$MODE" ]] || die "choose only one mode: --quick or --full."
        MODE="${1#--}"
        ;;
      --output)
        shift
        (( $# > 0 )) || die "--output requires a file path."
        OUTPUT_FILE="$1"
        ;;
      --sanitize) SANITIZE=true ;;
      --since)
        shift
        (( $# > 0 )) || die "--since requires a time expression."
        SINCE="$1"
        ;;
      --no-color) NO_COLOR=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done
}

interactive_menu() {
  cat <<'EOF'
Cloud-Setup Server Health Report

  1) Quick health check
  2) Full detailed report
EOF
  read -r -p "Choose [1-2]: " choice
  case "$choice" in
    1) MODE="quick" ;;
    2) MODE="full" ;;
    *) die "invalid choice; enter 1 or 2." ;;
  esac
}

cleanup() {
  [[ -n "$REPORT_FILE" && -f "$REPORT_FILE" ]] && rm -f -- "$REPORT_FILE"
  return 0
}
trap cleanup EXIT

section() {
  printf '\n== %s ==\n' "$1"
}

status() {
  local level="$1" label="$2" detail="$3"
  printf '%-20s %-10s %s\n' "${label}:" "$level" "$detail"
  case "$level" in
    WARNING) ((WARNINGS += 1)) ;;
    CRITICAL) ((CRITICALS += 1)) ;;
  esac
}

info() {
  printf '%-20s %s\n' "${1}:" "$2"
}

percent_status() {
  local label="$1" value="$2" warn="$3" critical="$4" detail
  detail="${5:-${value}% used}"
  if (( value >= critical )); then
    status CRITICAL "$label" "$detail"
  elif (( value >= warn )); then
    status WARNING "$label" "$detail"
  else
    status OK "$label" "$detail"
  fi
}

command_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

detect_ssh_service() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --no-legend ssh.service 2>/dev/null | grep -q '^ssh\.service'; then
    printf 'ssh\n'
  elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --no-legend sshd.service 2>/dev/null | grep -q '^sshd\.service'; then
    printf 'sshd\n'
  else
    printf 'ssh\n'
  fi
}

detect_ssh_port() {
  local sshd_bin="" port=""
  sshd_bin="$(command -v sshd 2>/dev/null || true)"
  [[ -n "$sshd_bin" ]] || [[ ! -x /usr/sbin/sshd ]] || sshd_bin="/usr/sbin/sshd"
  if [[ -n "$sshd_bin" ]]; then
    port="$(command_timeout 3 "$sshd_bin" -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
  fi
  printf '%s\n' "${port:-22}"
}

check_identity() {
  local os="unknown" virtualization="none detected"
  if [[ -r /etc/os-release ]]; then
    os="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-unknown}")"
  fi
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virtualization="$(systemd-detect-virt 2>/dev/null || printf 'none')"
  fi
  info "Generated" "$(date --iso-8601=seconds 2>/dev/null || date)"
  info "Mode" "$MODE"
  info "Host" "$(hostname -f 2>/dev/null || hostname)"
  info "Operating system" "$os"
  info "Kernel" "$(uname -r)"
  info "Virtualization" "$virtualization"
  info "Privileges" "$([[ $EUID -eq 0 ]] && printf 'root' || printf 'limited (run as root for complete results)')"
}

check_resources() {
  local uptime_text load1 load5 load15 cores load_level mem_total mem_available mem_used mem_percent
  local swap_total swap_free swap_used swap_percent disk_percent inode_percent

  uptime_text="$(uptime -p 2>/dev/null || awk '{printf "%.1f days", $1 / 86400}' /proc/uptime)"
  info "Uptime" "$uptime_text"

  read -r load1 load5 load15 _ < /proc/loadavg
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
  load_level="$(awk -v load="$load1" -v cores="$cores" 'BEGIN {if (load >= cores * 2) print "CRITICAL"; else if (load >= cores) print "WARNING"; else print "OK"}')"
  status "$load_level" "System load" "${load1} / ${load5} / ${load15} (${cores} CPU threads)"

  mem_total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  mem_available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  mem_used=$((mem_total - mem_available))
  mem_percent=$((mem_used * 100 / mem_total))
  percent_status "Memory" "$mem_percent" "$MEMORY_WARN" "$MEMORY_CRITICAL" "${mem_percent}% used"

  swap_total="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
  swap_free="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)"
  if (( swap_total == 0 )); then
    status OK "Swap" "not configured"
  else
    swap_used=$((swap_total - swap_free))
    swap_percent=$((swap_used * 100 / swap_total))
    percent_status "Swap" "$swap_percent" "$SWAP_WARN" "$SWAP_CRITICAL" "${swap_percent}% used"
  fi

  disk_percent="$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
  inode_percent="$(df -Pi / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
  percent_status "Root disk" "$disk_percent" "$DISK_WARN" "$DISK_CRITICAL" "${disk_percent}% used"
  percent_status "Root inodes" "$inode_percent" "$DISK_WARN" "$DISK_CRITICAL" "${inode_percent}% used"
}

check_systemd() {
  local system_state failed_count failed_names
  if ! command -v systemctl >/dev/null 2>&1; then
    status WARNING "Systemd" "systemctl is unavailable"
    return
  fi

  system_state="$(systemctl is-system-running 2>/dev/null || true)"
  failed_names="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd ', ' - || true)"
  failed_count="$(systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF {count++} END {print count+0}')"
  if (( failed_count > 0 )); then
    status CRITICAL "Systemd" "${system_state:-unknown}; ${failed_count} failed: ${failed_names}"
  elif [[ "$system_state" == "running" ]]; then
    status OK "Systemd" "running; no failed services"
  else
    status WARNING "Systemd" "${system_state:-unknown}; no failed services listed"
  fi
}

check_reboot_and_packages() {
  local pending_count=0 pending_output
  if [[ -f /var/run/reboot-required ]]; then
    status WARNING "Reboot required" "yes"
  else
    status OK "Reboot required" "no"
  fi

  if command -v dpkg >/dev/null 2>&1 && ! dpkg --audit 2>/dev/null | grep -q .; then
    status OK "Package state" "no unfinished dpkg operations"
  elif command -v dpkg >/dev/null 2>&1; then
    status CRITICAL "Package state" "dpkg reports unfinished or broken operations"
  else
    status WARNING "Package state" "dpkg is unavailable"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    if pending_output="$(command_timeout 5 apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | awk '/^Inst / {count++} END {print count+0}')"; then
      pending_count="$pending_output"
    else
      pending_count="unknown"
    fi
    if [[ "$pending_count" == "unknown" ]]; then
      status WARNING "Pending upgrades" "check timed out or failed; package lists were not refreshed"
    elif (( pending_count > 0 )); then
      status WARNING "Pending upgrades" "${pending_count} packages (existing APT cache)"
    else
      status OK "Pending upgrades" "none in existing APT cache"
    fi
  else
    status WARNING "Pending upgrades" "APT is unavailable"
  fi
}

check_ssh() {
  local service port state listening="no"
  service="$(detect_ssh_service)"
  port="$(detect_ssh_port)"
  if command -v systemctl >/dev/null 2>&1; then
    state="$(systemctl is-active "$service.service" 2>/dev/null || true)"
  else
    state="unknown"
  fi
  if command -v ss >/dev/null 2>&1 && ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
    listening="yes"
  fi
  if [[ "$state" == "active" && "$listening" == "yes" ]]; then
    status OK "SSH" "${service}.service active and listening on port ${port}"
  elif [[ "$state" == "active" ]]; then
    status WARNING "SSH" "service active, but port ${port} was not found listening"
  else
    status CRITICAL "SSH" "${service}.service is ${state:-unknown}"
  fi
  SSH_PORT_DETECTED="$port"
  SSH_SERVICE_DETECTED="$service"
}

check_ufw() {
  local first_line
  if ! command -v ufw >/dev/null 2>&1; then
    status WARNING "UFW" "not installed"
    return
  fi
  first_line="$(ufw status 2>/dev/null | head -n 1 || true)"
  if [[ "$first_line" == "Status: active" ]]; then
    status OK "UFW" "active"
  elif [[ "$first_line" == "Status: inactive" ]]; then
    status CRITICAL "UFW" "inactive"
  else
    status WARNING "UFW" "status unavailable (root may be required)"
  fi
}

check_fail2ban() {
  local state jail_status banned
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    status WARNING "Fail2ban SSH" "not installed"
    return
  fi
  state="$(systemctl is-active fail2ban.service 2>/dev/null || true)"
  jail_status="$(command_timeout 3 fail2ban-client status sshd 2>/dev/null || true)"
  banned="$(awk -F: '/Currently banned:/ {gsub(/[[:space:]]/, "", $2); print $2}' <<< "$jail_status")"
  if [[ "$state" == "active" && -n "$banned" ]]; then
    status OK "Fail2ban SSH" "active; ${banned} currently banned"
  elif [[ "$state" == "active" ]]; then
    status WARNING "Fail2ban SSH" "service active, but sshd jail status is unavailable"
  else
    status CRITICAL "Fail2ban SSH" "service is ${state:-unknown}"
  fi
}

check_alloy() {
  local state version
  if ! command -v alloy >/dev/null 2>&1 && ! systemctl list-unit-files alloy.service --no-legend 2>/dev/null | grep -q '^alloy\.service'; then
    info "Alloy" "not installed"
    return
  fi
  state="$(systemctl is-active alloy.service 2>/dev/null || true)"
  version="$(command -v alloy >/dev/null 2>&1 && alloy --version 2>/dev/null | head -n 1 || printf 'version unavailable')"
  if [[ "$state" == "active" ]]; then
    status OK "Alloy" "active; ${version}"
  else
    status WARNING "Alloy" "service is ${state:-unknown}; ${version}"
  fi
}

check_unattended_upgrades() {
  local timer_state service_result
  if ! command -v unattended-upgrade >/dev/null 2>&1; then
    status WARNING "Auto-upgrades" "unattended-upgrades is not installed"
    return
  fi
  timer_state="$(systemctl is-active apt-daily-upgrade.timer 2>/dev/null || true)"
  service_result="$(systemctl show unattended-upgrades.service -p Result --value 2>/dev/null || true)"
  if [[ "$timer_state" == "active" && ( -z "$service_result" || "$service_result" == "success" ) ]]; then
    status OK "Auto-upgrades" "timer active; last result ${service_result:-not recorded}"
  elif [[ "$timer_state" != "active" ]]; then
    status CRITICAL "Auto-upgrades" "apt-daily-upgrade.timer is ${timer_state:-unknown}"
  else
    status WARNING "Auto-upgrades" "timer active; last result ${service_result:-unknown}"
  fi
}

check_journal() {
  local error_count journal_output
  if ! command -v journalctl >/dev/null 2>&1; then
    status WARNING "Journal" "journalctl is unavailable"
    return
  fi
  if journal_output="$(command_timeout 5 journalctl -b -p 0..3 --no-pager -q 2>/dev/null | awk 'NF {count++} END {print count+0}')"; then
    error_count="$journal_output"
  else
    error_count="unknown"
  fi
  if [[ "$error_count" == "unknown" ]]; then
    status WARNING "Journal" "critical-error count timed out or access was denied"
  elif (( error_count > 0 )); then
    status WARNING "Journal" "${error_count} priority 0-3 entries this boot"
  else
    status OK "Journal" "no priority 0-3 entries this boot"
  fi
}

check_public_ports() {
  local ports unexpected="" port expected
  if ! command -v ss >/dev/null 2>&1; then
    status WARNING "Public TCP ports" "ss is unavailable"
    return
  fi
  ports="$(ss -H -ltn 2>/dev/null | awk '$4 ~ /^(0\.0\.0\.0:|\[::\]:|\*:)/ {sub(/^.*:/, "", $4); print $4}' | sort -nu | paste -sd, -)"
  [[ -n "$ports" ]] || ports="none"
  IFS=',' read -ra port_list <<< "$ports"
  for port in "${port_list[@]}"; do
    [[ "$port" == "none" ]] && continue
    expected=false
    for allowed in "${SSH_PORT_DETECTED:-22}" 80 443; do
      [[ "$port" == "$allowed" ]] && expected=true
    done
    $expected || unexpected+="${unexpected:+,}${port}"
  done
  if [[ -n "$unexpected" ]]; then
    status WARNING "Public TCP ports" "${ports}; review additional ports: ${unexpected}"
  else
    status OK "Public TCP ports" "$ports"
  fi
}

quick_report() {
  printf 'Cloud-Setup Server Health Report\n'
  check_identity
  section "Quick health"
  check_resources
  check_systemd
  check_reboot_and_packages
  check_ssh
  check_ufw
  check_fail2ban
  check_alloy
  check_unattended_upgrades
  check_journal
  check_public_ports
}

full_service_details() {
  section "Failed services"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --failed --no-pager --plain 2>&1 || true
  else
    echo "systemctl unavailable"
  fi
}

full_storage_details() {
  section "Filesystems"
  df -hPT 2>&1 || true
  echo
  echo "Inodes:"
  df -hiP 2>&1 || true
}

full_package_details() {
  section "Package details"
  if command -v apt-get >/dev/null 2>&1; then
    echo "Pending packages from the existing APT cache (no repository refresh):"
    command_timeout 15 apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | awk '/^Inst / {print "  - " $2 " " $3}' || echo "  check failed or timed out"
  fi
  if command -v dpkg >/dev/null 2>&1; then
    echo
    echo "dpkg audit:"
    dpkg --audit 2>&1 || true
  fi
  if [[ -f /var/run/reboot-required.pkgs ]]; then
    echo
    echo "Packages requesting a reboot:"
    sed 's/^/  - /' /var/run/reboot-required.pkgs
  fi
}

full_network_details() {
  section "Listening sockets"
  if command -v ss >/dev/null 2>&1; then
    ss -lntup 2>&1 || ss -lntu 2>&1 || true
  else
    echo "ss unavailable"
  fi

  section "UFW rules"
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose 2>&1 || true
  else
    echo "UFW not installed"
  fi
}

full_security_activity() {
  section "Recent SSH authentication failures"
  if command -v journalctl >/dev/null 2>&1; then
    command_timeout 10 journalctl -u "${SSH_SERVICE_DETECTED:-ssh}.service" --since "$SINCE" --no-pager -q 2>/dev/null |
      grep -Ei 'failed password|invalid user|authentication failure|maximum authentication attempts' |
      tail -n 50 || true
  else
    echo "journalctl unavailable"
  fi

  section "Recent Fail2ban bans"
  if [[ -r /var/log/fail2ban.log ]]; then
    grep ' Ban ' /var/log/fail2ban.log | tail -n 50 || true
  elif command -v journalctl >/dev/null 2>&1; then
    command_timeout 10 journalctl -u fail2ban.service --since "$SINCE" --no-pager -q 2>/dev/null | grep ' Ban ' | tail -n 50 || true
  else
    echo "Fail2ban log unavailable"
  fi
}

full_journal_details() {
  section "Critical journal entries"
  if command -v journalctl >/dev/null 2>&1; then
    command_timeout 15 journalctl --since "$SINCE" -p 0..3 -n 100 --no-pager -q 2>&1 || true
  else
    echo "journalctl unavailable"
  fi
}

full_alloy_details() {
  local alloy_bin
  section "Alloy details"
  alloy_bin="$(command -v alloy 2>/dev/null || true)"
  if [[ -z "$alloy_bin" ]]; then
    echo "Alloy binary not installed"
    return
  fi
  "$alloy_bin" --version 2>&1 | head -n 1 || true
  if [[ -f /etc/alloy/config.alloy ]]; then
    echo "Validating /etc/alloy/config.alloy (read-only):"
    command_timeout 20 "$alloy_bin" validate /etc/alloy/config.alloy 2>&1 || true
  else
    echo "Default configuration /etc/alloy/config.alloy not found"
  fi
  systemctl status alloy.service --no-pager -n 20 2>&1 || true
}

full_lynis_details() {
  local latest=""
  section "Latest Lynis report"
  if [[ -d /var/log/cloud-setup/lynis ]]; then
    latest="$(find /var/log/cloud-setup/lynis -maxdepth 1 -type f -name 'lynis-report-*.dat' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR == 1 {$1=""; sub(/^ /, ""); print}' || true)"
  fi
  if [[ -n "$latest" && -r "$latest" ]]; then
    info "Report" "$latest"
    grep -E '^(hardening_index|tests_performed|lynis_version)=' "$latest" 2>/dev/null || true
    echo "Warnings: $(grep -c '^warning\[\]=' "$latest" 2>/dev/null || true)"
    echo "Suggestions: $(grep -c '^suggestion\[\]=' "$latest" 2>/dev/null || true)"
  else
    echo "No readable Cloud-Setup Lynis report found"
  fi
}

full_backup_details() {
  section "Cloud-Setup backups"
  if [[ ! -d /root/cloud-setup-backups ]]; then
    echo "No /root/cloud-setup-backups directory found"
    return
  fi
  du -sh /root/cloud-setup-backups 2>&1 || true
  echo "Newest backup directories:"
  find /root/cloud-setup-backups -mindepth 2 -maxdepth 3 -type d -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null |
    sort -r | head -n 20 || true
}

full_certificate_details() {
  local cert end_date epoch now days found=0 expiring=0
  local -a roots=()
  section "TLS certificates"
  command -v openssl >/dev/null 2>&1 || { echo "openssl unavailable"; return; }
  [[ -d /etc/letsencrypt/live ]] && roots+=(/etc/letsencrypt/live)
  [[ -d /etc/ssl/certs ]] && roots+=(/etc/ssl/certs)
  (( ${#roots[@]} > 0 )) || { echo "No standard certificate directories found"; return; }
  now="$(date +%s)"
  while IFS= read -r -d '' cert; do
    end_date="$(command_timeout 2 openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
    [[ -n "$end_date" ]] || continue
    epoch="$(date -d "$end_date" +%s 2>/dev/null || true)"
    [[ -n "$epoch" ]] || continue
    days=$(((epoch - now) / 86400))
    ((found += 1))
    if (( days <= CERT_WARN_DAYS )); then
      printf '  WARNING: %s expires in %s days (%s)\n' "$cert" "$days" "$end_date"
      ((expiring += 1))
    fi
  done < <(find -L "${roots[@]}" -maxdepth 3 -type f \( -name '*.pem' -o -name '*.crt' \) -print0 2>/dev/null)
  echo "Readable certificates checked: ${found}"
  echo "Expired or expiring within ${CERT_WARN_DAYS} days: ${expiring}"
}

full_report() {
  full_service_details
  full_storage_details
  full_package_details
  full_network_details
  full_security_activity
  full_journal_details
  full_alloy_details
  full_lynis_details
  full_backup_details
  full_certificate_details
}

summary() {
  local overall="HEALTHY"
  if (( CRITICALS > 0 )); then
    overall="CRITICAL"
  elif (( WARNINGS > 0 )); then
    overall="WARNING"
  fi
  section "Summary"
  printf 'Overall: %s (%d warning(s), %d critical finding(s))\n' "$overall" "$WARNINGS" "$CRITICALS"
  echo "This report is read-only. No packages, services, repositories, or configuration were changed."
}

escape_sed_pattern() {
  printf '%s' "$1" | sed 's/[][\/.*^$]/\\&/g'
}

sanitize_report() {
  local source="$1" target="$2" host short_host fqdn user sed_expr=""
  host="$(hostname 2>/dev/null || true)"
  short_host="${host%%.*}"
  fqdn="$(hostname -f 2>/dev/null || true)"
  user="${SUDO_USER:-${USER:-}}"
  for value in "$fqdn" "$host" "$short_host" "$user"; do
    [[ -n "$value" && ${#value} -ge 3 && "$value" != "root" ]] || continue
    sed_expr+="s/$(escape_sed_pattern "$value")/[REDACTED]/g;"
  done
  sed -E "${sed_expr}s/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP-REDACTED]/g;s/([[:xdigit:]]{0,4}:){2,7}[[:xdigit:]]{0,4}/[IPV6-REDACTED]/g" "$source" > "$target"
}

render_terminal() {
  local file="$1"
  if $NO_COLOR || [[ ! -t 1 ]]; then
    cat "$file"
    return
  fi
  sed \
    -e $'s/ OK       / \033[32mOK\033[0m       /' \
    -e $'s/ WARNING  / \033[33mWARNING\033[0m  /' \
    -e $'s/ CRITICAL / \033[31mCRITICAL\033[0m /' \
    -e $'s/^Overall: HEALTHY/Overall: \033[32mHEALTHY\033[0m/' \
    -e $'s/^Overall: WARNING/Overall: \033[33mWARNING\033[0m/' \
    -e $'s/^Overall: CRITICAL/Overall: \033[31mCRITICAL\033[0m/' \
    "$file"
}

save_output() {
  local source="$1" parent
  [[ -n "$OUTPUT_FILE" ]] || return
  [[ "$OUTPUT_FILE" != *$'\n'* && "$OUTPUT_FILE" != *$'\r'* ]] || die "output path must be a single line."
  parent="$(dirname -- "$OUTPUT_FILE")"
  [[ -d "$parent" ]] || die "output directory does not exist: $parent"
  install -m 0600 "$source" "$OUTPUT_FILE"
  echo "Report saved with mode 0600: $OUTPUT_FILE" >&2
}

main() {
  local display_file exit_code=0 sanitized_file=""
  parse_arguments "$@"
  [[ -n "$MODE" ]] || interactive_menu
  validate_settings

  umask 077
  REPORT_FILE="$(mktemp)"
  {
    quick_report
    [[ "$MODE" != "full" ]] || full_report
    summary
  } > "$REPORT_FILE" 2>&1

  display_file="$REPORT_FILE"
  if $SANITIZE; then
    sanitized_file="$(mktemp)"
    sanitize_report "$REPORT_FILE" "$sanitized_file"
    display_file="$sanitized_file"
  fi

  render_terminal "$display_file"
  save_output "$display_file"
  [[ -z "$sanitized_file" ]] || rm -f -- "$sanitized_file"

  if (( CRITICALS > 0 )); then
    exit_code=2
  elif (( WARNINGS > 0 )); then
    exit_code=1
  fi
  return "$exit_code"
}

main "$@"
