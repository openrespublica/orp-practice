#!/usr/bin/env bash
# repo-init.sh — ORP Engine Repository Structure Initialization
# ─────────────────────────────────────────────────────────────────
# Creates the docs/records/ directory tree, sentinel .gitkeep files,
# an empty manifest.json, and the .gitignore.
#
# Idempotent — safe to re-run on an existing repo.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; GOLD='\033[0;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# SC2059 Fix: Use %b to safely evaluate color escape sequences
ok()   { printf '%b[✔]%b %s\n' "$GREEN" "$NC" "$1"; }
info() { printf '%b[*]%b %s\n' "$CYAN" "$NC" "$1"; }
warn() { printf '%b[!]%b %s\n' "$GOLD" "$NC" "$1"; }

clear
# SC2059 Fix: Pass color variables as formatting arguments
printf '%b' "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║    ORP ENGINE — Repository Structure Initialization    ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf '%b\n' "${NC}"
printf "  %bRepository root: %s%b\n\n" "$DIM" "$SCRIPT_DIR" "$NC"

# ── ORP Engine directory structure ───────────────────────────────
# This matches the actual structure main.py and Flask expect.
# Do NOT create app/, routes/, utils/, models/, config/, tests/ —
# those are generic scaffold patterns that do not belong here.
info "Creating ORP Engine directory structure..."

mkdir -p "$SCRIPT_DIR/docs/records"
mkdir -p "$SCRIPT_DIR/templates"
mkdir -p "$SCRIPT_DIR/static/css"
mkdir -p "$SCRIPT_DIR/static/js"

ok "Directories created."

# ── .gitkeep sentinels ────────────────────────────────────────────
# Git does not track empty directories. .gitkeep files let us commit
# the directory structure without any real content yet.
info "Creating .gitkeep sentinels..."

touch "$SCRIPT_DIR/docs/.gitkeep"
touch "$SCRIPT_DIR/docs/records/.gitkeep"
touch "$SCRIPT_DIR/static/css/.gitkeep"
touch "$SCRIPT_DIR/static/js/.gitkeep"

ok ".gitkeep sentinels created."

# ── manifest.json ─────────────────────────────────────────────────
# IMPORTANT: main.py's update_manifest() does json.load() and expects
# a flat JSON array (list), then calls records.insert(0, new_record).
# If manifest.json contains a dict instead of a list, the first upload
# will crash with: AttributeError: 'dict' object has no attribute 'insert'
#
# Correct schema: [] (empty array — main.py appends to this)
# Wrong schema:   {"records": [], "total": 0} (dict — crashes main.py)
MANIFEST="$SCRIPT_DIR/docs/records/manifest.json"
if [ ! -f "$MANIFEST" ]; then
    info "Creating manifest.json (empty array)..."
    # Plain empty array — main.py inserts records at index 0, newest first.
    printf '[]' > "$MANIFEST"
    ok "manifest.json created."
else
    warn "manifest.json already exists — skipping."
    # Validate it is a JSON array, not a dict
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "
import json, sys
with open('$MANIFEST') as f:
    data = json.load(f)
if not isinstance(data, list):
    print('WRONG: manifest.json is a dict, not an array')
    sys.exit(1)
" 2>/dev/null; then
            ok "manifest.json schema is correct (array)."
        else
            warn "manifest.json has wrong schema (expected array, got dict)."
            warn "Backing up and replacing with empty array..."
            cp "$MANIFEST" "${MANIFEST}.bak"
            printf '[]' > "$MANIFEST"
            ok "manifest.json reset to empty array. Backup: ${MANIFEST}.bak"
        fi
    fi
fi

# ── .gitignore ────────────────────────────────────────────────────
GITIGNORE="$SCRIPT_DIR/.gitignore"
if [ ! -f "$GITIGNORE" ]; then
    info "Creating .gitignore..."

    cat > "$GITIGNORE" <<'GITIGNORE_EOF'
# ORP Engine — .gitignore
# ─────────────────────────────────────────────────────────────────

# Python virtualenv
.venv/
__pycache__/
*.pyc
*.pyo
*.egg-info/
dist/
build/

# Environment file (contains LGU config — not a secret, but not committed)
.env

# immudb vault data (managed by immudb, not git)
.orp_vault/

# PKI directory — private keys must NEVER be committed.
# Path matches PKI_DIR in .env: $HOME/.orp_engine/ssl
# This .gitignore excludes it relative to repo root in case
# someone symlinks or copies it inside the repo accidentally.
.orp_engine/

# Identity secrets
.identity/

# OS artifacts
.DS_Store
Thumbs.db

# Editor artifacts
.vscode/
.idea/
*.swp
*.swo

# Logs
*.log
orp-setup.log
orp-timezone-setup.log

# Temporary files
*.tmp
*.bak
GITIGNORE_EOF

    ok ".gitignore created."
else
    warn ".gitignore already exists — skipping."
fi

# ── Git initialization ────────────────────────────────────────────
cd "$SCRIPT_DIR"

if [ ! -d .git ]; then
    info "Initializing git repository..."
    git init
    git branch -M main 2>/dev/null || true
    ok "Git repository initialized on branch: main"
else
    ok "Git repository already initialized."
fi

# ── Initial commit ───────────────────────────────────────────────
# Use explicit paths instead of ** glob — globstar is not enabled
# by default in bash and ** would silently add nothing.
info "Staging initial files..."

git add .gitignore                       2>/dev/null || true
git add docs/.gitkeep                    2>/dev/null || true
git add docs/records/.gitkeep            2>/dev/null || true
git add docs/records/manifest.json       2>/dev/null || true
git add static/css/.gitkeep              2>/dev/null || true
git add static/js/.gitkeep               2>/dev/null || true

if git diff --cached --quiet 2>/dev/null; then
    warn "No new changes to commit."
else
    # SC2015 Fix: Replaced && || with a proper if/else statement
    if git commit -m "init: repository structure" 2>/dev/null; then
        ok "Initial commit created."
    else
        warn "Commit skipped (git user may not be configured yet)."
    fi
fi

# ── Summary ──────────────────────────────────────────────────────
# SC2059 Fix: Safe variable handling for printf
printf '\n%b━━━ Repository Structure ━━━%b\n\n' "${BOLD}${CYAN}" "${NC}"
printf "  %s\n" "$SCRIPT_DIR"
printf "  ├── docs/\n"
printf "  │   ├── .gitkeep\n"
printf "  │   └── records/\n"
printf "  │       ├── .gitkeep\n"
printf "  │       └── manifest.json   ← empty [] array, appended by main.py\n"
printf "  ├── templates/              ← portal.html goes here\n"
printf "  ├── static/\n"
printf "  │   ├── css/                ← style.css goes here\n"
printf "  │   └── js/                 ← portal.js goes here\n"
printf "  ├── main.py\n"
printf "  ├── requirements.txt\n"
printf "  ├── .env                    ← git-ignored, created by orp-env-bootstrap.sh\n"
printf "  └── .gitignore\n\n"

ok "Repository structure initialized."
