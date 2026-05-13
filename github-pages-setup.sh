#!/usr/bin/env bash
# github-pages-setup.sh — ORP GitHub Pages Deployment Assistant (POLISHED)
# Auto-init git, configure remote, validate manifest, push to GitHub Pages

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Load environment
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

# Colors
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

# 1. GIT REPOSITORY VERIFICATION (WITH AUTO-INIT)
section "1. Git Repository Verification"

if [ ! -d "$SCRIPT_DIR/.git" ]; then
    info "No git repository detected. Initializing..."
    cd "$SCRIPT_DIR"
    git init > /dev/null 2>&1
    git branch -M main 2>/dev/null || true
    ok "Git repository initialized on branch: main"
else
    ok "Git repository already initialized."
fi

# 2. GIT IDENTITY CONFIGURATION
section "2. Git Identity Configuration"

CURRENT_NAME="$(git config user.name 2>/dev/null || echo "")"
CURRENT_EMAIL="$(git config user.email 2>/dev/null || echo "")"

printf "  Current Git Identity:\n"
printf "    user.name  = ${BOLD}${CURRENT_NAME:-NOT SET}${NC}\n"
printf "    user.email = ${BOLD}${CURRENT_EMAIL:-NOT SET}${NC}\n\n"

if [ -z "$CURRENT_NAME" ] || [ -z "$CURRENT_EMAIL" ]; then
    info "Setting up git identity..."
    
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
    
    git config user.name "$GIT_USER"
    git config user.email "$GIT_EMAIL"
    
    ok "Git identity configured."
else
    read -rp "  Reconfigure Git identity? [y/N]: " RECONFIG
    if [[ "$RECONFIG" =~ ^[Yy]$ ]]; then
        read -rp "    Enter GitHub username: " GIT_USER
        read -rp "    Enter GitHub email: " GIT_EMAIL
        git config user.name "$GIT_USER"
        git config user.email "$GIT_EMAIL"
        ok "Git identity updated."
    fi
fi

# 3. GITHUB REMOTE CONFIGURATION
section "3. GitHub Remote Configuration"

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

# 4. PREPARE GITHUB PAGES CONTENT
section "4. GitHub Pages Content"

mkdir -p "$SCRIPT_DIR/docs/records"
ok "Directories created."

touch "$SCRIPT_DIR/docs/.nojekyll"
ok ".nojekyll created."

CONFIG_FILE="$SCRIPT_DIR/docs/config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    LGU_NAME="${LGU_NAME:-Local Government Unit}"
    cat > "$CONFIG_FILE" <<EOF
{
  "LGU_NAME": "$LGU_NAME",
  "GENERATED": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "VERSION": "1.0.0"
}
EOF
    ok "config.json created."
fi

# 5. VALIDATE MANIFEST.JSON
section "5. Ledger Manifest Validation"

MANIFEST="$SCRIPT_DIR/docs/records/manifest.json"

if [ ! -f "$MANIFEST" ]; then
    printf '[]' > "$MANIFEST"
    ok "manifest.json created (empty array)."
else
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
    assert isinstance(data, list), 'Must be array'
" 2>/dev/null; then
            ok "manifest.json schema valid (array)."
        else
            warn "Invalid schema detected. Resetting..."
            cp "$MANIFEST" "${MANIFEST}.bak"
            printf '[]' > "$MANIFEST"
            ok "manifest.json reset."
        fi
    fi
fi

# 6. STAGE AND COMMIT
section "6. Git Status & Commit"

git add docs/ .gitignore 2>/dev/null || true

if ! git diff --cached --quiet 2>/dev/null; then
    printf "\n"
    DEFAULT_MSG="docs: Initialize GitHub Pages verification portal"
    read -rp "  Commit message [$DEFAULT_MSG]: " COMMIT_MSG
    COMMIT_MSG="${COMMIT_MSG:-$DEFAULT_MSG}"
    git commit -m "$COMMIT_MSG" && ok "Committed."
else
    warn "No changes to commit."
fi

# 7. GITHUB AUTHENTICATION
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

# 8. PUSH TO GITHUB
section "8. Pushing to GitHub"

BRANCH="$(git branch --show-current 2>/dev/null || echo "main")"

info "Pushing branch: ${BOLD}${BRANCH}${NC}"
printf "\n"

if git push -u origin "$BRANCH" 2>&1; then
    ok "Deployment successful!"
else
    error "Push failed."
    printf "  1. Verify repo exists on GitHub\n"
    printf "  2. Verify push permissions\n"
    printf "  3. Verify PAT scope includes 'repo'\n\n"
    exit 1
fi

# 9. SUMMARY
section "Deployment Complete"

REMOTE=$(git remote get-url origin 2>/dev/null || echo "N/A")
printf "  Repository: ${BOLD}${REMOTE}${NC}\n"
printf "  Branch: ${BOLD}origin/${BRANCH}${NC}\n"
printf "  Manifest: ${BOLD}docs/records/manifest.json${NC}\n\n"
printf "  Next: ${BOLD}./run_orp.sh${NC}\n\n"

ok "GitHub Pages setup complete!"
