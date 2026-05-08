#!/usr/bin/env bash

set -e

echo "=============================================="
echo " OpenRespublica GitHub Remote Setup Assistant "
echo "=============================================="
echo ""

# -----------------------------
# Check if inside a git repo
# -----------------------------
if [ ! -d ".git" ]; then
    echo "❌ This directory is not a Git repository."
    echo "Run this script inside your project folder."
    exit 1
fi

echo "✅ Git repository detected."
echo ""

# -----------------------------
# Git identity configuration
# -----------------------------
echo "----------------------------------------------"
echo " STEP 1: Configure Git Identity"
echo "----------------------------------------------"
echo ""

read -rp "Enter your GitHub username or organization name: " GITHUB_USER
read -rp "Enter your GitHub email: " GITHUB_EMAIL

echo ""
echo "Configuring local Git identity..."
git config user.name "$GITHUB_USER"
git config user.email "$GITHUB_EMAIL"

echo ""
echo "✅ Git identity configured:"
echo "   user.name  = $(git config user.name)"
echo "   user.email = $(git config user.email)"
echo ""

# -----------------------------
# Repository configuration
# -----------------------------
echo "----------------------------------------------"
echo " STEP 2: Configure GitHub Repository Remote"
echo "----------------------------------------------"
echo ""

read -rp "Enter GitHub repository name: " REPO_NAME

REMOTE_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"

echo ""
echo "Generated remote URL:"
echo "  $REMOTE_URL"
echo ""

# -----------------------------
# Configure remote
# -----------------------------
if git remote get-url origin >/dev/null 2>&1; then
    echo "⚠ Existing 'origin' remote detected."
    echo "Updating remote URL..."
    git remote set-url origin "$REMOTE_URL"
else
    echo "No existing origin remote found."
    echo "Adding new origin remote..."
    git remote add origin "$REMOTE_URL"
fi

echo ""
echo "✅ Remote configuration complete."
echo ""

# -----------------------------
# Display remotes
# -----------------------------
echo "----------------------------------------------"
echo " STEP 3: Verify Git Remotes"
echo "----------------------------------------------"
echo ""

git remote -v

echo ""
echo "----------------------------------------------"
echo " STEP 4: GitHub Authentication Guidance"
echo "----------------------------------------------"
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
echo "Recommended settings:"
echo ""
echo "  Token type : Fine-grained or Classic"
echo "  Scope      : repo"
echo ""
echo "When Git asks for:"
echo ""
echo "  Username -> your GitHub username"
echo "  Password -> paste the PAT token"
echo ""
echo "IMPORTANT:"
echo "The token will NOT visibly appear while typing."
echo ""

read -rp "Press ENTER once your PAT is ready..."

echo ""
echo "----------------------------------------------"
echo " STEP 5: Push to GitHub"
echo "----------------------------------------------"
echo ""

CURRENT_BRANCH=$(git branch --show-current)

if [ -z "$CURRENT_BRANCH" ]; then
    CURRENT_BRANCH="main"
fi

echo "Pushing branch '$CURRENT_BRANCH' to origin..."
echo ""

git push -u origin "$CURRENT_BRANCH"

echo ""
echo "✅ Push completed successfully."
echo ""
echo "Repository is now connected to GitHub."
