#!/bin/bash
# _orp_core.sh — Shared ORP Engine Boot Functions
# ─────────────────────────────────────────────────────────────────
# Source this file; do not execute it directly.
# All functions are called by run_orp.sh and run_orp-gum.sh.
#
# Alpine proot-distro compatibility notes:
#   • /dev/shm is not a tmpfs mount in proot — falls back to /tmp
#     with a clear warning (keys land on flash, not RAM).
#   • busybox mktemp does not support -p; template is passed as
#     a full path instead.
#   • busybox sleep rejects fractional seconds — all sleeps use 1s
#     and loop counts are halved to preserve the same wall-clock
#     timeout.
#   • nc -z is unreliable on Alpine; replaced with bash /dev/tcp.
#   • pgrep may be absent; ps-based fallbacks are used throughout.
#   • sudo is typically absent in proot (you run as root); the
#     SUDO variable is set to "" when running as root and to
#     "sudo" otherwise, so nginx calls are always correct.
#   • gpg-agent SSH socket path falls back to $GNUPGHOME when
#     /run/user/<uid>/ does not exist (common in proot).
#
# Required Alpine packages (install once with apk):
#   apk add bash gnupg openssh-keygen nginx procps
#   (immudb must be a static/musl binary — download from releases)
# ─────────────────────────────────────────────────────────────────

# ── Alpine /dev/shm guard ─────────────────────────────────────────
# In Termux proot-distro, /dev/shm is usually a directory on the
# overlay filesystem, NOT a real tmpfs — writing there is the same
# as writing to /tmp from a secrecy standpoint.  We detect this and
# warn the operator so they can decide whether that is acceptable.
#
# To get a real tmpfs on Termux, run from the Termux host shell:
#   mkdir -p /data/data/com.termux/files/usr/tmp/shm
#   mount -t tmpfs -o size=32m tmpfs /dev/shm   # requires root
#
_orp_shm_init() {
    if [ -d /dev/shm ] && [ -w /dev/shm ]; then
        # Verify it is actually a tmpfs (not just a directory).
        local fstype
        fstype=$(stat -f -c '%T' /dev/shm 2>/dev/null \
               || awk '$2=="/dev/shm"{print $3}' /proc/mounts 2>/dev/null \
               || echo "unknown")
        if [ "$fstype" = "tmpfs" ]; then
            ORP_SHM_BASE="/dev/shm"
        else
            ORP_SHM_BASE="/dev/shm"   # dir exists but may not be tmpfs
            printf '[!] WARNING: /dev/shm is not a tmpfs in this proot.\n'
            printf '    Ephemeral keys will be written to the overlay FS.\n'
            printf '    They will still be deleted on exit, but are NOT\n'
            printf '    held in volatile RAM during the session.\n\n'
        fi
    else
        ORP_SHM_BASE="/tmp"
        printf '[!] WARNING: /dev/shm is unavailable — using /tmp.\n'
        printf '    Keys are NOT in RAM; they exist on storage until\n'
        printf '    orp_cleanup() removes them on exit.\n\n'
    fi
    export ORP_SHM_BASE
}

# ── Port-check helper (replaces nc -z) ───────────────────────────
# Uses the bash /dev/tcp built-in so we never depend on a specific
# nc variant.  Returns 0 if the port is open, 1 otherwise.
_port_open() {
    local host="$1" port="$2"
    (echo > /dev/tcp/"$host"/"$port") 2>/dev/null
}

# ── Process-check helper (replaces pgrep -x) ─────────────────────
# Returns 0 if a process whose argv[0] exactly matches $1 exists.
# Falls back to ps when pgrep is absent.
_proc_running() {
    local name="$1"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x "$name" > /dev/null 2>&1
    else
        # shellcheck disable=SC2009
        ps -A -o comm= 2>/dev/null | grep -qx "$name"
    fi
}

# ── Privilege helper ──────────────────────────────────────────────
# In Alpine proot you are almost always UID 0; sudo is usually
# absent (and unneeded).  Exporting SUDO once at source-time is
# cleaner than inlining the check in every nginx call.
if [ "$(id -u)" = "0" ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    SUDO=""   # no sudo and not root — nginx calls may fail;
              # orp_refresh_gateway() will surface the error.
fi
export SUDO

# ── Identity anchor ───────────────────────────────────────────────
[ -d "$HOME/.identity" ] || mkdir -p "$HOME/.identity"
chmod 700 "$HOME/.identity"
[ -f "$HOME/.identity/db_secrets.env" ] && chmod 600 "$HOME/.identity/db_secrets.env"

# ─────────────────────────────────────────────────────────────────
# 1. Environment
# ─────────────────────────────────────────────────────────────────
orp_load_env() {
    local core_dir
    core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1009
    if [ -f "$core_dir/.env" ]; then
        set -a 
        # shellcheck disable=SC1091
        source "$core_dir/.env"
        set +a  
    else
        orp_die ".env not found at $core_dir/.env
  → Run ./orp-env-bootstrap.sh to create it."
    fi

    # shellcheck disable=SC1091
    if [ -f "$HOME/.identity/db_secrets.env" ]; then
        # shellcheck disable=SC1091
        set -a; source "$HOME/.identity/db_secrets.env"; set +a  
    else
        orp_die "db_secrets.env not found at ~/.identity/db_secrets.env
  → Run ./immudb-setup-operator.sh to create it."
    fi

    # Initialise the SHM base path now that env is loaded.
    _orp_shm_init

    printf '[✔] Environment loaded.\n'
}
# ─────────────────────────────────────────────────────────────────
# Error handler
# ─────────────────────────────────────────────────────────────────
orp_die() {
    printf '\n[✘] ERROR: %s\n' "$*" >&2
    exit 1
}

# ─────────────────────────────────────────────────────────────────
# 2. Cleanup trap
# ─────────────────────────────────────────────────────────────────
orp_cleanup() {
    printf '\n[!] Shutting down ORP Engine...\n'

    # Stop immudb if we started it.
    if [ -n "${IMMUDB_PID:-}" ] && kill -0 "$IMMUDB_PID" 2>/dev/null; then
        printf '[*] Stopping immudb (PID %s)...\n' "$IMMUDB_PID"
        kill "$IMMUDB_PID" 2>/dev/null || true
        sleep 1
    fi

    # Kill the GPG agent before wiping its home; otherwise the agent
    # relaunches itself and recreates files before rm -rf completes.
    if [ -n "${GNUPGHOME:-}" ] && [ -d "$GNUPGHOME" ]; then
        printf '[*] Wiping ephemeral GPG keys from %s...\n' "$ORP_SHM_BASE"
        # gpgconf --kill all may not honour GNUPGHOME in all Alpine
        # gnupg builds; kill by socket path as a belt-and-suspenders
        # measure.
        gpgconf --kill all 2>/dev/null || true
        local agent_sock="${GNUPGHOME}/S.gpg-agent"
        [ -S "$agent_sock" ] && \
            gpg-connect-agent --homedir "$GNUPGHOME" killagent /bye \
                > /dev/null 2>&1 || true
        rm -rf "$GNUPGHOME"
    fi

    # Wipe the exported public-key directory.
    local id_dir="${ORP_SHM_BASE}/orp_identity"
    [ -d "$id_dir" ] && rm -rf "$id_dir"
    
    printf '[✔] Session terminated. Keys wiped from %s.\n' "$ORP_SHM_BASE"
}

# ─────────────────────────────────────────────────────────────────
# 3. Ephemeral Ed25519 identity
# ─────────────────────────────────────────────────────────────────
orp_forge_identity() {
    printf '[*] Generating ephemeral Ed25519 session identity...\n'

    export GNUPGHOME
    GNUPGHOME=$(mktemp -d /tmp/.orp-gpg-XXXXXX)
    chmod 700 "$GNUPGHOME"

    cat > "$GNUPGHOME/gpg-agent.conf" <<'GPGCONF'
enable-ssh-support
allow-loopback-pinentry
default-cache-ttl 86400
GPGCONF

    # Start the agent AFTER exporting GNUPGHOME — it reads the env var
    # and creates its socket at $GNUPGHOME/S.gpg-agent.
    # Do NOT pass --homedir; that flag conflicts with the env-var socket path
    # on Alpine's gnupg build and causes the "No agent running" failure.
    gpg-agent --daemon \
        --enable-ssh-support \
        --allow-loopback-pinentry \
        > /dev/null 2>&1 || true

    # Wait for the socket file — not a port, just a filesystem entry.
    local i=0
    while [ ! -S "${GNUPGHOME}/S.gpg-agent" ]; do
        sleep 1
        i=$((i + 1))
        [ $i -ge 10 ] && orp_die \
            "gpg-agent socket not found after 10s.
  Expected: ${GNUPGHOME}/S.gpg-agent
  Check that gpg-agent is installed: command -v gpg-agent"
    done
    printf '[*] gpg-agent socket ready.\n'

    # SSH socket lives alongside the main socket.
    export SSH_AUTH_SOCK="${GNUPGHOME}/S.gpg-agent.ssh"

    cat > "$GNUPGHOME/gpg-gen-spec" <<EOF
Key-Type: EDDSA
Key-Curve: ed25519
Key-Usage: auth,sign
Name-Real: $LGU_SIGNER_NAME
Name-Email: $OPERATOR_GPG_EMAIL
Expire-Date: 1d
%no-protection
%commit
EOF
    
    # stderr intentionally left open — surfacing gpg errors is essential.
    gpg --batch --generate-key "$GNUPGHOME/gpg-gen-spec" > /dev/null \
        || orp_die "GPG key generation failed (see error above)."
        
    # Poll for the key to appear in the keyring.
    local KEYGRIP=""
    i=0
    while [ -z "$KEYGRIP" ]; do
        sleep 1
        i=$((i + 1))
        [ $i -ge 10 ] && orp_die "GPG key not found in keyring after 10s."
        KEYGRIP=$(gpg --with-keygrip -K "$OPERATOR_GPG_EMAIL" 2>/dev/null \
                  | awk '/Keygrip/{print $3; exit}')
    done

    echo "$KEYGRIP 0" > "$GNUPGHOME/sshcontrol"
    gpg-connect-agent updatestartuptty /bye > /dev/null 2>&1 || true
    
    export ORP_IDENTITY_DIR="${ORP_SHM_BASE}/orp_identity"
    mkdir -p "$ORP_IDENTITY_DIR"
    
    gpg --export-ssh-key "$OPERATOR_GPG_EMAIL" > "$ORP_IDENTITY_DIR/session.pub"
    gpg --export --armor   "$OPERATOR_GPG_EMAIL" > "$ORP_IDENTITY_DIR/session.gpg"

    KEY_ID=$(gpg --list-secret-keys --with-colons "$OPERATOR_GPG_EMAIL" \
             | awk -F: '/^sec/{print $5; exit}')
    export KEY_ID

    printf '[✔] Ed25519 identity forged (expires in 24 hours).\n'
}

# ─────────────────────────────────────────────────────────────────
# 4. immudb vault
# ─────────────────────────────────────────────────────────────────
orp_start_vault() {
    printf '[*] Checking for immudb vault on :3322...\n'

    if _port_open 127.0.0.1 3322; then
        printf '[!] Vault already running — attaching.\n'
        # ps-based PID lookup — pgrep -f may be absent on minimal Alpine.
        if command -v pgrep >/dev/null 2>&1; then
            IMMUDB_PID=$(pgrep -f "immudb" | head -n1 || true)
        else
            IMMUDB_PID=$(ps -A -o pid=,comm= 2>/dev/null \
                        | awk '/immudb/{print $1; exit}')
        fi
    else
        printf '[*] Starting hardened immudb instance...\n'

        "$HOME/bin/immudb" \
            --dir "$HOME/.orp_vault/data" \
            --address 127.0.0.1 \
            --port 3322 \
            --pidfile "$HOME/.orp_vault/immudb.pid" \
            --auth=true \
            --maintenance=false \
            >> "$HOME/.orp_vault/immudb.log" 2>&1 &
        IMMUDB_PID=$!

        # Poll — 10-second timeout with 1s busybox-safe intervals.
        local i=0
        while ! _port_open 127.0.0.1 3322; do
            sleep 1
            i=$((i + 1))
            [ $i -ge 10 ] && orp_die "immudb failed to start after 10s.
  Check: $HOME/.orp_vault/immudb.log"
        done
        printf '[✔] Vault ready on :3322.\n'
    fi
    export IMMUDB_PID
}

# ─────────────────────────────────────────────────────────────────
# 5. Git config
# ─────────────────────────────────────────────────────────────────
orp_configure_git() {
    printf '[*] Configuring git for GPG commit signing...\n'

    cd "$GITHUB_REPO_PATH" || \
        orp_die "Cannot cd to GITHUB_REPO_PATH: $GITHUB_REPO_PATH"

    # Tell git which gpg binary and homedir to use.  On Alpine the
    # binary is usually /usr/bin/gpg; gpg2 may not exist as a
    # separate symlink.
    local gpg_bin
    gpg_bin=$(command -v gpg2 2>/dev/null || command -v gpg)

    git config --local user.name        "$LGU_SIGNER_NAME"
    git config --local user.email       "$OPERATOR_GPG_EMAIL"
    git config --local user.signingkey  "$KEY_ID"
    git config --local commit.gpgsign   true
    git config --local gpg.program      "$gpg_bin"
    
    # Pass GNUPGHOME via the git environment so the ephemeral
    # keyring is used for every git gpg call in this session.
    # (git does not have a native per-repo gpg homedir setting.)
    export GNUPGHOME

    printf '[✔] Git configured for signed commits.\n'
}

# ─────────────────────────────────────────────────────────────────
# 6. Engine launch
# ─────────────────────────────────────────────────────────────────
orp_launch_engine() {
    # Re-derive the SSH socket in case it shifted.
    export SSH_AUTH_SOCK
    SSH_AUTH_SOCK=$(gpgconf --homedir "$GNUPGHOME" \
        --list-dirs agent-ssh-socket 2>/dev/null \
        || echo "${GNUPGHOME}/S.gpg-agent.ssh")
    export GNUPGHOME
    
    if [ ! -x "./.venv/bin/gunicorn" ]; then
        orp_die "Gunicorn not found in .venv
  Run: ./python_prep.sh to create the virtual environment."
    fi
    
    local port="${FLASK_PORT:-5000}"
    printf '[*] Launching Gunicorn on 127.0.0.1:%s...\n' "$port"

    exec ./.venv/bin/gunicorn \
        --bind "127.0.0.1:${port}" \
        --workers 1 \
        --threads 2 \
        --timeout 120 \
        --access-logfile - \
        --error-logfile  - \
        main:app
}

# ─────────────────────────────────────────────────────────────────
# 7. Nginx gateway
# ─────────────────────────────────────────────────────────────────
orp_refresh_gateway() {
    printf '[*] Verifying Nginx mTLS gateway...\n'

    if ! command -v nginx >/dev/null 2>&1; then
        printf '[!] Nginx not in PATH — skipping gateway check.\n'
        printf '    Install with: apk add nginx\n'
        return 0
    fi

    # On Alpine proot the nginx config lives under /etc/nginx/.
    # The site-specific conf is still expected at:
    #   /etc/nginx/conf.d/orp_engine.conf
    if ! $SUDO nginx -t > /dev/null 2>&1; then
        $SUDO nginx -t >&2
        orp_die "Nginx config is invalid. Fix: /etc/nginx/conf.d/orp_engine.conf"
    fi

    # Alpine nginx does not use systemctl; use native signals.
    # _proc_running uses ps as a pgrep fallback.
    if _proc_running nginx; then
        printf '[*] Reloading Nginx config...\n'
        $SUDO nginx -s reload
    else
        printf '[*] Starting Nginx...\n'
        $SUDO nginx
    fi

    sleep 1
    if ! _proc_running nginx; then
        orp_die "Nginx failed to start. Run: ${SUDO} nginx -t"
    fi
    
    printf '[✔] Gateway operational on :9443.\n'
}
