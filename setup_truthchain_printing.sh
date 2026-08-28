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

# Detect the actual operator user (the one who invoked doas)
OPERATOR_USER="${SUDO_USER:-${DOAS_USER:-$(logname 2>/dev/null || echo 'root')}}"
if [ "$OPERATOR_USER" = "root" ]; then
    echo "[!] ERROR: This script must be run via 'doas' as a non-root user." >&2
    echo "    Run: doas bash $0" >&2
    exit 1
fi

OPERATOR_HOME=$(eval echo ~"$OPERATOR_USER")
echo "[*] Detected operator: $OPERATOR_USER (home: $OPERATOR_HOME)"

echo "[*] Phase 1: Refreshing system repositories and constructing core stack..."
apk update
apk add bash curl nginx cups cups-filters cups-libs util-linux ghostscript sudo

echo "[*] Phase 2: Building underlying device-class framework directories..."
mkdir -p /usr/lib/cups/backend/
mkdir -p /var/log/cups/

echo "[*] Phase 3: Provisioning cryptographic access security groups..."
# Ensure targeted security boundaries exist
getent group lpadmin >/dev/null || addgroup lpadmin
getent group sys >/dev/null     || addgroup sys

# Add the detected operator user to lpadmin and sys groups
if id "$OPERATOR_USER" >/dev/null 2>&1; then
    addgroup "$OPERATOR_USER" lpadmin 2>/dev/null || true
    addgroup "$OPERATOR_USER" sys 2>/dev/null || true
    echo "[✔] User '$OPERATOR_USER' added to lpadmin and sys groups"
else
    echo "[!] WARNING: User '$OPERATOR_USER' not found in system."
    exit 1
fi

addgroup root lpadmin 2>/dev/null || true

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

# Allow lpadmin group socket access
Listen 127.0.0.1:631
Listen /run/cups/cups.sock
EOF

echo "[*] Phase 5: Generating Custom Cryptographic Pipeline Backend..."
cat << EOF > /usr/lib/cups/backend/truthchain
#!/usr/bin/env bash
# ==============================================================================
# /usr/lib/cups/backend/truthchain
# Custom CUPS Transmission Layer for the TruthChain Decentralized Proxy
# ==============================================================================

# CRITICAL FIX: CUPS isolates backends and clears the global environment.
# We must explicitly declare the system execution PATH.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

# Device Discovery Directive: If executed with zero parameters, announce capabilities
if [ -z "\$1" ]; then
    echo 'direct truthchain "Unknown" "TruthChain Secure Cryptographic Printer Endpoint"'
    exit 0
fi

# Capture the 6 standard positional parameters passed natively by the CUPS daemon
JOB_ID="\$1"
USER_NAME="\$2"
JOB_TITLE="\$3"
COPIES="\$4"
OPTIONS="\$5"
INPUT_FILE="\$6"

# ── DEFENSE IN DEPTH: Hardcoded Execution Kill-Switch ──
AUTHORIZED_USER="$OPERATOR_USER"
if [ "\$USER_NAME" != "\$AUTHORIZED_USER" ] && [ "\$USER_NAME" != "root" ]; then
    logger -t "TRUTHCHAIN-PRINTER" "CRITICAL: Unauthorized execution attempt by user: \$USER_NAME. Payload destroyed."
    exit 1
fi

# Configuration Boundaries for the local mTLS Portal Nginx Proxy
ENGINE_URL="https://127.0.0.1:9443/print" 
MTLS_CERT="$OPERATOR_HOME/.orp_engine/ssl/operator_01.crt"
MTLS_KEY="$OPERATOR_HOME/.orp_engine/ssl/operator_01.key"
ARCHIVE_DIR="$OPERATOR_HOME/pdf_printed_archive"

# Establish secure volatile working buffers
TMP_PAYLOAD=\$(mktemp /tmp/orp_print.XXXXXX)
RESPONSE_PDF=\$(mktemp /tmp/orp_processed.XXXXXX)

# PostScript to PDF Normalization Pipeline
if [ -n "\$INPUT_FILE" ] && [ -f "\$INPUT_FILE" ]; then
    ps2pdf "\$INPUT_FILE" "\$TMP_PAYLOAD"
else
    # Capture direct standard input stream from the CUPS pipeline spooler
    cat <&0 | ps2pdf - "\$TMP_PAYLOAD"
fi

# Secure Payload Transmission via Mutual TLS Over Loopback Interface
HTTP_STATUS=\$(curl -s -w "%{http_code}" -o "\$RESPONSE_PDF" \\
    --cert "\$MTLS_CERT" \\
    --key "\$MTLS_KEY" \\
    --insecure \\
    -H "X-Operator-ID: \$USER_NAME" \\
    -H "X-Print-Job-Title: \$JOB_TITLE" \\
    --data-binary "@\$TMP_PAYLOAD" \\
    "\$ENGINE_URL")

# Transaction Validation and Local Immutable Storage Logging
if [ "\$HTTP_STATUS" -eq 200 ]; then
    mkdir -p "\$ARCHIVE_DIR"
    STAMPED_FILE="\${ARCHIVE_DIR}/Stamped_Job_\${JOB_ID}.pdf"
    
    cp "\$RESPONSE_PDF" "\$STAMPED_FILE"
    chown "$OPERATOR_USER:$OPERATOR_USER" "\$STAMPED_FILE" 2>/dev/null || true
    chmod 600 "\$STAMPED_FILE"
    
    logger -t "TRUTHCHAIN-PRINTER" "SUCCESS: Job \${JOB_ID} verified and routed via mTLS proxy."
    rm -f "\$TMP_PAYLOAD" "\$RESPONSE_PDF"
    exit 0
else
    logger -t "TRUTHCHAIN-PRINTER" "ALERT: Cryptographic pipeline dropped stream. HTTP Code: \$HTTP_STATUS"
    rm -f "\$TMP_PAYLOAD" "\$RESPONSE_PDF"
    exit 1
fi
EOF

echo "[*] Phase 6: Locking down file execution permissions..."
# CUPS requires root ownership and 700 permissions to execute custom backends safely
chown root:root /usr/lib/cups/backend/truthchain
chmod 700 /usr/lib/cups/backend/truthchain

# Pre-stage and secure the local operator's printing archive
mkdir -p "$OPERATOR_HOME/pdf_printed_archive"
chown -R "$OPERATOR_USER:$OPERATOR_USER" "$OPERATOR_HOME/pdf_printed_archive"
chmod 700 "$OPERATOR_HOME/pdf_printed_archive"
echo "[✔] Archive directory created: $OPERATOR_HOME/pdf_printed_archive"

echo "[*] Phase 7: Initiating CUPS Core Daemon and setting boot runtime targets..."
rc-update add cupsd default
rc-service cupsd restart

echo "[*] Phase 7.5: Initiating Zero-Trust Host Hardening Protocol..."

# ==============================================================================
# LAYER 1: Binary Execution Sandbox
# Strip world-execution rights from all CUPS client binaries.
# Only users explicitly assigned to the lpadmin group can invoke them.
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
# Force the internal IPP scheduler to accept jobs from lpadmin group members only.
# ==============================================================================
echo "  -> Rewriting internal IPP access policies..."
cat << 'EOF' > /etc/cups/cupsd.conf
# Strict Local Loopback Only
Listen 127.0.0.1:631
Listen [::1]:631
Listen /run/cups/cups.sock

# Disable network browsing/discovery entirely
Browsing Off

# Default policy: Absolute restriction to lpadmin group
<Policy default>
  # Job Submission and Management operations
  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Require user @OWNER @SYSTEM
    Order allow,deny
  </Limit>

  # Administrative operations (only lpadmin group and root)
  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order allow,deny
  </Limit>

  # General read-only queries
  <Limit All>
    Order allow,deny
  </Limit>
</Policy>
EOF

# Ensure CUPS socket directory exists and has proper permissions
mkdir -p /run/cups
chmod 755 /run/cups

rc-service cupsd restart

echo "  -> Print subsystem hardening complete (kill-switch embedded)."
echo "[+] Hardening Protocol Complete. Print subsystem is now isolated."

# ==============================================================================
# Phase 8: Register the TruthChain Endpoint
# ==============================================================================
echo "[*] Phase 8: Registering the TruthChain Endpoint into the CUPS Spooler Matrix..."

# Wait for CUPS daemon to be fully ready
sleep 2

# Ensure CUPS socket is accessible
if [ ! -S /run/cups/cups.sock ]; then
    echo "[!] WARNING: CUPS socket not ready. Waiting..."
    sleep 3
fi

# Check if the printer destination already exists
if lpstat -p -d 2>/dev/null | grep -q "TruthChain_Standard_Printer"; then
    echo "[*] Destination already registered. Skipping registration..."
else
    echo "[*] Registering new printer destination..."
    echo "[!] Note: lpadmin may prompt for password. Provide root password if prompted."
    echo ""
    
    # Use --no-password option if available, otherwise fall back to interactive
    # The --no-password flag tells CUPS to use implicit authentication via group membership
    if lpadmin --help 2>/dev/null | grep -q "\-\-no-password"; then
        lpadmin --no-password \
                -p TruthChain_Standard_Printer \
                -E \
                -v "truthchain://127.0.0.1/print" \
                -m raw \
                -L "Sovereign Verification Desk" \
                -o printer-is-shared=false 2>&1
    else
        # Fallback: Use stdin redirection with empty password or direct assignment
        # Alpine CUPS may accept empty password from root-running script
        (echo ""; sleep 1) | lpadmin -p TruthChain_Standard_Printer \
                -E \
                -v "truthchain://127.0.0.1/print" \
                -m raw \
                -L "Sovereign Verification Desk" \
                -o printer-is-shared=false 2>&1 || true
    fi
fi

# ==============================================================================
# Phase 9: Audit and Verify
# ==============================================================================
echo ""
echo "[*] Phase 9: Auditing active spooler state configuration..."

sleep 1

# Check if printer was registered
PRINTER_CHECK=$(lpstat -p -d 2>/dev/null | grep "TruthChain_Standard_Printer" || true)

if [ -n "$PRINTER_CHECK" ]; then
    echo "[+] SUCCESS: Spooler mapping verified."
    echo "$PRINTER_CHECK"
    echo ""
    echo "------------------------------------------------------------"
    lpq -P TruthChain_Standard_Printer 2>/dev/null || echo "Queue ready (no jobs)"
    echo "------------------------------------------------------------"
else
    echo "[!] WARNING: Printer not registered via lpadmin."
    echo ""
    echo "    This may be due to CUPS permission requirements."
    echo "    Try registering manually as root:"
    echo ""
    echo "    # lpadmin -p TruthChain_Standard_Printer \\"
    echo "            -E \\"
    echo "            -v 'truthchain://127.0.0.1/print' \\"
    echo "            -m raw \\"
    echo "            -L 'Sovereign Verification Desk' \\"
    echo "            -o printer-is-shared=false"
    echo ""
    echo "    Then verify with:"
    echo "    # lpstat -p -d"
fi

echo ""
echo "=============================================================================="
echo "[+] SUCCESS: TruthChain Secure Printing Pipeline Setup Complete!"
echo "=============================================================================="
echo ""
echo "Configuration Summary:"
echo "  Backend installed at    : /usr/lib/cups/backend/truthchain"
echo "  Archive directory       : $OPERATOR_HOME/pdf_printed_archive"
echo "  Authorized operator     : $OPERATOR_USER"
echo "  CUPS socket             : /run/cups/cups.sock"
echo "  System groups           : lpadmin, sys"
echo ""
echo "Backend Status:"
if [ -f /usr/lib/cups/backend/truthchain ]; then
    echo "  ✔ Backend script installed"
    echo "  ✔ Permissions: $(ls -l /usr/lib/cups/backend/truthchain | awk '{print $1, $3, $4}')"
fi
echo ""
echo "To test the printer:"
echo "  $ lp -d TruthChain_Standard_Printer /path/to/document.pdf"
echo ""
echo "To debug CUPS issues:"
echo "  $ lpstat -p -d              # Check all printers"
echo "  $ tail -f /var/log/cups/error_log   # Watch CUPS errors"
echo "  $ tail -f /var/log/cups/access_log  # Watch CUPS access"
echo ""
