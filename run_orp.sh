#!/bin/bash
# run_orp.sh — ORP Engine Plain Terminal Launcher (Alpine proot-distro)
# ─────────────────────────────────────────────────────────────────
# Starts the ORP Engine in a plain terminal (no gum required).
# Compatible with Ubuntu WSL2, Termux proot-distro Ubuntu, and
# Termux proot-distro Alpine.
#
# Alpine prerequisites (run once as root inside proot):
# apk add bash gnupg openssh nginx procps
# # immudb: download the static/musl binary from
# # https://github.com/codenotary/immudb/releases
# # and place it at ~/bin/immudb (chmod +x)
#
# Boot sequence:
# 1. Load .env and ~/.identity/db_secrets.env
# 2. Detect /dev/shm availability (warn if not a real tmpfs)
# 3. Generate ephemeral Ed25519 session keys in RAM (or /tmp)
# 4. Start immudb vault on :3322 (or attach if already running)
# 5. Configure git signing with the session GPG key
# 6. Start/reload Nginx mTLS gateway
# 7. Display session SSH and GPG public keys
# 8. Wait for operator to paste SSH key to GitHub
# 9. Launch Gunicorn (exec — replaces this shell)
#
# On exit (Ctrl+C or Lock Engine):
# → orp_cleanup() wipes the SHM directory
# → All ephemeral keys are permanently destroyed
# ─────────────────────────────────────────────────────────────────
#
# NOTE on shebang: Alpine does not install bash at /bin/bash by
# default. "#!/usr/bin/env bash" locates whichever bash is on
# PATH (typically /usr/bin/bash after: apk add bash).
# If you are certain bash is always at /bin/bash on your target,
# you may revert to #!/bin/bash.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

# BASH_SOURCE[0] is bash-specific and requires bash (not sh/ash).
# The #!/usr/bin/env bash shebang guarantees we are in bash here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/_orp_core.sh"

# Register cleanup trap — fires on exit, Ctrl+C (INT), and TERM.
trap orp_cleanup EXIT INT TERM

# ── Boot sequence ─────────────────────────────────────────────────
orp_load_env # also calls _orp_shm_init, sets ORP_SHM_BASE
orp_forge_identity
orp_start_vault
orp_configure_git
orp_refresh_gateway

# ── Session check-in display ─────────────────────────────────────
clear
cat <<EOF
╔═══════════════════════════════════════════════════════════════╗
║ OpenResPublica Engine — SESSION CHECK-IN ║
╚═══════════════════════════════════════════════════════════════╝

  Identity: $LGU_SIGNER_NAME
  GPG Key ID: $KEY_ID
  SSH Socket: $SSH_AUTH_SOCK
  Key store: $ORP_SHM_BASE ($([ "$ORP_SHM_BASE" = "/dev/shm" ] && echo "RAM" || echo "⚠ storage — not RAM"))

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SESSION SSH PUBLIC KEY (paste this into GitHub Settings)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$(cat "$ORP_IDENTITY_DIR/session.pub")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  SESSION GPG PUBLIC KEY (for commit verification on GitHub)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$(cat "$ORP_IDENTITY_DIR/session.gpg")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ACTION REQUIRED (once per session)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Copy the SSH PUBLIC KEY shown above.

  2. Open your browser and go to:
       https://github.com/settings/keys

  3. Click "New SSH Key":
       Title: ORP Engine - $HOSTNAME - $(date +%Y-%m-%d)
       Key type: Authentication Key
       Key: [paste the SSH public key]
       Click "Add SSH Key"

  ⚠️ IMPORTANT: This key is EPHEMERAL.
      It will be wiped when you exit this session.
      You must repeat this step at every session startup.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# ── Clipboard helper (Termux only) ───────────────────────────────
# termux-clipboard-set runs on the Android host regardless of which
# proot-distro is active, so this still works inside Alpine proot.
if command -v termux-clipboard-set >/dev/null 2>&1; then
    cat "$ORP_IDENTITY_DIR/session.pub" | termux-clipboard-set
    termux-toast "SSH public key copied to clipboard" 2>/dev/null || true
    printf " [✔] SSH key copied to clipboard (Termux).\n\n"
fi

read -rp " Press [ENTER] after adding the SSH key to GitHub... "

printf "\n"
printf "╔═══════════════════════════════════════════════════════════════╗\n"
printf "║ Starting ORP Engine via Gunicorn... ║\n"
printf "╚═══════════════════════════════════════════════════════════════╝\n\n"
printf " Portal: https://localhost:9443\n"
printf " Auth: Client certificate required (operator_01.p12)\n"
printf " Stop: Press Ctrl+C\n\n"

# orp_launch_engine uses exec — replaces this shell with Gunicorn.
orp_launch_engine
