#!/bin/sh                                                                                 # orp-timezone-setup.sh — Alpine System Timezone Configuration
set -eu
                                                                                          TARGET_TZ="Asia/Manila"
ZONEINFO_FILE="/usr/share/zoneinfo/${TARGET_TZ}"
LOG_FILE="${LOG_FILE:-$HOME/orp-timezone-setup.log}"
                                                                                          echo "[*] System Timezone Configuration: $TARGET_TZ"                                      
# ── 1. tzdata pre-flight ──────────────────────────────────────────
if [ ! -f "$ZONEINFO_FILE" ]; then
    echo "[*] Timezone file not found. Installing tzdata via apk..."
    apk add --no-cache tzdata                                                                 if [ ! -f "$ZONEINFO_FILE" ]; then
        echo "[✘] ERROR: Timezone file missing after install: $ZONEINFO_FILE" >&2
        exit 1
    fi
    echo "[✔] tzdata installed."
fi
                                                                                          # ── 2. /etc/localtime symlink ─────────────────────────────────────
if [ -L /etc/localtime ]; then
    CURRENT_LINK="$(readlink -f /etc/localtime 2>/dev/null || echo 'unknown')"
    if [ "$CURRENT_LINK" = "$ZONEINFO_FILE" ]; then
        echo "[✔] /etc/localtime already points to $TARGET_TZ"
    else                                                                                          echo "[*] Updating /etc/localtime..."
        ln -sf "$ZONEINFO_FILE" /etc/localtime
        echo "[✔] /etc/localtime updated."
    fi                                                                                    else
    echo "[*] Creating /etc/localtime..."                                                     ln -sf "$ZONEINFO_FILE" /etc/localtime
    echo "[✔] /etc/localtime created."
fi

# ── 3. /etc/timezone text file ────────────────────────────────────                      CURRENT_TZ_FILE="$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]' || echo '')"
if [ "$CURRENT_TZ_FILE" = "$TARGET_TZ" ]; then
    echo "[✔] /etc/timezone already set."
else
    echo "[*] Writing $TARGET_TZ to /etc/timezone..."
    echo "$TARGET_TZ" > /etc/timezone
    echo "[✔] /etc/timezone updated."                                                     fi

# ── 4. Shell environment ──────────────────────────────────────────
# Alpine defaults to ash, which sources ~/.profile
PROFILE_FILE="$HOME/.profile"                                                             if grep -q 'export TZ=' "$PROFILE_FILE" 2>/dev/null; then                                     echo "[✔] TZ already set in $PROFILE_FILE"
else
    printf '\n# ORP Engine — timezone\nexport TZ="%s"\n' "$TARGET_TZ" >> "$PROFILE_FILE"
    echo "[✔] TZ added to $PROFILE_FILE"
fi
export TZ="$TARGET_TZ"

# ── 5. Verification ───────────────────────────────────────────────
CURRENT_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
CURRENT_OFFSET="$(date '+%z')"

echo "[*] System time: $CURRENT_TIME"
echo "[*] UTC offset: $CURRENT_OFFSET"

if date | grep -qE '(PHT|PST|\+0800)'; then
    echo "[✔] Timezone verified: Philippines Standard Time (UTC+8)."
else
    echo "[!] UTC offset does not match +0800. Verify manually."                          fi
