#!/usr/bin/env bash

# Safely detect and update an existing Grafana Alloy installation.
# Supported update paths: APT/dpkg, DNF/YUM/RPM, and Zypper/RPM packages.
# Standalone binaries and containers are detected and reported, but never
# replaced automatically because their original deployment settings are unknown.

set -Eeuo pipefail

BACKUP_BASE="/root/cloud-setup-backups"
ASSUME_YES=false
CHECK_ONLY=false

usage() {
  cat <<'EOF'
Usage: sudo ./update-alloy.sh [--check] [--yes]

  no option  Show an interactive Update/Check menu
  --check  Refresh repository metadata and check; do not update or restart Alloy
  --yes    Update without the confirmation prompt
  -h       Show this help
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=true ;;
    --yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $arg" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "run this script as root (sudo)."

if (( $# == 0 )); then
  cat <<'EOF'
What do you want to do?
  1) Check for and install an Alloy update
  2) Check for an Alloy update only
EOF
  read -r -p "Choose [1-2]: " choice
  case "$choice" in
    1) ASSUME_YES=true ;;
    2) CHECK_ONLY=true ;;
    *) die "invalid choice; enter 1 or 2." ;;
  esac
fi

ALLOY_BIN="$(command -v alloy 2>/dev/null || true)"
PACKAGE_MANAGER=""
INSTALL_METHOD=""

if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' alloy 2>/dev/null | grep -q 'install ok installed'; then
  INSTALL_METHOD="Debian package (alloy)"
  PACKAGE_MANAGER="apt"
elif command -v rpm >/dev/null 2>&1 && rpm -q alloy >/dev/null 2>&1; then
  INSTALL_METHOD="RPM package (alloy)"
  if command -v dnf >/dev/null 2>&1; then
    PACKAGE_MANAGER="dnf"
  elif command -v zypper >/dev/null 2>&1; then
    PACKAGE_MANAGER="zypper"
  elif command -v yum >/dev/null 2>&1; then
    PACKAGE_MANAGER="yum"
  else
    die "Alloy is RPM-managed, but DNF, Zypper, and YUM are unavailable."
  fi
elif [[ -n "$ALLOY_BIN" ]]; then
  INSTALL_METHOD="standalone or otherwise unmanaged binary ($ALLOY_BIN)"
elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files alloy.service --no-legend 2>/dev/null | grep -q '^alloy.service'; then
  INSTALL_METHOD="custom systemd deployment"
elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Image}} {{.Names}}' 2>/dev/null | grep -qi alloy; then
  INSTALL_METHOD="Docker container"
elif command -v podman >/dev/null 2>&1 && podman ps -a --format '{{.Image}} {{.Names}}' 2>/dev/null | grep -qi alloy; then
  INSTALL_METHOD="Podman container"
else
  die "no Alloy installation was found. This updater does not perform first-time installs."
fi

echo "Detected installation: $INSTALL_METHOD"
if [[ -n "$ALLOY_BIN" ]]; then
  echo "Binary: $ALLOY_BIN"
  echo "Current version: $($ALLOY_BIN --version 2>/dev/null | head -n 1 || echo unknown)"
fi

if [[ -z "$PACKAGE_MANAGER" ]]; then
  cat >&2 <<EOF
Automatic update stopped: this installation is not owned by a supported system package manager.
Update it through the original deployment method so its flags, mounts, configuration, and rollback path are preserved.
EOF
  exit 2
fi

echo "Package manager used for updates: $PACKAGE_MANAGER"

case "$PACKAGE_MANAGER" in
  apt)
    CURRENT_VERSION="$(dpkg-query -W -f='${Version}' alloy)"
    apt-get update
    CANDIDATE_VERSION="$(apt-cache policy alloy | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$CANDIDATE_VERSION" && "$CANDIDATE_VERSION" != "(none)" ]] || die "no Alloy candidate is available from configured APT repositories."
    ;;
  dnf) CURRENT_VERSION="$(rpm -q --qf '%{VERSION}-%{RELEASE}' alloy)"; CANDIDATE_VERSION="$(dnf -q --refresh repoquery --latest-limit 1 --qf '%{version}-%{release}' alloy 2>/dev/null | tail -n 1)" ;;
  yum) CURRENT_VERSION="$(rpm -q --qf '%{VERSION}-%{RELEASE}' alloy)"; CANDIDATE_VERSION="$(yum -q --refresh list available alloy 2>/dev/null | awk '$1 ~ /^alloy\./ {print $2; exit}')" ;;
  zypper) CURRENT_VERSION="$(rpm -q --qf '%{VERSION}-%{RELEASE}' alloy)"; CANDIDATE_VERSION="$(zypper --non-interactive --gpg-auto-import-keys refresh >/dev/null; zypper --no-refresh search -s --match-exact alloy | awk -F'|' '$2 ~ /alloy/ {gsub(/ /,"",$4); print $4}' | sort -V | tail -n 1)" ;;
esac

echo "Installed package version: $CURRENT_VERSION"
echo "Repository candidate: ${CANDIDATE_VERSION:-unknown}"

if [[ "$PACKAGE_MANAGER" == apt ]] && dpkg --compare-versions "$CURRENT_VERSION" ge "$CANDIDATE_VERSION"; then
  echo "Alloy is already up to date."
  exit 0
elif [[ "$PACKAGE_MANAGER" != apt && -n "$CANDIDATE_VERSION" && "$CURRENT_VERSION" == "$CANDIDATE_VERSION" ]]; then
  echo "Alloy is already up to date."
  exit 0
fi

$CHECK_ONLY && { echo "An update is available; Alloy was not updated or restarted."; exit 10; }

if ! $ASSUME_YES; then
  read -r -p "Update Alloy using $PACKAGE_MANAGER now? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Update cancelled."; exit 0; }
fi

CONFIG_FILE="/etc/alloy/config.alloy"
if [[ -x "$ALLOY_BIN" && -f "$CONFIG_FILE" ]]; then
  echo "Validating the current Alloy configuration..."
  "$ALLOY_BIN" validate "$CONFIG_FILE"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="$BACKUP_BASE/$timestamp/alloy"
  install -d -m 0700 "$backup_dir"
  cp -a "$CONFIG_FILE" "$backup_dir/config.alloy"
  echo "Configuration backup: $backup_dir/config.alloy"
fi

was_active=false
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet alloy.service; then was_active=true; fi

echo "Updating Alloy..."
case "$PACKAGE_MANAGER" in
  apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade alloy ;;
  dnf) dnf -y upgrade alloy ;;
  yum) yum -y update alloy ;;
  zypper) zypper --non-interactive update alloy ;;
esac

ALLOY_BIN="$(command -v alloy 2>/dev/null || true)"
[[ -n "$ALLOY_BIN" ]] || die "the package update completed but the Alloy binary is unavailable."
if [[ -f "$CONFIG_FILE" ]]; then "$ALLOY_BIN" validate "$CONFIG_FILE"; fi

if $was_active; then
  systemctl restart alloy.service
  if ! systemctl is-active --quiet alloy.service; then
    journalctl -u alloy.service -n 50 --no-pager >&2 || true
    die "Alloy did not become active after the update. The configuration backup is shown above."
  fi
fi

echo "Update complete: $($ALLOY_BIN --version 2>/dev/null | head -n 1 || echo 'version unavailable')"
