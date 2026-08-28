#!/bin/bash
# orp_setup_gpg.sh — Generate/rotate persistent GPG key (30-day)
# Alpine Linux compatible
set -euo pipefail

GPG_EMAIL="${OPERATOR_GPG_EMAIL:-marcofernandez0204@gmail.com}"
GPG_NAME="${LGU_SIGNER_NAME:-MARCO C. FERNANDEZ}"
KEY_DIR="$HOME/.orp/gpg"
VALID_DAYS=30

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# Find pinentry binary
PINENTRY=$(command -v pinentry 2>/dev/null \
    || command -v pinentry-curses 2>/dev/null \
    || echo "/usr/bin/pinentry")

mkdir -p "$HOME/.gnupg"
chmod 700 "$HOME/.gnupg"
cat > "$HOME/.gnupg/gpg-agent.conf" << EOF
pinentry-program $PINENTRY
default-cache-ttl 86400
max-cache-ttl 86400
EOF
chmod 600 "$HOME/.gnupg/gpg-agent.conf"

gpgconf --kill gpg-agent 2>/dev/null || true
sleep 1

# Remove previous key for this email
PREV=$(gpg --list-secret-keys --with-colons "$GPG_EMAIL" 2>/dev/null \
       | awk -F: '/^fpr/{print $10; exit}' || true)
[ -n "$PREV" ] && \
    gpg --batch --yes --delete-secret-and-public-key "$PREV" \
    2>/dev/null || true

# Generate new key
SPEC=$(mktemp)
cat > "$SPEC" << EOF
Key-Type: EDDSA
Key-Curve: ed25519
Key-Usage: sign,auth
Name-Real: $GPG_NAME
Name-Email: $GPG_EMAIL
Expire-Date: ${VALID_DAYS}d
%no-protection
%commit
EOF

gpg --batch --generate-key "$SPEC" 2>&1
rm -f "$SPEC"

KEY_ID=$(gpg --list-secret-keys --with-colons "$GPG_EMAIL" \
         | awk -F: '/^sec/{print $5; exit}')

echo "$KEY_ID" > "$KEY_DIR/current_key_id.txt"
python3 -c "
import datetime
print((datetime.date.today()+datetime.timedelta($VALID_DAYS)).isoformat())
" > "$KEY_DIR/expiry.txt"

git config --global user.signingkey "$KEY_ID"
git config --global commit.gpgsign  true
git config --global gpg.program     "$(command -v gpg)"

echo ""
echo "══════════════════════════════════════════════════"
echo "  ORP GPG KEY ROTATED"
echo "══════════════════════════════════════════════════"
echo ""
echo "  Key ID  : $KEY_ID"
echo "  Expires : $(cat "$KEY_DIR/expiry.txt")"
echo ""
echo "  Public key (add to GitHub Settings → GPG keys):"
echo ""
gpg --armor --export "$GPG_EMAIL"
echo ""
echo "  → https://github.com/settings/keys  (GPG Keys tab)"
echo "  1. Delete the old GPG key"
echo "  2. Add this new key"
echo ""
