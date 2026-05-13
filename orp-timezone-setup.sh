#!/usr/bin/env bash
# orp-timezone-setup.sh — System Timezone Configuration
# ─────────────────────────────────────────────────────────────────
# Sets Asia/Manila system timezone for WSL2 and Termux proot-distro.
# Writes both /etc/localtime (symlink) and /etc/timezone (text file).
#
# Idempotent — safe to re-run if timezone is already correct.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

TARGET_TZ="Asia/Manila"
ZONEINFO_FILE="/usr/share/zoneinfo/${TARGET_TZ}"
LOG_FILE="${LOG_FILE:-$HOME/orp-timezone-setup.log}"

# ── Colours ───────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; GOLD='\033[0;33m'; RED='\033[0;31m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()      { printf "${GREEN}[✔]${NC} %s\n" "$1" | tee -a "$LOG_FILE"; }
info()    { printf "${CYAN}[*]${NC} %s\n" "$1" | tee -a "$LOG_FILE"; }
warn()    { printf "${GOLD}[!]${NC} %s\n" "$1" | tee -a "$LOG_FILE"; }
die()     { printf "${RED}[✘] ERROR: %s${NC}\n" "$1" >&2 | tee -a "$LOG_FILE"; exit 1; }
section() { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n\n" "$1"; }

# ── Log directory ─────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
printf '[%s] Timezone setup started.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG_FILE"

# ── Banner ────────────────────────────────────────────────────────
clear
printf "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║     ORP ENGINE — System Timezone Configuration          ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"
printf "  ${DIM}Target timezone: %s${NC}\n\n" "$TARGET_TZ"

# ── 1. tzdata pre-flight ──────────────────────────────────────────
section "1. Timezone Data"

if [ ! -f "$ZONEINFO_FILE" ]; then
    info "Timezone file not found. Installing tzdata..."
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata
    if [ ! -f "$ZONEINFO_FILE" ]; then
        die "Timezone file still missing after tzdata install: $ZONEINFO_FILE"
    fi
    ok "tzdata installed."
else
    ok "Timezone file found: $ZONEINFO_FILE"
fi

# ── 2. /etc/localtime symlink ─────────────────────────────────────
section "2. System Clock (localtime)"

if [ -L /etc/localtime ]; then
    CURRENT_LINK="$(readlink -f /etc/localtime 2>/dev/null || echo 'unknown')"
    if [ "$CURRENT_LINK" = "$ZONEINFO_FILE" ]; then
        ok "/etc/localtime already points to $TARGET_TZ — no change needed."
    else
        info "Updating /etc/localtime from $(basename "$CURRENT_LINK")..."
        sudo ln -sf "$ZONEINFO_FILE" /etc/localtime
        ok "/etc/localtime updated."
    fi
elif [ -f /etc/localtime ]; then
    warn "/etc/localtime is a regular file (not a symlink). Replacing..."
    sudo ln -sf "$ZONEINFO_FILE" /etc/localtime
    ok "/etc/localtime replaced with symlink."
else
    info "Creating /etc/localtime..."
    sudo ln -sf "$ZONEINFO_FILE" /etc/localtime
    ok "/etc/localtime created."
fi

# ── 3. /etc/timezone text file ────────────────────────────────────
# Required by dpkg-reconfigure, Python's datetime, and many system
# tools on Debian/Ubuntu. The symlink alone is not sufficient.
section "3. Timezone Name File (/etc/timezone)"

CURRENT_TZ_FILE="$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]' || echo '')"

if [ "$CURRENT_TZ_FILE" = "$TARGET_TZ" ]; then
    ok "/etc/timezone already set to $TARGET_TZ — no change needed."
else
    info "Writing $TARGET_TZ to /etc/timezone..."
    echo "$TARGET_TZ" | sudo tee /etc/timezone > /dev/null
    ok "/etc/timezone updated."
fi

# ── 4. Shell environment ──────────────────────────────────────────
# WSL2 does not always inherit /etc/timezone into new shells.
# Setting TZ= in ~/.bashrc ensures the correct timezone in every
# bash session regardless of WSL2 or Termux proot-distro behaviour.
section "4. Shell Environment"

if grep -q 'export TZ=' "$HOME/.bashrc" 2>/dev/null; then
    ok "TZ already set in ~/.bashrc."
else
    printf '\n# ORP Engine — timezone\nexport TZ="%s"\n' "$TARGET_TZ" >> "$HOME/.bashrc"
    ok "TZ added to ~/.bashrc."
fi

# Export for the current session so subsequent setup steps in the
# same shell process (e.g. master-bootstrap.sh) see the right TZ.
export TZ="$TARGET_TZ"

# ── 5. Verification ───────────────────────────────────────────────
section "5. Verification"

CURRENT_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"
CURRENT_OFFSET="$(date '+%z')"

printf "  ${BOLD}%-20s${NC} %s\n" "System time:" "$CURRENT_TIME"
printf "  ${BOLD}%-20s${NC} %s\n" "UTC offset:" "$CURRENT_OFFSET"
printf "  ${BOLD}%-20s${NC} %s\n" "/etc/timezone:" "$(cat /etc/timezone 2>/dev/null)"
printf "  ${BOLD}%-20s${NC} %s\n" "/etc/localtime:" "$(readlink -f /etc/localtime 2>/dev/null)"
printf "\n"

if date | grep -qE '(PHT|PST|\+0800)'; then
    ok "Timezone verified: Philippines Standard Time (UTC+8)."
else
    warn "UTC offset does not match +0800 — verify /etc/localtime manually."
fi

# ── Log ───────────────────────────────────────────────────────────
{
    printf '  Timezone: %s\n' "$TARGET_TZ"
    printf '  System time: %s\n' "$CURRENT_TIME"
    printf '  UTC offset: %s\n' "$CURRENT_OFFSET"
    printf '  Completed: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$LOG_FILE"

ok "Timezone setup complete."
