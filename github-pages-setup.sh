#!/usr/bin/env bash
# github-pages-setup.sh
#
# OpenRespublica GitHub Pages Deployment Assistant
#
# Features:
# - Validates docs/ structure
# - Ensures .nojekyll exists
# - Validates manifest.json
# - Interactive Git identity setup
# - Interactive GitHub remote configuration
# - GitHub PAT authentication guidance
# - Commits and pushes automatically
#
# Usage:
#   chmod +x github-pages-setup.sh
#   ./github-pages-setup.sh

set -euo pipefail

# ----------------------------------------------------------
# Helpers
# ----------------------------------------------------------

info() {
  echo ""
  echo "[INFO] $1"
}

success() {
  echo ""
  echo "[SUCCESS] $1"
}

warn() {
  echo ""
  echo "[WARNING] $1"
}

error() {
  echo ""
  echo "[ERROR] $1"
}

# ----------------------------------------------------------
# Paths
# ----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_DIR="$SCRIPT_DIR/docs"
RECORDS_DIR="$DOCS_DIR/records"
MANIFEST="$RECORDS_DIR/manifest.json"

clear

echo "=========================================================="
echo "     OpenRespublica GitHub Pages Deploy Assistant"
echo "=========================================================="
echo ""

# ----------------------------------------------------------
# Verify Git Repository
# ----------------------------------------------------------

if [ ! -d "$SCRIPT_DIR/.git" ]; then
  error "This directory is not a Git repository."
  echo ""
  echo "Initialize one first:"
  echo "  git init"
  exit 1
fi

success "Git repository detected."

# ----------------------------------------------------------
# Git Identity Setup
# ----------------------------------------------------------

info "Checking Git identity configuration..."

CURRENT_NAME="$(git config user.name || true)"
CURRENT_EMAIL="$(git config user.email || true)"

echo ""
echo "Current Git Identity:"
echo "  user.name  = ${CURRENT_NAME:-NOT SET}"
echo "  user.email = ${CURRENT_EMAIL:-NOT SET}"
echo ""

read -rp "Would you like to configure/update Git identity? (y/N): " CONFIGURE_GIT

if [[ "$CONFIGURE_GIT" =~ ^[Yy]$ ]]; then
  echo ""

  read -rp "Enter GitHub username or organization name: " GITHUB_USER
  read -rp "Enter GitHub email: " GITHUB_EMAIL

  git config user.name "$GITHUB_USER"
  git config user.email "$GITHUB_EMAIL"

  success "Git identity updated."

  echo ""
  echo "Configured Identity:"
  echo "  user.name  = $(git config user.name)"
  echo "  user.email = $(git config user.email)"
else
  GITHUB_USER="${CURRENT_NAME:-}"
fi

# ----------------------------------------------------------
# GitHub Remote Setup
# ----------------------------------------------------------

info "Checking Git remote configuration..."

if git remote get-url origin >/dev/null 2>&1; then
  CURRENT_REMOTE="$(git remote get-url origin)"

  echo ""
  echo "Current origin remote:"
  echo "  $CURRENT_REMOTE"
  echo ""

  read -rp "Would you like to update the origin remote? (y/N): " UPDATE_REMOTE

  if [[ "$UPDATE_REMOTE" =~ ^[Yy]$ ]]; then
    read -rp "Enter GitHub repository name: " REPO_NAME

    REMOTE_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"

    git remote set-url origin "$REMOTE_URL"

    success "Origin remote updated."
  fi
else
  warn "No origin remote configured."

  echo ""
  read -rp "Enter GitHub username/org: " GITHUB_USER
  read -rp "Enter GitHub repository name: " REPO_NAME

  REMOTE_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"

  git remote add origin "$REMOTE_URL"

  success "Origin remote added."
fi

echo ""
echo "Configured Git Remotes:"
git remote -v

# ----------------------------------------------------------
# Prepare GitHub Pages Content
# ----------------------------------------------------------

info "Preparing GitHub Pages content..."

mkdir -p "$DOCS_DIR" "$RECORDS_DIR"

touch "$DOCS_DIR/.nojekyll"

success ".nojekyll ensured."

# ----------------------------------------------------------
# Validate manifest.json
# ----------------------------------------------------------

if [ ! -f "$MANIFEST" ]; then
  echo "[]" > "$MANIFEST"
  success "Created empty manifest.json"
else
  if ! head -n 1 "$MANIFEST" | grep -q "^\s*\["; then
    warn "manifest.json is invalid."

    BACKUP_FILE="${MANIFEST}.bak.$(date +%s)"

    cp "$MANIFEST" "$BACKUP_FILE"

    echo "[]" > "$MANIFEST"

    success "manifest.json reset."
    echo "Backup created:"
    echo "  $BACKUP_FILE"
  else
    success "manifest.json validated."
  fi
fi

# ----------------------------------------------------------
# Git Status
# ----------------------------------------------------------

info "Git status overview..."

echo ""
git status --short

# ----------------------------------------------------------
# Stage Changes
# ----------------------------------------------------------

info "Staging GitHub Pages files..."

git add docs/ || true
git add docs/.nojekyll 2>/dev/null || true

success "Files staged."

# ----------------------------------------------------------
# Commit Changes
# ----------------------------------------------------------

if git diff --cached --quiet; then
  warn "No changes detected."
else
  echo ""
  read -rp "Enter commit message [docs: update public verification portal]: " COMMIT_MSG

  COMMIT_MSG="${COMMIT_MSG:-docs: update public verification portal}"

  git commit -m "$COMMIT_MSG"

  success "Changes committed."
fi

# ----------------------------------------------------------
# GitHub Authentication Guidance
# ----------------------------------------------------------

echo ""
echo "=========================================================="
echo "                GitHub Authentication"
echo "=========================================================="
echo ""
echo "GitHub no longer accepts account passwords"
echo "for Git operations over HTTPS."
echo ""
echo "You MUST use a GitHub Personal Access Token (PAT)."
echo ""
echo "Create one here:"
echo ""
echo "  https://github.com/settings/tokens"
echo ""
echo "Recommended configuration:"
echo ""
echo "  Token Type:"
echo "    - Fine-grained token"
echo "      OR"
echo "    - Classic token"
echo ""
echo "  Required Scope:"
echo "    ✓ repo"
echo ""
echo "During git push:"
echo ""
echo "  Username -> your GitHub username"
echo "  Password -> paste the PAT token"
echo ""
echo "IMPORTANT:"
echo "The token will NOT appear while typing."
echo ""

read -rp "Press ENTER when your GitHub PAT is ready..."

# ----------------------------------------------------------
# Push Changes
# ----------------------------------------------------------

CURRENT_BRANCH="$(git branch --show-current || true)"

if [ -z "$CURRENT_BRANCH" ]; then
  CURRENT_BRANCH="main"
fi

echo ""
info "Pushing to GitHub..."

if git push -u origin "$CURRENT_BRANCH"; then
  success "GitHub Pages content deployed successfully."

  echo ""
  echo "Branch pushed:"
  echo "  origin/$CURRENT_BRANCH"
else
  error "Push failed."

  echo ""
  echo "Troubleshooting:"
  echo "  1. Verify repository permissions"
  echo "  2. Verify GitHub PAT scope includes 'repo'"
  echo "  3. Verify remote URL"
  echo "  4. Verify repository exists on GitHub"

  exit 1
fi

# ----------------------------------------------------------
# Finished
# ----------------------------------------------------------

echo ""
echo "=========================================================="
echo "                     Deployment Complete"
echo "=========================================================="
echo ""

echo "Repository:"
git remote get-url origin

echo ""
echo "Current branch:"
echo "  $CURRENT_BRANCH"

echo ""
echo "GitHub Pages setup finished successfully."
echo ""
