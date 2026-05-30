#!/bin/bash
# nginx-setup.sh — Alpine Nginx mTLS Gateway Configuration
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=1091
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"

PKI_DIR="${PKI_DIR:-$HOME/.orp_engine/ssl}"
FLASK_PORT="${FLASK_PORT:-5000}"
NGINX_CONF_DEST="/etc/nginx/http.d/orp_engine.conf"
NGINX_CONF_TPL="$SCRIPT_DIR/orp_engine.conf.tpl"

echo "[*] Initializing ORP Engine Nginx Gateway Setup"

# Verify dependencies (Alpine uses gettext for envsubst)
if ! command -v envsubst >/dev/null 2>&1 || ! command -v nginx >/dev/null 2>&1; then
    echo "[*] Installing Nginx and Gettext..."
    apk add --no-cache nginx gettext
fi
                                                                                          # Verify Certificates
for cert in "$PKI_DIR/orp_server.crt" "$PKI_DIR/orp_server.key" "$PKI_DIR/sovereign_root.crt"; do
    if [ ! -f "$cert" ]; then
        echo "[✘] ERROR: Missing $cert. Run orp-pki-setup.sh first." >&2
        exit 1
    fi
done

if [ ! -f "$NGINX_CONF_TPL" ]; then
    echo "[✘] ERROR: Template missing: $NGINX_CONF_TPL" >&2
    exit 1
fi

echo "[*] Generating Nginx configuration..."
# shellcheck disable=SC2016
export PKI_DIR FLASK_PORT
# shellcheck disable=SC2016
envsubst '${PKI_DIR} ${FLASK_PORT}' < "$NGINX_CONF_TPL" > "$NGINX_CONF_DEST"

# Remove Alpine's default site configuration
if [ -f /etc/nginx/http.d/default.conf ]; then
    rm -f /etc/nginx/http.d/default.conf
    echo "[*] Default Nginx site removed."
fi

echo "[*] Testing Nginx Configuration..."
if ! nginx -t >/dev/null 2>&1; then
    nginx -t
    echo "[✘] ERROR: Nginx configuration invalid." >&2
    exit 1
fi

echo "[*] Reloading Nginx..."
if pgrep -x nginx >/dev/null 2>&1; then
    nginx -s reload
else
    nginx
fi

echo "[✔] Nginx Gateway Operational."
echo "Listening on: https://localhost:9443"
