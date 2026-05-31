#!/usr/bin/env bash
# master-bootstrap.sh — ORP Engine Master Setup Orchestrator
# ─────────────────────────────────────────────────────────────────
# Runs every setup script in the correct order on a fresh Ubuntu
# WSL2 or Termux proot-distro Ubuntu environment.
#
# USAGE:
#   ./master-bootstrap.sh [OPTIONS]
#
# OPTIONS:
#   -l, --list              List all steps and their skip conditions, then exit
#   -f, --from  N           Start from step N (skip steps 1 through N-1)
#   -o, --only  N[,M,...]   Run only the specified step numbers
#   -s, --skip  N[,M,...]   Skip the specified step numbers
#   -n, --dry-run           Show what would run without executing anything
#   -y, --yes               Skip the confirmation prompt (for automation)
#   -r, --resume            Resume from the last failed step (uses state file)
#       --reset-state       Clear the state file and exit
#   -h, --help              Show this help text
#
# EXAMPLES:
#   ./master-bootstrap.sh                    # Full fresh install
#   ./master-bootstrap.sh --from 4           # Resume from immudb build
#   ./master-bootstrap.sh --only 6,7         # Regenerate PKI and Nginx only
#   ./master-bootstrap.sh --skip 7 --yes     # Skip Nginx, no prompt
#   ./master-bootstrap.sh --dry-run          # Preview without running
#   ./master-bootstrap.sh --resume           # Continue from last failure
#   ./master-bootstrap.sh --list             # Show step overview
#
# STATE FILE:
#   ~/.orp-bootstrap.state tracks which steps have completed.
#   Use --reset-state to clear it.
#
# IDEMPOTENT:
#   Each step has a skip condition (a file or directory whose existence
#   means that step is already done). --from / --only / --skip override
#   these skip conditions when you want to force a step to re-run.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="${LOG_FILE:-$HOME/orp-setup.log}"
STATE_FILE="$HOME/.orp-bootstrap.state"

# ── Colour helpers ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; GOLD='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

hdr() {
    printf "\n%b%b╔══════════════════════════════════════════╗%b\n" "$BOLD" "$CYAN" "$NC"
    printf "%b%b║  %-40s║%b\n" "$BOLD" "$CYAN" "$1" "$NC"
    printf "%b%b╚══════════════════════════════════════════╝%b\n" "$BOLD" "$CYAN" "$NC"
}
ok()    { printf "%b[✔]%b %s\n" "$GREEN" "$NC" "$1" | tee -a "$LOG_FILE"; }
info()  { printf "%b[*]%b %s\n" "$CYAN" "$NC" "$1" | tee -a "$LOG_FILE"; }
warn()  { printf "%b[!]%b %s\n" "$GOLD" "$NC" "$1" | tee -a "$LOG_FILE"; }
die()   { printf "%b[✘] ERROR: %s%b\n" "$RED" "$1" "$NC" >&2; log "ERROR: $1"; exit 1; }
log()   { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
dim()   { printf "  %b%s%b\n" "$DIM" "$1" "$NC"; }

# ── Step registry ─────────────────────────────────────────────────
declare -A STEPS
declare -A STEP_SCRIPTS
declare -A STEP_SENTINELS
declare -a STEP_ORDER

_register_step() {
    local num="$1" desc="$2" script="$3" sentinel="$4"
    STEPS[$num]="$desc"
    STEP_SCRIPTS[$num]="$script"
    STEP_SENTINELS[$num]="$sentinel"
    STEP_ORDER+=("$num")
}

# Load .env early so $PKI_DIR is available for sentinel paths.
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

PKI_DIR_DEFAULT="$HOME/.orp_engine/ssl"
PKI_DIR="${PKI_DIR:-$PKI_DIR_DEFAULT}"

_register_step 1 "Timezone (Asia/Manila)"               "orp-timezone-setup.sh"       ""
_register_step 2 "Environment Configuration (.env)"     "orp-env-bootstrap.sh"        "$ENV_FILE"
_register_step 3 "Python Virtualenv + Dependencies"     "python_prep.sh"              "$SCRIPT_DIR/.venv"
_register_step 4 "immudb Binary Build"                  "immudb_setup.sh"             "$HOME/bin/immudb"
_register_step 5 "immudb Operator Database + Secrets"   "immudb-setup-operator.sh"    "$HOME/.identity/db_secrets.env"
_register_step 6 "Sovereign PKI (mTLS Certificates)"    "orp-pki-setup.sh"            "${PKI_DIR}/sovereign_root.crt"
_register_step 7 "Nginx mTLS Gateway"                   "nginx-setup.sh"              ""
_register_step 8 "Repository Directory Structure"       "repo-init.sh"                "$SCRIPT_DIR/docs/records/manifest.json"

TOTAL_STEPS=${#STEP_ORDER[@]}

# ── CLI argument parsing ──────────────────────────────────────────
OPT_LIST=false
OPT_DRY_RUN=false
OPT_YES=false
OPT_RESUME=false
OPT_RESET_STATE=false
OPT_FROM=0
OPT_ONLY=""  # comma-separated step numbers
OPT_SKIP=""  # comma-separated step numbers

_usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

  -l, --list              List steps and exit
  -f, --from  N           Start from step N
  -o, --only  N[,M,...]   Run only these steps
  -s, --skip  N[,M,...]   Skip these steps
  -n, --dry-run           Preview without executing
  -y, --yes               Skip confirmation prompt
  -r, --resume            Resume from last failed step
      --reset-state       Clear state file and exit
  -h, --help              Show this help

USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--list)         OPT_LIST=true ;;
        -n|--dry-run)      OPT_DRY_RUN=true ;;
        -y|--yes)          OPT_YES=true ;;
        -r|--resume)       OPT_RESUME=true ;;
        --reset-state)     OPT_RESET_STATE=true ;;
        -h|--help)         _usage; exit 0 ;;
        -f|--from)
            shift
            [[ "$1" =~ ^[0-9]+$ ]] || die "--from requires a step number (e.g. --from 4)"
            OPT_FROM="$1"
            ;;
        -o|--only)
            shift
            [[ "$1" =~ ^[0-9,]+$ ]] || die "--only requires comma-separated step numbers (e.g. --only 3,4)"
            OPT_ONLY="$1"
            ;;
        -s|--skip)
            shift
            [[ "$1" =~ ^[0-9,]+$ ]] || die "--skip requires comma-separated step numbers (e.g. --skip 7)"
            OPT_SKIP="$1"
            ;;
        *)
            warn "Unknown option: $1"; _usage; exit 1 ;;
    esac
    shift
done

# ── State file helpers ────────────────────────────────────────────
state_completed() { grep -qx "DONE:$1" "$STATE_FILE" 2>/dev/null; }
state_mark_done() { echo "DONE:$1" >> "$STATE_FILE"; }
state_mark_failed() {
    # Record the failed step so --resume knows where to restart.
    grep -v "^FAILED:" "$STATE_FILE" 2>/dev/null > "${STATE_FILE}.tmp" || true
    echo "FAILED:$1" >> "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}
state_last_failed() { grep "^FAILED:" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d: -f2 || echo ""; }

if $OPT_RESET_STATE; then
    rm -f "$STATE_FILE"
    ok "State file cleared."
    exit 0
fi

# ── Resolve resume step ───────────────────────────────────────────
if $OPT_RESUME; then
    FAILED_STEP="$(state_last_failed)"
    if [ -z "$FAILED_STEP" ]; then
        warn "No failed step recorded in state file. Running from step 1."
    else
        info "Resuming from step $FAILED_STEP (last failure)."
        OPT_FROM="$FAILED_STEP"
    fi
fi

# ── Step filter helpers ───────────────────────────────────────────
_in_list() {
    local needle="$1" haystack="$2"
    echo ",$haystack," | grep -q ",${needle},"
}

_should_run() {
    local num="$1"
    # --only overrides everything: if set, only listed steps run.
    if [ -n "$OPT_ONLY" ]; then
        _in_list "$num" "$OPT_ONLY" && return 0 || return 1
    fi
    # --skip: listed steps are excluded.
    if [ -n "$OPT_SKIP" ] && _in_list "$num" "$OPT_SKIP"; then
        return 1
    fi
    # --from: steps before N are skipped.
    if [ "$OPT_FROM" -gt 0 ] && [ "$num" -lt "$OPT_FROM" ]; then
        return 1
    fi
    return 0
}

# ── --list ────────────────────────────────────────────────────────
if $OPT_LIST; then
    clear
    printf "%b%b  ORP Engine Bootstrap — Step Registry%b\n\n" "$BOLD" "$CYAN" "$NC"
    printf "  %b%-4s %-42s %-12s %s%b\n" "$BOLD" "Step" "Description" "Status" "Skip Sentinel" "$NC"
    printf "  %s\n" "$(printf '%.0s─' {1..90})"
    for num in "${STEP_ORDER[@]}"; do
        desc="${STEPS[$num]}"
        sentinel="${STEP_SENTINELS[$num]}"
        if state_completed "$num"; then
            status="${GREEN}done${NC}"
        elif [ -n "$sentinel" ] && [ -e "$sentinel" ]; then
            status="${CYAN}ready${NC}"
        else
            status="${GOLD}pending${NC}"
        fi
        sentinel_display="${sentinel:-  (always runs)}"
        printf "  %b%2s%b   %-42s " "$BOLD" "$num" "$NC" "$desc"
        printf "%b" "${status}"
        printf "  %b%s%b\n" "$DIM" "$(basename "$sentinel_display")" "$NC"
    done
    printf "\n"
    printf "  %bState file: %s%b\n\n" "$DIM" "$STATE_FILE" "$NC"
    exit 0
fi

# ── Verify required scripts ───────────────────────────────────────
_verify_scripts() {
    local missing=()
    for num in "${STEP_ORDER[@]}"; do
        _should_run "$num" || continue
        local script="${STEP_SCRIPTS[$num]}"
        [ -f "$SCRIPT_DIR/$script" ] || missing+=("$script")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing scripts (re-clone the repository):\n  ${missing[*]}"
    fi
}

# ── Banner ────────────────────────────────────────────────────────
clear
printf "%b%b" "$BOLD" "$CYAN"
cat <<'BANNER'
  ╔═══════════════════════════════════════════════════════════╗
  ║    OPENRESPUBLICA — ORP ENGINE MASTER BOOTSTRAP           ║
  ║    TruthChain Sovereign Document Issuance System         ║
  ╚═══════════════════════════════════════════════════════════╝
BANNER
printf "%b" "$NC"

printf "\n  %bUbuntu WSL2 (Windows) · Termux proot-distro (Android)%b\n" "$DIM" "$NC"
printf "\n  %bLog:%b %s\n" "$BOLD" "$NC" "$LOG_FILE"

# Show active flags
if $OPT_DRY_RUN; then printf "  %bMode: DRY RUN — nothing will be executed%b\n" "$GOLD" "$NC"; fi
[ -n "$OPT_ONLY" ] && printf "  %bOnly steps: %s%b\n" "$GOLD" "$OPT_ONLY" "$NC"
[ -n "$OPT_SKIP" ] && printf "  %bSkipping steps: %s%b\n" "$GOLD" "$OPT_SKIP" "$NC"
[ "$OPT_FROM" -gt 0 ] && printf "  %bStarting from step: %s%b\n" "$GOLD" "$OPT_FROM" "$NC"
printf "\n"

# ── OS check ─────────────────────────────────────────────────────
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "Detected distro: ${ID:-unknown}. This script targets Ubuntu."
        warn "Continuing — some steps may need manual adjustment."
    else
        ok "Ubuntu ${VERSION_ID:-} detected."
    fi
fi

_verify_scripts

# ── Confirmation ──────────────────────────────────────────────────
if ! $OPT_YES && ! $OPT_DRY_RUN; then
    warn "This script will install packages and configure system services."
    warn "You may be prompted for your sudo password."
    printf "\n"
    read -rp "  Press ENTER to begin, or Ctrl+C to abort... "
fi

log "Bootstrap started. from=$OPT_FROM only=$OPT_ONLY skip=$OPT_SKIP dry=$OPT_DRY_RUN"

# ── Step runner ───────────────────────────────────────────────────
STEPS_RUN=0
STEPS_SKIPPED=0
STEPS_ALREADY_DONE=0

run_step() {
    local num="$1"
    local desc="${STEPS[$num]}"
    local script="${STEP_SCRIPTS[$num]}"
    local sentinel="${STEP_SENTINELS[$num]}"

    hdr "Step ${num}/${TOTAL_STEPS} — ${desc}"

    # ── Already done (state file) ─────────────────────────────────
    if state_completed "$num"; then
        warn "State file: step ${num} already completed — skipping."
        dim "Use --from $num or --only $num to force re-run."
        (( STEPS_ALREADY_DONE++ )) || true
        return 0
    fi

    # ── Sentinel skip (idempotency) ───────────────────────────────
    if [ -n "$sentinel" ] && [ -e "$sentinel" ]; then
        warn "Already complete (sentinel exists): $(basename "$sentinel")"
        dim "Remove '$sentinel' to re-run this step."
        state_mark_done "$num"
        (( STEPS_ALREADY_DONE++ )) || true
        return 0
    fi

    # ── Dry run ───────────────────────────────────────────────────
    if $OPT_DRY_RUN; then
        printf "  %b[DRY RUN]%b Would execute: %b%s%b\n\n" "$CYAN" "$NC" "$BOLD" "$script" "$NC"
        (( STEPS_RUN++ )) || true
        return 0
    fi

    # ── Execute ───────────────────────────────────────────────────
    log "START: step $num — $desc"

    local exit_code=0
    bash "$SCRIPT_DIR/$script" 2>&1 | tee -a "$LOG_FILE" || exit_code=${PIPESTATUS[0]}

    if [ "$exit_code" -ne 0 ]; then
        state_mark_failed "$num"
        log "FAIL: step $num — exit $exit_code"
        die "Step ${num} failed (exit ${exit_code}): ${script}\n  Re-run with: ./master-bootstrap.sh --from ${num}\n  Or check: $LOG_FILE"
    fi

    state_mark_done "$num"
    log "DONE: step $num — $desc"
    ok "Step ${num} complete: ${desc}"
    (( STEPS_RUN++ )) || true
}

# ── Execute steps ─────────────────────────────────────────────────
for num in "${STEP_ORDER[@]}"; do
    if ! _should_run "$num"; then
        printf "\n%b  [—] Step %s skipped: %s%b\n" "$DIM" "$num" "${STEPS[$num]}" "$NC"
        log "SKIP: step $num — ${STEPS[$num]}"
        (( STEPS_SKIPPED++ )) || true
        continue
    fi
    run_step "$num"
done

# ── Step 8 special: config.json for Docs ─────────────────────────
# Writing the canonical config.json for config-loader.js now happens
# alongside the repository directory structure build.
if _should_run "8" && ! $OPT_DRY_RUN && [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a

    if [ -n "${GITHUB_REPO_PATH:-}" ] && [ -d "$GITHUB_REPO_PATH/docs" ]; then
        info "Writing canonical config.json for config-loader.js..."

        PORTAL_URL="${GITHUB_PORTAL_URL:-https://${GITHUB_OWNER:-}.github.io/${GITHUB_PAGES_REPO:-}/verify.html}"

        cat > "$GITHUB_REPO_PATH/docs/config.json" <<EOF
{
  "lgu": {
    "name": "${LGU_NAME:-}",
    "signer_name": "${LGU_SIGNER_NAME:-}",
    "signer_position": "${LGU_SIGNER_POSITION:-Punong Barangay}",
    "timezone": "${LGU_TIMEZONE:-Asia/Manila}"
  },
  "portal": {
    "title": "TruthChain Verification",
    "subtitle": "LGU ${LGU_NAME:-} · Cryptographic Document Audit Portal"
  },
  "github": {
    "owner": "${GITHUB_OWNER:-}",
    "repo": "${GITHUB_PAGES_REPO:-}",
    "portal_url": "${PORTAL_URL}"
  },
  "generated": "$(date -Iseconds)",
  "version": "1.0.0"
}
EOF
        ok "config.json written to $GITHUB_REPO_PATH/docs/"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────
hdr "Bootstrap Summary"
printf "\n"
printf "  %b%-20s%b %d\n" "$BOLD" "Steps executed:" "$NC"    "$STEPS_RUN"
printf "  %b%-20s%b %d\n" "$BOLD" "Steps skipped:" "$NC"     "$STEPS_SKIPPED"
printf "  %b%-20s%b %d\n" "$BOLD" "Already complete:" "$NC"  "$STEPS_ALREADY_DONE"
printf "  %b%-20s%b %s\n" "$BOLD" "Log file:" "$NC"          "$LOG_FILE"
printf "  %b%-20s%b %s\n" "$BOLD" "State file:" "$NC"        "$STATE_FILE"
printf "\n"

if $OPT_DRY_RUN; then
    info "Dry run complete — no changes made."
    exit 0
fi

# ── Load env for next steps display ──────────────────────────────
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi
PKI_FINAL="${PKI_DIR:-$HOME/.orp_engine/ssl}"

{
    printf "  %bNext steps:%b\n\n" "$GOLD" "$NC"

    printf "  %b1.%b Install the operator certificate in your browser:\n\n" "$GOLD" "$NC"
    printf "        Chrome / Edge:\n"
    printf "          Settings → Privacy → Manage certificates → Import\n"
    printf "          Select: %b%s/operator_01.p12%b\n\n" "$BOLD" "$PKI_FINAL" "$NC"
    printf "        Firefox:\n"
    printf "          Settings → Privacy → View Certificates → Import\n"
    printf "          Select: %b%s/operator_01.p12%b\n\n" "$BOLD" "$PKI_FINAL" "$NC"

    printf "  %b2.%b Launch the engine:\n\n" "$GOLD" "$NC"
    printf "          %b./run_orp.sh%b\n\n" "$BOLD" "$NC"

    printf "  %b3.%b Paste the session SSH key to GitHub:\n\n" "$GOLD" "$NC"
    printf "          GitHub → Settings → SSH Keys → New SSH Key\n\n"

    printf "  %b4.%b Open the portal:\n\n" "$GOLD" "$NC"
    printf "          %bhttps://localhost:9443%b\n\n" "$BOLD" "$NC"

    printf "  %bTo re-run a specific step:%b\n" "$GOLD" "$NC"
    printf "          %b./master-bootstrap.sh --only N%b\n\n" "$BOLD" "$NC"

    printf "  %bTo resume from a failure:%b\n" "$GOLD" "$NC"
    printf "          %b./master-bootstrap.sh --resume%b\n\n" "$BOLD" "$NC"

    printf "  %bSetup log: %s%b\n\n" "$DIM" "$LOG_FILE" "$NC"
} | tee -a "$LOG_FILE"

log "Bootstrap complete."
ok "ORP Engine environment is ready."
