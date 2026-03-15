#!/bin/bash
# Optional: Allow MacChill to toggle Low Power Mode without password prompts.
# This adds a sudoers entry so `pmset` can be run without a password.
#
# Run with: sudo ./setup-sudoers.sh
#
# Without this, MacChill will use an AppleScript dialog to ask for your
# admin password the first time it toggles Low Power Mode.

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/macchill"
CURRENT_USER="${SUDO_USER:-$USER}"

echo "Setting up passwordless pmset for user: $CURRENT_USER"

cat > "$SUDOERS_FILE" << EOF
# Allow MacChill to toggle Low Power Mode without password
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/pmset -a lowpowermode 0
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/pmset -a lowpowermode 1
EOF

chmod 0440 "$SUDOERS_FILE"

echo "Done! MacChill can now toggle Low Power Mode without a password prompt."
echo "To remove: sudo rm $SUDOERS_FILE"
