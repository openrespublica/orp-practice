#!/bin/bash
# orp_setup_ssh.sh — Generate/rotate persistent SSH key (30-day)
# Alpine Linux compatible
set -euo pipefail

KEY_DIR="$HOME/.orp/ssh"
KEY_FILE="$KEY_DIR/orp_engine_ed25519"
VALID_DAYS=30

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

[ -f "$KEY_FILE" ] && rm -f "$KEY_FILE" "$KEY_FILE.pub"

ssh-keygen -t ed25519 \
    -C "ORP Engine - $(hostname) - $(date +%Y-%m-%d)" \
    -f "$KEY_FILE" \
    -N ""

chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"

python3 -c "
import datetime
print((datetime.date.today()+datetime.timedelta($VALID_DAYS)).isoformat())
" > "$KEY_DIR/expiry.txt"

echo ""
echo "══════════════════════════════════════════════════"
echo "  ORP SSH KEY ROTATED"
echo "══════════════════════════════════════════════════"
echo ""
echo "  Public key:"
cat "$KEY_FILE.pub"
echo ""
echo "  Fingerprint : $(ssh-keygen -lf "$KEY_FILE.pub" | awk '{print $2}')"
echo "  Expires     : $(cat "$KEY_DIR/expiry.txt")"
echo ""
echo "  → https://github.com/settings/keys"
echo "  1. Delete the old ORP Engine key"
echo "  2. Add this new key (Authentication Key)"
echo ""
