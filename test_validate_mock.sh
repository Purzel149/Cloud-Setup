#!/bin/bash
# Re-define functions directly but without systemd-analyze
validate_no_newline() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

validate_oncalendar() {
  local value="$1"
  if [[ -z "$value" ]] || ! validate_no_newline "$value"; then
    return 1
  fi

  # Fallback without systemd-analyze: at least ensure a simple date/time-like pattern.
  [[ "$value" =~ ^[0-9\*]+-[0-9\*]+-[0-9\*]+[[:space:]]+[0-9\*]+:[0-9\*]+$ ]]
}

value="*-*-* 00:00"$'\n'"ExecStart=bad"
if validate_oncalendar "$value"; then
  echo "VULNERABLE (fallback)"
else
  echo "SAFE (fallback)"
fi

value="*-*-* 00:00"
if validate_oncalendar "$value"; then
  echo "VALID_SAFE (fallback)"
else
  echo "VALID_FAILED (fallback)"
fi
