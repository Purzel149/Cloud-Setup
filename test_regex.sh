#!/usr/bin/env bash

# Test MAXRETRY
MAXRETRY="5"
if ! [[ "$MAXRETRY" =~ ^[0-9]+$ ]]; then
  echo "MAXRETRY failed"
fi

# Test FINDTIME
FINDTIME="10m"
if ! [[ "$FINDTIME" =~ ^[0-9]+[a-zA-Z]*$ ]]; then
  echo "FINDTIME failed"
fi

# Test BANTIME
BANTIME="1h"
if ! [[ "$BANTIME" =~ ^-?[0-9]+[a-zA-Z]*$ ]]; then
  echo "BANTIME failed"
fi

# Test SSH_PORT
SSH_PORT="ssh"
if ! [[ "$SSH_PORT" =~ ^[a-zA-Z0-9]+$ ]]; then
  echo "SSH_PORT failed"
fi

echo "All tests passed (if no failures above)"
