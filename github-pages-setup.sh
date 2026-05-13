#!/usr/bin/env bash
# github-pages-setup.sh — ORP GitHub Pages Deployment Assistant
# ─────────────────────────────────────────────────────────────────
# Auto-inits git, configures remote, validates manifest.json,
# writes the canonical config.json, and pushes to GitHub Pages.
#
# config.json schema matches config-loader.js and master-bootstrap.sh.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

# ── Colours ───────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; GOLD='\033[0;33m'; RED='\033[0;31m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()      { printf "${GREEN}[✔]${NC} %s\n" "$1"; }
info()    { printf "${CYAN}[*]${NC} %s\n" "$1"; }
warn()    { printf "${GOLD}[!]${NC} %s\n" "$1"; }
error()   { printf "${RED}[✘]${NC} %s\n" "$1" >&2; }
section() { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n\n" "$1"; }
hint()    { printf "  ${DIM}%s${NC}\n" "$1"; }

clear
printf "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔════════════════════════════════════════════════════════════╗
  ║  OpenRespublica — GitHub Pages Deployment Assistant      ║
  ║  TruthChain Public Verification Ledger Setup             ║
  ╚════════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"

# ── 1. Git repository ─────────────────────────────────────────────
section "1. Git Repository"

cd "$SCRIPT_DIR"
if [ ! -d .git ]; then
    info "Initializing git repository..."
    git init > /dev/null 2>&1
    git branch -M main 2>/dev/null || true
    ok "Git repository initialized on branch: main"
else
    ok "Git repository already initialized."
fi

# ── 2. Git identity ───────────────────────────────────────────────
section "2. Git Identity"

CURRENT_NAME="$(git config user.name  2>/dev/null || echo '')"
CURRENT_EMAIL="$(git config user.email 2>/dev/null || echo '')"

printf "  Current Git Identity:\n"
printf "    user.name  = ${BOLD}${CURRENT_NAME:-NOT SET}${NC}\n"
printf "    user.email = ${BOLD}${CURRENT_EMAIL:-NOT SET}${NC}\n\n"

if [ -z "$CURRENT_NAME" ] || [ -z "$CURRENT_EMAIL" ]; then
    read -rp "  Enter GitHub username: " GIT_USER
    while [ -z "$GIT_USER" ]; do
        warn "Username cannot be empty."
        read -rp "  Enter GitHub username: " GIT_USER
    done
    read -rp "  Enter GitHub email: " GIT_EMAIL
    while [[ "$GIT_EMAIL" != *"@"* ]]; do
        warn "Invalid email format."
        read -rp "  Enter GitHub email: " GIT_EMAIL
    done
    git config user.name  "$GIT_USER"
    git config user.email "$GIT_EMAIL"
    ok "Git identity configured."
else
    read -rp "  Reconfigure identity? [y/N]: " RECONFIG
    if [[ "$RECONFIG" =~ ^[Yy]$ ]]; then
        read -rp "    Enter GitHub username: " GIT_USER
        read -rp "    Enter GitHub email: " GIT_EMAIL
        git config user.name  "$GIT_USER"
        git config user.email "$GIT_EMAIL"
        ok "Git identity updated."
    fi
fi

# ── 3. Remote ─────────────────────────────────────────────────────
section "3. GitHub Remote"

if git remote get-url origin >/dev/null 2>&1; then
    CURRENT_REMOTE="$(git remote get-url origin)"
    printf "  Current remote: ${BOLD}${CURRENT_REMOTE}${NC}\n\n"
    read -rp "  Update remote? [y/N]: " UPDATE_REMOTE
    if [[ "$UPDATE_REMOTE" =~ ^[Yy]$ ]]; then
        hint "Example: git@github.com:openrespublica-ph/truthchain-ledger.git"
        read -rp "    New URL: " NEW_REMOTE
        [ -n "$NEW_REMOTE" ] && git remote set-url origin "$NEW_REMOTE" && ok "Remote updated."
    fi
else
    warn "No remote configured."
    if [ -n "${GITHUB_OWNER:-}" ] && [ -n "${GITHUB_PAGES_REPO:-}" ]; then
        hint "Auto-detected: ${GITHUB_OWNER}/${GITHUB_PAGES_REPO}"
        read -rp "  Use these? [Y/n]: " USE_AUTO
        if [[ ! "$USE_AUTO" =~ ^[Nn]$ ]]; then
            REMOTE="git@github.com:${GITHUB_OWNER}/${GITHUB_PAGES_REPO}.git"
            git remote add origin "$REMOTE"
            ok "Remote added: $REMOTE"
        fi
    else
        hint "Example: git@github.com:openrespublica-ph/truthchain-ledger.git"
        read -rp "  GitHub URL: " GITHUB_REMOTE
        [ -n "$GITHUB_REMOTE" ] && git remote add origin "$GITHUB_REMOTE" && ok "Remote added."
    fi
fi

printf "\n"
info "Git remotes:"
git remote -v

# ── 4. GitHub Pages content ───────────────────────────────────────
section "4. GitHub Pages Content"

mkdir -p "$SCRIPT_DIR/docs/records"
ok "Directories ready."

touch "$SCRIPT_DIR/docs/.nojekyll"
ok ".nojekyll created."

# ── config.json (canonical nested schema) ────────────────────────
# This schema must match config-loader.js and master-bootstrap.sh.
# config-loader.js reads: lgu.name, lgu.signer_name, lgu.signer_position,
# github.portal_url, portal.title
CONFIG_FILE="$SCRIPT_DIR/docs/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    info "Writing config.json (canonical schema)..."

    # Build portal_url from env or derive it
    PORTAL_URL="${GITHUB_PORTAL_URL:-}"
    if [ -z "$PORTAL_URL" ] && [ -n "${GITHUB_OWNER:-}" ] && [ -n "${GITHUB_PAGES_REPO:-}" ]; then
        PORTAL_URL="https://${GITHUB_OWNER}.github.io/${GITHUB_PAGES_REPO}/verify.html"
    fi

    cat > "$CONFIG_FILE" <<EOF
{
  "lgu": {
    "name": "${LGU_NAME:-Local Government Unit}",
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
    "portal_url": "${PORTAL_URL:-}"
  },
  "generated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "version": "1.0.0"
}
EOF
    ok "config.json written."
else
    warn "config.json already exists — skipping."
    hint "Delete $CONFIG_FILE to regenerate."
fi

# ── 5. Validate manifest.json ─────────────────────────────────────
section "5. Ledger Manifest Validation"

MANIFEST="$SCRIPT_DIR/docs/records/manifest.json"

if [ ! -f "$MANIFEST" ]; then
    printf '[]' > "$MANIFEST"
    ok "manifest.json created (empty array)."
else
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "
import json, sys
with open('$MANIFEST') as f:
    data = json.load(f)
assert isinstance(data, list), 'manifest.json must be a JSON array'
" 2>/dev/null; then
            ok "manifest.json schema valid (array)."
        else
            warn "Invalid schema detected. Resetting..."
            cp "$MANIFEST" "${MANIFEST}.bak"
            printf '[]' > "$MANIFEST"
            ok "manifest.json reset. Backup: ${MANIFEST}.bak"
        fi
    fi
fi

# ── 6. Stage and commit ───────────────────────────────────────────
section "6. Git Commit"

git add docs/ .gitignore 2>/dev/null || true

if ! git diff --cached --quiet 2>/dev/null; then
    DEFAULT_MSG="docs: Initialize GitHub Pages verification portal"
    read -rp "  Commit message [$DEFAULT_MSG]: " COMMIT_MSG
    COMMIT_MSG="${COMMIT_MSG:-$DEFAULT_MSG}"
    git commit -m "$COMMIT_MSG" && ok "Committed."
else
    warn "No changes to commit."
fi

# ── 7. GitHub authentication ──────────────────────────────────────
section "7. GitHub Authentication"

printf "  GitHub requires a Personal Access Token (PAT).\n\n"
printf "  ${BOLD}Create PAT:${NC}\n"
printf "    1. https://github.com/settings/tokens\n"
printf "    2. Generate token (classic)\n"
printf "    3. Scope: ${BOLD}repo${NC}\n"
printf "    4. Copy token\n\n"
printf "  ${BOLD}During push:${NC}\n"
printf "    Username: GitHub username\n"
printf "    Password: Paste PAT (won't show)\n\n"

read -rp "  Ready to push? Press ENTER or Ctrl+C to abort... "

# ── 8. Push ───────────────────────────────────────────────────────
section "8. Pushing to GitHub"

BRANCH="$(git branch --show-current 2>/dev/null || echo 'main')"
info "Pushing branch: ${BOLD}${BRANCH}${NC}"
printf "\n"

if git push -u origin "$BRANCH" 2>&1; then
    ok "Push successful."
else
    error "Push failed."
    printf "  1. Verify the repository exists on GitHub\n"
    printf "  2. Verify push permissions\n"
    printf "  3. Verify PAT scope includes 'repo'\n\n"
    exit 1
fi

# ── 9. Summary ────────────────────────────────────────────────────
section "Deployment Complete"

REMOTE="$(git remote get-url origin 2>/dev/null || echo 'N/A')"
printf "  Repository: ${BOLD}${REMOTE}${NC}\n"
printf "  Branch: ${BOLD}origin/${BRANCH}${NC}\n"
printf "  Config: ${BOLD}docs/config.json${NC}\n"
printf "  Manifest: ${BOLD}docs/records/manifest.json${NC}\n\n"
printf "  Next: ${BOLD}./run_orp.sh${NC}\n\n"

ok "GitHub Pages setup complete."
