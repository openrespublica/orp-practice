#!/bin/bash
# orp-pki-setup.sh — Alpine Minimal Sovereign PKI Setup
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"

PKI_DIR="${PKI_DIR:-$HOME/.orp_engine/ssl}"

echo "[*] Initializing ORP Engine PKI Generator"
echo "[*] Target Directory: $PKI_DIR"

# Ensure openssl is installed
if ! command -v openssl >/dev/null 2>&1; then
    echo "[*] Installing openssl..."
    apk add --no-cache openssl
fi

mkdir -p "$PKI_DIR"
cd "$PKI_DIR"

# 1. Root CA
if [ -f sovereign_root.crt ]; then
    echo "[!] Root CA exists — skipping."
else
    echo "[*] Generating 4096-bit RSA Root CA (10 years)..."
    openssl genrsa -out sovereign_root.key 4096 2>/dev/null
    openssl req -x509 -new -nodes -key sovereign_root.key -sha256 -days 3650 \
        -out sovereign_root.crt \
        -subj "/C=PH/ST=Negros Oriental/L=Sibulan/O=ORP Sovereign/CN=ORP Root CA" 2>/dev/null
    echo "[✔] Root CA generated."
fi

# 2. Server Certificate
if [ -f orp_server.crt ]; then
    echo "[!] Server certificate exists — skipping."
else
    echo "[*] Generating Server Certificate (1 year)..."
    openssl genrsa -out orp_server.key 2048 2>/dev/null
    openssl req -new -key orp_server.key -out orp_server.csr \
        -subj "/C=PH/ST=Negros Oriental/L=Sibulan/O=ORP Engine/CN=localhost" 2>/dev/null
    openssl x509 -req -in orp_server.csr -CA sovereign_root.crt -CAkey sovereign_root.key \
        -CAcreateserial -out orp_server.crt -days 365 -sha256 2>/dev/null
    rm -f orp_server.csr
    echo "[✔] Server certificate generated."
fi

# 3. Operator Certificate
if [ -f operator_01.crt ]; then
    echo "[!] Operator certificate exists — skipping."
else
    printf "Enter Operator Common Name (CN) [ORP-Operator-01]: "
    read -r OP_CN
    OP_CN="${OP_CN:-ORP-Operator-01}"

    echo "[*] Generating Operator Certificate: $OP_CN..."
    openssl genrsa -out operator_01.key 2048 2>/dev/null
    openssl req -new -key operator_01.key -out operator_01.csr \
        -subj "/C=PH/ST=Negros Oriental/O=ORP Operators/CN=${OP_CN}" 2>/dev/null
    openssl x509 -req -in operator_01.csr -CA sovereign_root.crt -CAkey sovereign_root.key \
        -CAcreateserial -out operator_01.crt -days 365 -sha256 2>/dev/null
    rm -f operator_01.csr
    echo "[✔] Operator certificate generated."
fi

# 4. PKCS#12 Bundle
if [ -f operator_01.p12 ]; then
    echo "[!] PKCS#12 bundle exists — skipping."
else
    printf "Enter P12 Export Password (blank for none): "
    stty -echo
    read -r EXPORTPASS
    stty echo
    printf "\n"

    openssl pkcs12 -export -out operator_01.p12 -inkey operator_01.key -in operator_01.crt \
        -certfile sovereign_root.crt -passout "pass:${EXPORTPASS}" 2>/dev/null

    EXPORTPASS=""
    echo "[✔] PKCS#12 bundle created: operator_01.p12"
fi

# 5. Permissions (Alpine uses 'nginx' group)
echo "[*] Locking down file permissions..."
chmod 600 "$PKI_DIR"/*.key "$PKI_DIR"/*.p12
chmod 644 "$PKI_DIR"/*.crt
if getent group nginx >/dev/null 2>&1; then
    chgrp nginx "$PKI_DIR"/*.crt "$PKI_DIR"/*.key 2>/dev/null || true
    chmod 640 "$PKI_DIR"/*.key 2>/dev/null || true
fi

# 6. Verification
echo "[*] Verifying Chains..."
openssl verify -CAfile sovereign_root.crt operator_01.crt >/dev/null 2>&1 && echo "[✔] Operator -> Root: VALID"
openssl verify -CAfile sovereign_root.crt orp_server.crt >/dev/null 2>&1 && echo "[✔] Server -> Root: VALID"

echo "[✔] PKI Setup Complete."
echo "Export operator_01.p12 to your local machine to access the gateway."
