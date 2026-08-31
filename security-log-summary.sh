#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only Debian/Ubuntu security-log summary.
# It never installs packages, restarts services, changes configuration, or modifies logs.

SINCE="24 hours ago"
OUTPUT_FILE=""
SANITIZE=false
NO_COLOR=false
WARNINGS=0
CRITICALS=0
REPORT_FILE=""
SSH_EVENTS_FILE=""
FAIL2BAN_EVENTS_FILE=""
JOURNAL_CRITICAL_FILE=""
JOURNAL_WARNING_FILE=""
SANITIZED_FILE=""

usage() {
  cat <<'EOF'
Usage: ./security-log-summary.sh [OPTIONS]

Summarize recent SSH authentication failures, Fail2ban bans, and severe
system-journal events. The report is read-only and is always printed to stdout.

Options:
  --since TIME      Log window accepted by date(1) (default: "24 hours ago")
  --output FILE     Also save a private plain-text report (mode 0600)
  --sanitize        Redact hostnames, local user names, and IP addresses
  --no-color        Disable colors in terminal output
  -h, --help        Show this help

Examples:
  sudo ./security-log-summary.sh
  sudo ./security-log-summary.sh --since "7 days ago" --output /root/security-log-summary.txt
  sudo ./security-log-summary.sh --sanitize --output ./security-log-summary.txt

Exit codes:
  0  No findings
  1  One or more warnings
  2  One or more critical findings
EOF
}

die() {
  echo "Error: $*" >&2
  exit 2
}

cleanup() {
  local file
  for file in "$REPORT_FILE" "$SSH_EVENTS_FILE" "$FAIL2BAN_EVENTS_FILE" "$JOURNAL_CRITICAL_FILE" "$JOURNAL_WARNING_FILE" "$SANITIZED_FILE"; do
    [[ -z "$file" ]] || rm -f -- "$file"
  done
}

command_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$seconds" "$@"
  else
    "$@"
  fi
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --since)
        shift
        (( $# > 0 )) || die "--since requires a time expression."
        SINCE="$1"
        ;;
      --output)
        shift
        (( $# > 0 )) || die "--output requires a file path."
        OUTPUT_FILE="$1"
        ;;
      --sanitize) SANITIZE=true ;;
      --no-color) NO_COLOR=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done

  [[ -n "$SINCE" && "$SINCE" != *$'\n'* && "$SINCE" != *$'\r'* ]] || die "--since must be a non-empty single-line value."
  date --date="$SINCE" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1 || die "--since is not understood by date: $SINCE"
  [[ "$OUTPUT_FILE" != *$'\n'* && "$OUTPUT_FILE" != *$'\r'* ]] || die "output path must be a single line."
}

section() {
  printf '\n== %s ==\n' "$1"
}

finding() {
  local severity="$1" label="$2" detail="$3"
  case "$severity" in
    WARNING) ((WARNINGS += 1)) ;;
    CRITICAL) ((CRITICALS += 1)) ;;
  esac
  printf '%-8s %s: %s\n' "$severity" "$label" "$detail"
}

info() {
  printf '%-8s %s: %s\n' "INFO" "$1" "$2"
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

print_samples() {
  local file="$1" count="$2"
  if (( count == 0 )); then
    echo "No matching events."
  else
    echo "Newest ${count} matching event(s):"
    tail -n 20 "$file" | sed 's/^/  /'
  fi
}

collect_ssh_failures() {
  local service raw_file count
  section "SSH authentication failures"
  if ! command -v journalctl >/dev/null 2>&1; then
    finding WARNING "SSH log" "journalctl is unavailable"
    return
  fi

  service="$(detect_ssh_service)"
  raw_file="$(mktemp)"
  if ! command_timeout 15 journalctl -u "${service}.service" --since "$SINCE" --no-pager -q > "$raw_file" 2>/dev/null; then
    finding WARNING "SSH log" "could not read ${service}.service journal entries (root may be required)"
    rm -f -- "$raw_file"
    return
  fi
  grep -Ei 'failed password|invalid user|authentication failure|maximum authentication attempts' "$raw_file" > "$SSH_EVENTS_FILE" || true
  rm -f -- "$raw_file"
  count="$(wc -l < "$SSH_EVENTS_FILE")"
  if (( count > 0 )); then
    finding WARNING "SSH log" "${count} authentication failure event(s) since ${SINCE}"
  else
    info "SSH log" "no authentication failure events since ${SINCE}"
  fi
  print_samples "$SSH_EVENTS_FILE" "$count"
}

collect_fail2ban_bans() {
  local count cutoff raw_file
  section "Fail2ban bans"
  cutoff="$(date --date="$SINCE" '+%Y-%m-%d %H:%M:%S')"
  if [[ -r /var/log/fail2ban.log ]]; then
    awk -v cutoff="$cutoff" 'substr($0, 1, 19) >= cutoff && index($0, " Ban ") { print }' /var/log/fail2ban.log > "$FAIL2BAN_EVENTS_FILE" || true
  elif command -v journalctl >/dev/null 2>&1; then
    raw_file="$(mktemp)"
    if ! command_timeout 15 journalctl -u fail2ban.service --since "$SINCE" --no-pager -q > "$raw_file" 2>/dev/null; then
      finding WARNING "Fail2ban log" "could not read Fail2ban journal entries (root may be required)"
      rm -f -- "$raw_file"
      return
    fi
    grep ' Ban ' "$raw_file" > "$FAIL2BAN_EVENTS_FILE" || true
    rm -f -- "$raw_file"
  else
    finding WARNING "Fail2ban log" "no readable Fail2ban log source"
    return
  fi
  count="$(wc -l < "$FAIL2BAN_EVENTS_FILE")"
  if (( count > 0 )); then
    finding WARNING "Fail2ban log" "${count} ban event(s) since ${SINCE}"
  else
    info "Fail2ban log" "no ban events since ${SINCE}"
  fi
  print_samples "$FAIL2BAN_EVENTS_FILE" "$count"
}

collect_journal_events() {
  local raw_file critical_count warning_count
  section "Severe system journal events"
  if ! command -v journalctl >/dev/null 2>&1; then
    finding WARNING "System journal" "journalctl is unavailable"
    return
  fi

  raw_file="$(mktemp)"
  if ! command_timeout 20 journalctl --since "$SINCE" -p 0..3 --no-pager -q > "$raw_file" 2>/dev/null; then
    finding WARNING "System journal" "could not read journal entries (root may be required)"
    rm -f -- "$raw_file"
    return
  fi
  cat "$raw_file" > "$JOURNAL_WARNING_FILE"
  command_timeout 20 journalctl --since "$SINCE" -p 0..2 --no-pager -q > "$JOURNAL_CRITICAL_FILE" 2>/dev/null || true
  warning_count="$(wc -l < "$JOURNAL_WARNING_FILE")"
  critical_count="$(wc -l < "$JOURNAL_CRITICAL_FILE")"

  if (( critical_count > 0 )); then
    finding CRITICAL "System journal" "${critical_count} priority 0-2 event(s) since ${SINCE}"
  fi
  if (( warning_count > critical_count )); then
    finding WARNING "System journal" "$((warning_count - critical_count)) priority 3 event(s) since ${SINCE}"
  elif (( warning_count == 0 )); then
    info "System journal" "no priority 0-3 events since ${SINCE}"
  fi
  echo "Newest priority 0-3 event(s):"
  if (( warning_count == 0 )); then
    echo "  No matching events."
  else
    tail -n 20 "$JOURNAL_WARNING_FILE" | sed 's/^/  /'
  fi
  rm -f -- "$raw_file"
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
  echo "This report is read-only. No packages, services, repositories, configuration, or logs were changed."
}

escape_sed_pattern() {
  printf '%s' "$1" | sed 's/[][\\/.*^$]/\\&/g'
}

sanitize_report() {
  local source="$1" target="$2" host short_host fqdn user sed_expr="" value
  host="$(hostname 2>/dev/null || true)"
  short_host="${host%%.*}"
  fqdn="$(hostname -f 2>/dev/null || true)"
  user="${SUDO_USER:-${USER:-}}"
  for value in "$fqdn" "$host" "$short_host" "$user"; do
    [[ -n "$value" && ${#value} -ge 3 && "$value" != "root" ]] || continue
    sed_expr+="s/$(escape_sed_pattern "$value")/[REDACTED]/g;"
  done
  sed -E "${sed_expr}s/([0-2][0-9]):([0-5][0-9]):([0-5][0-9])/__TIME_\1_\2_\3__/g;s/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP-REDACTED]/g;s/([[:xdigit:]]{0,4}:){2,7}[[:xdigit:]]{0,4}/[IPV6-REDACTED]/g;s/__TIME_([0-2][0-9])_([0-5][0-9])_([0-5][0-9])__/\1:\2:\3/g" "$source" > "$target"
}

render_terminal() {
  local file="$1"
  if $NO_COLOR || [[ ! -t 1 ]]; then
    cat "$file"
    return
  fi
  sed \
    -e $'s/^WARNING /\\033[33mWARNING\\033[0m /' \
    -e $'s/^CRITICAL /\\033[31mCRITICAL\\033[0m /' \
    -e $'s/^INFO /\\033[36mINFO\\033[0m /' \
    -e $'s/^Overall: HEALTHY/Overall: \\033[32mHEALTHY\\033[0m/' \
    -e $'s/^Overall: WARNING/Overall: \\033[33mWARNING\\033[0m/' \
    -e $'s/^Overall: CRITICAL/Overall: \\033[31mCRITICAL\\033[0m/' \
    "$file"
}

save_output() {
  local source="$1" parent
  [[ -n "$OUTPUT_FILE" ]] || return
  parent="$(dirname -- "$OUTPUT_FILE")"
  [[ -d "$parent" ]] || die "output directory does not exist: $parent"
  install -m 0600 "$source" "$OUTPUT_FILE"
  echo "Report saved with mode 0600: $OUTPUT_FILE" >&2
}

main() {
  local display_file exit_code=0
  parse_arguments "$@"
  umask 077
  REPORT_FILE="$(mktemp)"
  SSH_EVENTS_FILE="$(mktemp)"
  FAIL2BAN_EVENTS_FILE="$(mktemp)"
  JOURNAL_CRITICAL_FILE="$(mktemp)"
  JOURNAL_WARNING_FILE="$(mktemp)"
  trap cleanup EXIT

  {
    echo "Cloud-Setup Security Log Summary"
    echo "Window: ${SINCE}"
    collect_ssh_failures
    collect_fail2ban_bans
    collect_journal_events
    summary
  } > "$REPORT_FILE" 2>&1

  display_file="$REPORT_FILE"
  if $SANITIZE; then
    SANITIZED_FILE="$(mktemp)"
    sanitize_report "$REPORT_FILE" "$SANITIZED_FILE"
    display_file="$SANITIZED_FILE"
  fi
  render_terminal "$display_file"
  save_output "$display_file"
  [[ -z "$SANITIZED_FILE" ]] || rm -f -- "$SANITIZED_FILE"
  SANITIZED_FILE=""

  if (( CRITICALS > 0 )); then
    exit_code=2
  elif (( WARNINGS > 0 )); then
    exit_code=1
  fi
  return "$exit_code"
}

main "$@"
