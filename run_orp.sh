#!/bin/bash
# run_orp.sh — ORP Engine Plain Terminal Launcher
# ─────────────────────────────────────────────────────────────────
# Boot sequence:
# 1.  Load .env and ~/.identity/db_secrets.env
# 2.  Detect /dev/shm availability
# 3.  Generate ephemeral Ed25519 session keys in RAM (or /tmp)
# 4.  Start immudb vault on :3322 (or attach if already running)
# 5.  Configure git signing with the session GPG key
# 6.  Start/reload Nginx mTLS gateway
# 7.  Display session SSH and GPG public keys + fingerprint
# 8.  Wait for operator to paste SSH key to GitHub
# 9.  Verify GitHub SSH auth — ABORT if it fails
# 10. Launch Gunicorn (exec — replaces this shell)
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/_orp_core.sh"

trap orp_cleanup EXIT INT TERM

# ── Boot sequence ─────────────────────────────────────────────────
orp_load_env
orp_forge_identity
orp_start_vault
orp_configure_git
orp_refresh_gateway

# ── Session check-in display ─────────────────────────────────────
clear
cat <<EOF
╔═══════════════════════════════════════════════════════════════╗
║         OpenResPublica Engine — SESSION CHECK-IN              ║
╚═══════════════════════════════════════════════════════════════╝

  Identity : $LGU_SIGNER_NAME
  GPG Key  : $KEY_ID
  SSH Sock : $SSH_AUTH_SOCK
  Key store: $ORP_SHM_BASE ($([ "$ORP_SHM_BASE" = "/dev/shm" ] && echo "RAM ✅" || echo "⚠ storage — not RAM"))

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SESSION SSH PUBLIC KEY  (paste this into GitHub Settings)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$(cat "$ORP_IDENTITY_DIR/session.pub")

  Fingerprint: $SESSION_KEY_FP
  ↑ Verify this matches what GitHub shows after you add the key.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SESSION GPG PUBLIC KEY  (for commit verification on GitHub)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$(cat "$ORP_IDENTITY_DIR/session.gpg")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ACTION REQUIRED (once per session)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Copy the SSH PUBLIC KEY shown above.

  2. Open: https://github.com/settings/keys
     → Delete any stale "ORP Engine" key from a previous session.
     → Click "New SSH Key":
         Title:    ORP Engine - $HOSTNAME - $(date +%Y-%m-%d)
         Key type: Authentication Key
         Key:      [paste]
     → Click "Add SSH Key"

  3. After saving, confirm GitHub shows fingerprint:
       $SESSION_KEY_FP

  ⚠️  This key is EPHEMERAL — wiped on exit. Repeat every session.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# ── Clipboard helper (Termux only) ───────────────────────────────
if command -v termux-clipboard-set >/dev/null 2>&1; then
    cat "$ORP_IDENTITY_DIR/session.pub" | termux-clipboard-set
    termux-toast "SSH public key copied to clipboard" 2>/dev/null || true
    printf ' [✔] SSH key copied to clipboard (Termux).\n\n'
fi

read -rp ' Press [ENTER] after adding the SSH key to GitHub... '

# ── Gate: verify GitHub accepts the key before starting Gunicorn ─
# This catches a wrong/stale key interactively rather than letting
# the engine start and fail silently 30 seconds into the first sync.
orp_verify_github_ssh || true

printf '\n'
printf '╔═══════════════════════════════════════════════════════════════╗\n'
printf '║         Starting ORP Engine via Gunicorn...                  ║\n'
printf '╚═══════════════════════════════════════════════════════════════╝\n\n'
printf ' Portal: https://localhost:9443\n'
printf ' Auth  : Client certificate required (operator_01.p12)\n'
printf ' Stop  : Press Ctrl+C\n\n'

orp_launch_engine
