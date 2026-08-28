#!/bin/bash
# _orp_core.sh — ORP Engine Boot Functions
# Alpine Linux 3.23 — Persistent PKI — LUKS USB Vault
# Source this file; do not execute directly.
# ─────────────────────────────────────────────────────────────────

# ── Error handler ─────────────────────────────────────────────────
orp_die() {
    printf '\n[✘] ERROR: %s\n' "$*" >&2
    exit 1
}

# ─────────────────────────────────────────────────────────────────
# 1. Load environment
# ─────────────────────────────────────────────────────────────────
orp_load_env() {
    local core_dir
    core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    [ -f "$core_dir/.env" ] || orp_die ".env not found at $core_dir/.env"

    set -a
    # shellcheck disable=SC1091
    source "$core_dir/.env"
    set +a

    # Expand $HOME in values — Alpine sh doesn't auto-expand in sourced files
    ORP_SSH_KEY="${ORP_SSH_KEY/\$HOME/$HOME}"
    ORP_GPG_KEY_ID_FILE="${ORP_GPG_KEY_ID_FILE/\$HOME/$HOME}"
    GITHUB_REPO_PATH="${GITHUB_REPO_PATH/\$HOME/$HOME}"
    export ORP_SSH_KEY ORP_GPG_KEY_ID_FILE GITHUB_REPO_PATH

    printf '[✔] Environment loaded.\n'
}

# ─────────────────────────────────────────────────────────────────
# 2. PKI key validation — persistent 30-day keys
# ─────────────────────────────────────────────────────────────────
orp_validate_keys() {
    local warn_days=7
    local expiry days_left

    printf '[*] Validating persistent PKI keys...\n'

    # ── SSH ───────────────────────────────────────────────────────
    [ -f "$ORP_SSH_KEY" ] || \
        orp_die "SSH key not found: $ORP_SSH_KEY\n  Run: ./orp_setup_ssh.sh"
    [ -f "${ORP_SSH_KEY}.pub" ] || \
        orp_die "SSH public key missing.\n  Run: ./orp_setup_ssh.sh"

    local ssh_expiry_file="${ORP_SSH_KEY%/*}/expiry.txt"
    [ -f "$ssh_expiry_file" ] || \
        orp_die "SSH expiry file missing.\n  Run: ./orp_setup_ssh.sh"

    expiry=$(cat "$ssh_expiry_file")
    days_left=$(python3 -c "
import datetime
exp = datetime.date.fromisoformat('$expiry')
print((exp - datetime.date.today()).days)
")

    if   [ "$days_left" -le 0 ]; then
        orp_die "SSH key EXPIRED on $expiry.\n  Run: ./orp_setup_ssh.sh"
    elif [ "$days_left" -le "$warn_days" ]; then
        printf '[!] WARNING: SSH key expires in %dd (%s). Rotate soon.\n' \
               "$days_left" "$expiry"
    else
        printf '[✔] SSH key valid — %dd remaining (expires %s).\n' \
               "$days_left" "$expiry"
    fi

    export ORP_SSH_KEY
    export SSH_KEY_FP
    SSH_KEY_FP=$(ssh-keygen -lf "${ORP_SSH_KEY}.pub" 2>/dev/null | awk '{print $2}')

    # ── GPG ───────────────────────────────────────────────────────
    [ -f "$ORP_GPG_KEY_ID_FILE" ] || \
        orp_die "GPG key ID file not found.\n  Run: ./orp_setup_gpg.sh"

    local gpg_expiry_file="${ORP_GPG_KEY_ID_FILE%/*}/expiry.txt"
    [ -f "$gpg_expiry_file" ] || \
        orp_die "GPG expiry file missing.\n  Run: ./orp_setup_gpg.sh"

    export KEY_ID
    KEY_ID=$(cat "$ORP_GPG_KEY_ID_FILE")

    gpg --list-secret-keys "$KEY_ID" > /dev/null 2>&1 || \
        orp_die "GPG key $KEY_ID not in keyring.\n  Run: ./orp_setup_gpg.sh"

    expiry=$(cat "$gpg_expiry_file")
    days_left=$(python3 -c "
import datetime
exp = datetime.date.fromisoformat('$expiry')
print((exp - datetime.date.today()).days)
")

    if   [ "$days_left" -le 0 ]; then
        orp_die "GPG key EXPIRED on $expiry.\n  Run: ./orp_setup_gpg.sh"
    elif [ "$days_left" -le "$warn_days" ]; then
        printf '[!] WARNING: GPG key expires in %dd (%s). Rotate soon.\n' \
               "$days_left" "$expiry"
    else
        printf '[✔] GPG key valid — %dd remaining (expires %s).\n' \
               "$days_left" "$expiry"
    fi

    printf '[✔] PKI validation complete.\n'
}

# ─────────────────────────────────────────────────────────────────
# 3. Kingston USB detection + LUKS two-factor unlock
# ─────────────────────────────────────────────────────────────────
orp_unlock_vault() {
    printf '[*] Locating Kingston USB vault...\n'

    local boot_dev luks_dev boot_mount keyfile_path

    # ── Find FAT32 boot partition by UUID ─────────────────────────
    # Alpine uses blkid differently — no -U flag, use -t UUID=
    boot_dev=$(blkid -t "UUID=$ORP_USB_BOOT_UUID" -o device 2>/dev/null || true)

    if [ -z "$boot_dev" ]; then
        orp_die "Kingston USB not found.
  Expected FAT32 UUID : $ORP_USB_BOOT_UUID

  Make sure the USB is plugged in, then retry: ./run_orp.sh
  If on WSL2, first run from PowerShell: usbipd attach --wsl --busid 2-7"
    fi
    printf '[✔] USB boot partition: %s\n' "$boot_dev"

    # ── Mount FAT32 read-only ─────────────────────────────────────
    boot_mount=$(mktemp -d)
    doas mount -o ro "$boot_dev" "$boot_mount"

    # ── Verify USB identity ───────────────────────────────────────
    if [ ! -f "$boot_mount/$ORP_VAULT_IDENTITY" ]; then
        doas umount "$boot_mount"; rmdir "$boot_mount"
        orp_die "USB identity file missing — wrong USB or corrupted boot partition."
    fi

    local usb_serial
    usb_serial=$(grep "^ORP_USB_SERIAL=" \
                 "$boot_mount/$ORP_VAULT_IDENTITY" | cut -d= -f2)

    if [ "$usb_serial" != "$ORP_USB_SERIAL" ]; then
        doas umount "$boot_mount"; rmdir "$boot_mount"
        orp_die "USB serial mismatch.
  Expected : $ORP_USB_SERIAL
  Found    : $usb_serial
  This is not the authorised ORP vault USB."
    fi
    printf '[✔] USB identity verified (serial: %s).\n' "$usb_serial"

    # ── Read keyfile ──────────────────────────────────────────────
    keyfile_path="$boot_mount/$ORP_VAULT_KEYFILE"
    [ -f "$keyfile_path" ] || {
        doas umount "$boot_mount"; rmdir "$boot_mount"
        orp_die "LUKS keyfile missing from USB boot partition."
    }

    # ── Find LUKS partition by UUID ───────────────────────────────
    luks_dev=$(blkid -t "UUID=$ORP_USB_LUKS_UUID" -o device 2>/dev/null || true)
    if [ -z "$luks_dev" ]; then
        doas umount "$boot_mount"; rmdir "$boot_mount"
        orp_die "LUKS vault partition not found (UUID: $ORP_USB_LUKS_UUID)."
    fi

    # ── Close stale mapping ───────────────────────────────────────
    if [ -e "/dev/mapper/$ORP_VAULT_MAP" ]; then
        printf '[!] Stale vault mapping — closing...\n'
        doas cryptsetup close "$ORP_VAULT_MAP" 2>/dev/null || true
    fi

    # ── Unlock LUKS: keyfile (factor 1) + passphrase (factor 2) ──
    printf '[*] Unlocking LUKS vault...\n'
    printf '    Enter vault passphrase:\n'

    if ! doas cryptsetup open \
            --key-file "$keyfile_path" \
            --keyfile-size 512 \
            "$luks_dev" "$ORP_VAULT_MAP"; then
        doas umount "$boot_mount"; rmdir "$boot_mount"
        orp_die "LUKS unlock failed — wrong passphrase or corrupted vault."
    fi

    doas umount "$boot_mount"
    rmdir "$boot_mount"

    # ── Mount decrypted filesystem ────────────────────────────────
    doas mkdir -p "$ORP_VAULT_MOUNT"
    doas mount /dev/mapper/"$ORP_VAULT_MAP" "$ORP_VAULT_MOUNT"
    doas chown "$USER:$USER" "$ORP_VAULT_MOUNT"
    doas chmod 700 "$ORP_VAULT_MOUNT"

    # Create directory structure if first mount
    mkdir -p \
        "$ORP_VAULT_MOUNT/records" \
        "$ORP_VAULT_MOUNT/pdfs" \
        "$ORP_VAULT_MOUNT/backups" \
        "$ORP_VAULT_MOUNT/audit_log" \
        "$ORP_VAULT_MOUNT/exports"

    chmod 700 \
        "$ORP_VAULT_MOUNT/records" \
        "$ORP_VAULT_MOUNT/pdfs" \
        "$ORP_VAULT_MOUNT/backups" \
        "$ORP_VAULT_MOUNT/audit_log" \
        "$ORP_VAULT_MOUNT/exports"

    # Initialize chain file if first time
    if [ ! -f "$ORP_VAULT_MOUNT/chain.json" ]; then
        python3 -c "
import json, datetime
chain = {
    'chain_id': 'ORP-$(date +%Y)',
    'created': datetime.datetime.utcnow().isoformat() + 'Z',
    'genesis': '0' * 64,
    'entries': []
}
print(json.dumps(chain, indent=2))
" > "$ORP_VAULT_MOUNT/chain.json"
        chmod 600 "$ORP_VAULT_MOUNT/chain.json"
        printf '[✔] Chain initialized.\n'
    fi

    # Export vault paths for main.py
    export ORP_RECORDS_DIR="$ORP_VAULT_MOUNT/records"
    export ORP_PDFS_DIR="$ORP_VAULT_MOUNT/pdfs"
    export ORP_BACKUP_DIR="$ORP_VAULT_MOUNT/backups"
    export ORP_AUDIT_LOG="$ORP_VAULT_MOUNT/audit_log/engine.log"
    export ORP_CHAIN_FILE="$ORP_VAULT_MOUNT/chain.json"

    printf '[✔] Vault mounted at %s\n' "$ORP_VAULT_MOUNT"
}

# ─────────────────────────────────────────────────────────────────
# 4. Lock vault
# ─────────────────────────────────────────────────────────────────
orp_lock_vault() {
    printf '\n[!] Sealing vault...\n'
    sync

    if mountpoint -q "$ORP_VAULT_MOUNT" 2>/dev/null; then
        doas umount -l "$ORP_VAULT_MOUNT" 2>/dev/null || true
        printf '[✔] Vault filesystem unmounted.\n'
    fi

    if [ -e "/dev/mapper/$ORP_VAULT_MAP" ]; then
        doas cryptsetup close "$ORP_VAULT_MAP" 2>/dev/null || true
        printf '[✔] LUKS vault sealed.\n'
    fi
}

# ─────────────────────────────────────────────────────────────────
# 5. USB watchdog — immediate shutdown on unplug
# ─────────────────────────────────────────────────────────────────
orp_start_usb_watchdog() {
    local engine_pid="$1"
    printf '[*] USB watchdog active (engine PID: %s)...\n' "$engine_pid"

    (
        while true; do
            sleep 2
            # Alpine blkid: check if LUKS UUID still visible
            if ! blkid -t "UUID=$ORP_USB_LUKS_UUID" \
                    -o device > /dev/null 2>&1; then
                printf '\n[!!!] CRITICAL: Kingston USB removed!\n'
                printf '      Terminating engine and sealing vault...\n'
                kill -TERM "$engine_pid" 2>/dev/null || true
                sleep 1
                kill -KILL "$engine_pid" 2>/dev/null || true
                orp_lock_vault
                printf '[✔] Engine stopped. Vault sealed.\n'
                printf '    Re-insert USB and run ./run_orp.sh to restart.\n'
                exit 0
            fi
        done
    ) &

    export ORP_WATCHDOG_PID=$!
    printf '[✔] Watchdog PID: %s\n' "$ORP_WATCHDOG_PID"
}

# ─────────────────────────────────────────────────────────────────
# 6. GitHub SSH verification
# ─────────────────────────────────────────────────────────────────
orp_verify_github_ssh() {
    printf '[*] Verifying GitHub SSH access...\n'

    local ssh_output
    # GitHub always exits 1 even on success — || true prevents set -e abort
    ssh_output=$(
        ssh -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes \
            -i "$ORP_SSH_KEY" \
            -T git@github.com 2>&1
    ) || true

    if printf '%s' "$ssh_output" | grep -q "successfully authenticated"; then
        printf '[✔] GitHub SSH confirmed.\n'
        return 0
    fi

    # Key not registered — prompt operator
    printf '\n'
    printf '══════════════════════════════════════════════════\n'
    printf '  GitHub SSH key not registered\n'
    printf '  (persistent key — add once, valid 30 days)\n'
    printf '══════════════════════════════════════════════════\n\n'
    printf '  Public key:\n\n'
    cat "${ORP_SSH_KEY}.pub"
    printf '\n  Fingerprint : %s\n' "$SSH_KEY_FP"
    printf '  Add at      : https://github.com/settings/keys\n'
    printf '  Key type    : Authentication Key\n\n'
    read -rp "  Press [ENTER] after adding the key to GitHub... "

    ssh_output=$(
        ssh -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes \
            -i "$ORP_SSH_KEY" \
            -T git@github.com 2>&1
    ) || true

    if printf '%s' "$ssh_output" | grep -q "successfully authenticated"; then
        printf '[✔] GitHub SSH confirmed.\n'
    else
        orp_die "GitHub rejected the key.
  Response : $ssh_output
  Repo     : $(git -C "$GITHUB_REPO_PATH" remote get-url origin 2>/dev/null \
               || echo '(check GITHUB_REPO_PATH in .env)')"
    fi
}

# ─────────────────────────────────────────────────────────────────
# 7. Git configuration for this session
# ─────────────────────────────────────────────────────────────────
orp_configure_git() {
    cd "$GITHUB_REPO_PATH" || orp_die "Cannot cd to $GITHUB_REPO_PATH"

    git config --local user.name       "$LGU_SIGNER_NAME"
    git config --local user.email      "$OPERATOR_GPG_EMAIL"
    git config --local user.signingkey "$KEY_ID"
    git config --local commit.gpgsign  true
    git config --local gpg.program     "$(command -v gpg)"

    export GIT_SSH_COMMAND="ssh \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -i $ORP_SSH_KEY"

    export GNUPGHOME="${HOME}/.gnupg"
    printf '[✔] Git configured for session.\n'
}

# ─────────────────────────────────────────────────────────────────
# 8. Nginx gateway (Alpine — uses doas, no systemctl)
# ─────────────────────────────────────────────────────────────────
orp_refresh_gateway() {
    if ! command -v nginx >/dev/null 2>&1; then
        printf '[!] Nginx not found — skipping gateway.\n'
        return 0
    fi

    if ! doas nginx -t > /dev/null 2>&1; then
        doas nginx -t >&2
        orp_die "Nginx config invalid."
    fi

    if pgrep nginx > /dev/null 2>&1; then
        doas nginx -s reload
    else
        doas nginx
    fi

    sleep 1
    pgrep nginx > /dev/null 2>&1 || orp_die "Nginx failed to start."
    printf '[✔] Nginx gateway ready.\n'
}

# ─────────────────────────────────────────────────────────────────
# 9. Full cleanup — fires on EXIT, INT, TERM
# ─────────────────────────────────────────────────────────────────
orp_cleanup() {
    printf '\n[!] Shutting down ORP Engine...\n'

    [ -n "${ORP_WATCHDOG_PID:-}" ] && \
        kill "$ORP_WATCHDOG_PID" 2>/dev/null || true

    orp_lock_vault
    printf '[✔] Session ended. Vault sealed.\n'
}
