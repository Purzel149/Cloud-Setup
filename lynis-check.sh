#!/usr/bin/env bash
set -euo pipefail

# Lynis security audit for Debian/Ubuntu
# - Installs lynis if missing
# - Runs a read-only system audit
# - Stores timestamped reports under /var/log/cloud-setup/lynis
# - Prints hardening score, warnings and suggestions summary

REPORT_DIR="${REPORT_DIR:-/var/log/cloud-setup/lynis}"
AUDITOR="${AUDITOR:-Cloud-Setup}"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen: sudo bash $0"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Dieses Skript benötigt ein APT-basiertes System (Debian/Ubuntu)."
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
    echo "Nicht unterstützte Distribution: ${PRETTY_NAME:-unbekannt}"
    echo "Unterstützt: Debian, Ubuntu und Debian-Derivate mit APT."
    exit 1
  fi
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
report_file="${REPORT_DIR}/lynis-report-${timestamp}.dat"
log_file="${REPORT_DIR}/lynis-log-${timestamp}.log"

print_report_values() {
  local label="$1"
  local key="$2"
  local limit="${3:-10}"
  local count

  count="$(grep -c "^${key}\\[\\]=" "$report_file" 2>/dev/null || true)"
  echo "${label}: ${count}"

  if [[ "$count" -gt 0 ]]; then
    grep "^${key}\\[\\]=" "$report_file" |
      sed "s/^${key}\\[\\]=//" |
      cut -d'|' -f1 |
      head -n "$limit" |
      sed 's/^/  - /'

    if [[ "$count" -gt "$limit" ]]; then
      echo "  - ... weitere Einträge im Report"
    fi
  fi
}

echo "[1/4] Lynis installieren falls nötig..."
if ! command -v lynis >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y lynis
else
  echo "Lynis ist bereits installiert: $(command -v lynis)"
fi

echo "[2/4] Report-Verzeichnis vorbereiten..."
# Security validation for REPORT_DIR to prevent arbitrary permission changes
if [[ ! "$REPORT_DIR" = /* ]]; then
  echo "Fehler: REPORT_DIR muss ein absoluter Pfad sein."
  exit 1
fi

if [[ "$REPORT_DIR" == *..* ]]; then
  echo "Fehler: REPORT_DIR darf keine '..' enthalten."
  exit 1
fi

# Resolve canonical path to be absolutely sure
REAL_DIR="$(readlink -m "$REPORT_DIR")"

# Must be inside /var/log or /tmp, and cannot be exactly /var/log, /tmp, or /
if [[ "$REAL_DIR" != /var/log/* && "$REAL_DIR" != /tmp/* ]]; then
  echo "Fehler: REPORT_DIR muss ein Unterverzeichnis von /var/log oder /tmp sein."
  exit 1
fi

REPORT_DIR="$REAL_DIR"

mkdir -p "$REPORT_DIR"
chmod 750 "$REPORT_DIR"

echo "[3/4] Lynis Audit ausführen..."
set +e
lynis audit system --quick --no-colors --auditor "$AUDITOR" --logfile "$log_file" --report-file "$report_file"
lynis_exit=$?
set -e

if [[ ! -s "$report_file" ]]; then
  echo "Lynis hat keinen Report erzeugt. Logdatei prüfen: ${log_file}"
  exit 1
fi

echo "[4/4] Ergebnis zusammenfassen..."
hardening_index="$(grep '^hardening_index=' "$report_file" 2>/dev/null | cut -d= -f2 || true)"
tests_performed="$(grep '^tests_performed=' "$report_file" 2>/dev/null | cut -d= -f2 || true)"
lynis_version="$(grep '^lynis_version=' "$report_file" 2>/dev/null | cut -d= -f2 || true)"

echo
echo "Fertig."
echo "Lynis-Version: ${lynis_version:-unbekannt}"
echo "Hardening-Score: ${hardening_index:-unbekannt}"
echo "Tests durchgeführt: ${tests_performed:-unbekannt}"
echo "Exit-Code: ${lynis_exit}"
echo
print_report_values "Warnungen" "warning" 10
echo
print_report_values "Vorschläge" "suggestion" 10
echo
echo "Report: ${report_file}"
echo "Log: ${log_file}"
echo
echo "Hinweis: Dieses Skript ändert keine Security-Einstellungen automatisch."
