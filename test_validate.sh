#!/bin/bash
# Re-define functions directly to be safe
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

value="*-*-* 00:00"$'\n'"ExecStart=bad"
if validate_oncalendar "$value"; then
  echo "VULNERABLE"
else
  echo "SAFE"
fi

value="*-*-* 00:00"
if validate_oncalendar "$value"; then
  echo "VALID_SAFE"
else
  echo "VALID_FAILED"
fi
