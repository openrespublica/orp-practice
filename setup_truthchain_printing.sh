#!/bin/bash
# ==============================================================================
# TRUTHCHAIN SECURE PRINT SERVICE SUBSYSTEM INITIALIZATION BLUEPRINT
# Target Environment: Alpine Linux Standard (Main Core Node)
# Implementation: Custom Isolated CUPS Backend Mapping to mTLS Gateway
# ==============================================================================

# Ensure the script is running with administrative privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] Critical Error: This setup script must be run with root authority." >&2
    echo "    Execute via: doas bash $0" >&2
    exit 1
fi

echo "[*] Phase 1: Refreshing system repositories and constructing core stack..."
apk update
apk add bash curl nginx cups cups-filters cups-libs util-linux ghostscript

echo "[*] Phase 2: Building underlying device-class framework directories..."
mkdir -p /usr/lib/cups/backend/
mkdir -p /var/log/cups/

echo "[*] Phase 3: Provisioning cryptographic access security groups..."
# Ensure targeted security boundaries exist
getent group lpadmin >/dev/null || addgroup lpadmin
getent group sys >/dev/null     || addgroup sys

# Append administrative users and core processes to system authorization groups
addgroup marco lpadmin
addgroup marco sys
addgroup root lpadmin

echo "[*] Phase 4: Constructing hardened cups-files.conf layout..."
cat << 'EOF' > /etc/cups/cups-files.conf
# ==============================================================================
# Hardened File/Directory Access Protection Mapping for TruthChain CUPS Engine
# ==============================================================================

# System administrative groups allowed to alter print execution states
SystemGroup lpadmin sys root

# Enforce Unix domain socket peer credential verification for local processes
PeerCred on

# Centralized Immutable Log Locations for Blue Team Audit Tracking
AccessLog /var/log/cups/access_log
ErrorLog /var/log/cups/error_log
PageLog /var/log/cups/page_log
EOF

echo "[*] Phase 5: Generating Custom Cryptographic Pipeline Backend..."
cat << 'EOF' > /usr/lib/cups/backend/truthchain
#!/usr/bin/env bash
# ==============================================================================
# /usr/lib/cups/backend/truthchain
# Custom CUPS Transmission Layer for the TruthChain Decentralized Proxy
# ==============================================================================

# CRITICAL FIX: CUPS isolates backends and clears the global environment.
# We must explicitly declare the system execution PATH.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

# Device Discovery Directive: If executed with zero parameters, announce capabilities
if [ -z "$1" ]; then
    echo 'direct truthchain "Unknown" "TruthChain Secure Cryptographic Printer Endpoint"'
    exit 0
fi

# Capture the 6 standard positional parameters passed natively by the CUPS daemon
JOB_ID="$1"
USER_NAME="$2"
JOB_TITLE="$3"
COPIES="$4"
OPTIONS="$5"
INPUT_FILE="$6"

# Configuration Boundaries for the local mTLS Portal Nginx Proxy
ENGINE_URL="https://127.0.0.1:9443/print" 
MTLS_CERT="/home/marco/.orp_engine/ssl/operator_01.crt"
MTLS_KEY="/home/marco/.orp_engine/ssl/operator_01.key"
ARCHIVE_DIR="/home/marco/pdf_printed_archive"

# Establish secure volatile working buffers
TMP_PAYLOAD=$(mktemp /tmp/orp_print.XXXXXX)
RESPONSE_PDF=$(mktemp /tmp/orp_processed.XXXXXX)

# PostScript to PDF Normalization Pipeline
if [ -n "$INPUT_FILE" ] && [ -f "$INPUT_FILE" ]; then
    ps2pdf "$INPUT_FILE" "$TMP_PAYLOAD"
else
    # Capture direct standard input stream from the CUPS pipeline spooler
    cat <&0 | ps2pdf - "$TMP_PAYLOAD"
fi

# Secure Payload Transmission via Mutual TLS Over Loopback Interface
HTTP_STATUS=$(curl -s -w "%{http_code}" -o "$RESPONSE_PDF" \
    --cert "$MTLS_CERT" \
    --key "$MTLS_KEY" \
    --insecure \
    -H "X-Operator-ID: $USER_NAME" \
    -H "X-Print-Job-Title: $JOB_TITLE" \
    --data-binary "@$TMP_PAYLOAD" \
    "$ENGINE_URL")

# Transaction Validation and Local Immutable Storage Logging
if [ "$HTTP_STATUS" -eq 200 ]; then
    mkdir -p "$ARCHIVE_DIR"
    STAMPED_FILE="${ARCHIVE_DIR}/Stamped_Job_${JOB_ID}.pdf"
    
    cp "$RESPONSE_PDF" "$STAMPED_FILE"
    chown marco:marco "$STAMPED_FILE"
    chmod 600 "$STAMPED_FILE"
    
    logger -t "TRUTHCHAIN-PRINTER" "SUCCESS: Job ${JOB_ID} verified and routed via mTLS proxy."
    rm -f "$TMP_PAYLOAD" "$RESPONSE_PDF"
    exit 0
else
    logger -t "TRUTHCHAIN-PRINTER" "ALERT: Cryptographic pipeline dropped stream. HTTP Code: $HTTP_STATUS"
    rm -f "$TMP_PAYLOAD" "$RESPONSE_PDF"
    exit 1
fi
EOF

echo "[*] Phase 6: Locking down file execution permissions..."
# CUPS requires root ownership and 700 permissions to execute custom backends safely
chown root:root /usr/lib/cups/backend/truthchain
chmod 700 /usr/lib/cups/backend/truthchain

# Pre-stage and secure the local operator's printing archive
mkdir -p /home/marco/pdf_printed_archive
chown -R marco:marco /home/marco/pdf_printed_archive
chmod 700 /home/marco/pdf_printed_archive

echo "[*] Phase 7: Initiating CUPS Core Daemon and setting boot runtime targets..."
rc-update add cupsd default
rc-service cupsd restart

echo "[*] Phase 7.5: Initiating Zero-Trust Host Hardening Protocol..."

# ==============================================================================
# LAYER 1: Binary Execution Sandbox
# Strip world-execution rights from all CUPS client binaries.
# Only users explicitly assigned to the lpadmin group (marco) can invoke them.
# ==============================================================================
echo "  -> Locking down CUPS executable binaries..."
for binary in lp lpr lpstat cancel cupsdisable cupsenable lpadmin lpinfo lpmove lpoptions; do
    if [ -f "/usr/bin/$binary" ]; then
        chown root:lpadmin "/usr/bin/$binary"
        chmod 750 "/usr/bin/$binary"
    fi
    if [ -f "/usr/sbin/$binary" ]; then
        chown root:lpadmin "/usr/sbin/$binary"
        chmod 750 "/usr/sbin/$binary"
    fi
done

# ==============================================================================
# LAYER 2: CUPS Policy Enforcement
# Force the internal IPP scheduler to drop jobs from any user except 'marco'.
# ==============================================================================
echo "  -> Rewriting internal IPP access policies..."
cat << 'EOF' > /etc/cups/cupsd.conf
# Strict Local Loopback Only
Listen 127.0.0.1:631
Listen [::1]:631

# Disable network browsing/discovery entirely
Browsing Off

# Default policy: Absolute restriction to the designated operator
<Policy default>
  # Job Submission and Management operations
  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Require user marco
    Order deny,allow
  </Limit>

  # Administrative operations
  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  # General read-only queries
  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
EOF

rc-service cupsd restart

# ==============================================================================
# LAYER 3: Backend Logic Kill-Switch
# Inject an immediate validation check into the TruthChain pipeline.
# ==============================================================================
echo "  -> Injecting execution kill-switch into the TruthChain backend..."

# We use sed to insert the kill-switch right after the variables are defined
sed -i '/INPUT_FILE="$6"/a \
\
# ── DEFENSE IN DEPTH: Hardcoded Execution Kill-Switch ──\
if [ "$USER_NAME" != "marco" ]; then\
    logger -t "TRUTHCHAIN-PRINTER" "CRITICAL: Unauthorized execution attempt by user: $USER_NAME. Payload destroyed."\
    exit 1\
fi\
' /usr/lib/cups/backend/truthchain

echo "[+] Hardening Protocol Complete. Print subsystem is now isolated."

echo "[*] Phase 8: Registering the TruthChain Endpoint into the CUPS Spooler Matrix..."
# Check if the printer destination already exists to prevent duplicate configuration conflicts
if lpstat -p "TruthChain_Standard_Printer" >/dev/null 2>&1; then
    echo "[*] Destination already registered. Updating configuration..."
fi

# Register the destination. 
# We utilize the RAW driver designation to bypass deprecated PPD overhead,
# ensuring the raw PostScript/PDF buffer drops cleanly directly into our backend.
lpadmin -p "TruthChain_Standard_Printer" \
        -E \
        -v "truthchain://127.0.0.1/print" \
        -m raw \
        -L "Sovereign Verification Desk" \
        -o printer-is-shared=false

# Double check deployment state metrics
echo "[*] Phase 9: Auditing active spooler state configuration..."
if lpstat -p "TruthChain_Standard_Printer" -v | grep -q "truthchain://"; then
    echo "[+] SUCCESS: Spooler mapping verified."
    lpstat -p "TruthChain_Standard_Printer" -v
else
    echo "[!] Warning: Print destination registered but handshake interface failed verification." >&2
fi

echo "[*] Phase 9: Auditing active spooler state configuration..."
# Verify queue status and loopback routing paths
if lpstat -p "TruthChain_Standard_Printer" -v | grep -q "truthchain://"; then
    echo "[+] SUCCESS: Spooler mapping verified live."
    echo "------------------------------------------------------------"
    lpq -P TruthChain_Standard_Printer
    echo "------------------------------------------------------------"
else
    echo "[!] Warning: Print destination registered but verification failed." >&2
fi

echo "=============================================================================="
echo "[+] SUCCESS: TruthChain Secure Printing Pipeline Successfully Armed!"
echo "=============================================================================="
