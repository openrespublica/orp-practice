#!/bin/bash
# run_orp.sh — ORP Engine Launcher
# Alpine Linux 3.23 — Persistent PKI — LUKS USB Vault
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_orp_core.sh"

trap orp_cleanup EXIT INT TERM

# ── Boot sequence ─────────────────────────────────────────────────
orp_load_env
orp_unlock_vault
orp_validate_keys
orp_configure_git
orp_verify_github_ssh
orp_refresh_gateway

# ── Session summary ───────────────────────────────────────────────
clear
cat <<BANNER
╔═══════════════════════════════════════════════════════════════╗
║         OpenResPublica Engine — SESSION CHECK-IN              ║
╚═══════════════════════════════════════════════════════════════╝

  Office   : $LGU_NAME
  Operator : $LGU_SIGNER_NAME ($LGU_SIGNER_POSITION)
  GPG Key  : $KEY_ID
  SSH Key  : $ORP_SSH_KEY
             $SSH_KEY_FP

  Vault    : $ORP_VAULT_MOUNT ✅ SEALED (LUKS2/AES-XTS-512)
  Records  : $ORP_RECORDS_DIR
  GitHub   : ✅ Authenticated → openrespublica/orp-practice

  Portal   : http://localhost:${FLASK_PORT:-5000}
  Stop     : Ctrl+C (vault seals automatically)

  ⚠️  Do NOT remove the Kingston USB while engine is running.

═══════════════════════════════════════════════════════════════
BANNER

# ── Launch Gunicorn in background ────────────────────────────────
printf '[*] Launching Gunicorn on 127.0.0.1:%s...\n' "${FLASK_PORT:-5000}"

"$SCRIPT_DIR/.venv/bin/gunicorn" \
    --bind "127.0.0.1:${FLASK_PORT:-5000}" \
    --workers 1 \
    --threads 2 \
    --timeout 120 \
    --access-logfile - \
    --error-logfile  - \
    main:app &

GUNICORN_PID=$!
sleep 2

if ! kill -0 "$GUNICORN_PID" 2>/dev/null; then
    printf '[✘] Gunicorn failed to start — check errors above.\n'
    exit 1
fi

printf '[✔] Gunicorn running (PID %s).\n' "$GUNICORN_PID"

# ── USB watchdog ──────────────────────────────────────────────────
orp_start_usb_watchdog "$GUNICORN_PID"

# ── Wait — Ctrl+C fires orp_cleanup via trap ──────────────────────
printf '[*] Engine running. Press Ctrl+C to stop.\n\n'
wait "$GUNICORN_PID"
