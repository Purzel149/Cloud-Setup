#!/bin/bash
systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || echo "Warnung: SSH-Service konnte nicht neu geladen/gestartet werden."
