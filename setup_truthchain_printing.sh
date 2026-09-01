#!/bin/bash
# ==============================================================================
# setup_truthchain_printing.sh — TruthChain CUPS Print Subsystem
# ORP Engine — Alpine Linux
# ==============================================================================
# Installs and configures the TruthChain virtual printer which pipes
# all print jobs through the ORP Engine /print endpoint.
#
# Every printed document is:
#   • SHA-256 fingerprinted
#   • Hash-chained (tamper-evident sequence)
#   • GPG-signed and archived to the LUKS vault
#   • Pushed to the GitHub Pages public ledger
#   • Saved as stamped PDF to ~/pdf_printed_archive/
#
# Usage:
#   doas bash setup_truthchain_printing.sh
# ==============================================================================

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[✘] Must be run as root: doas bash $0" >&2
    exit 1
fi

OPERATOR_USER="${DOAS_USER:-${SUDO_USER:-}}"
if [ -z "$OPERATOR_USER" ] || [ "$OPERATOR_USER" = "root" ]; then
    echo "[✘] Run via doas as your operator user: doas bash $0" >&2
    exit 1
fi

OPERATOR_HOME=$(eval echo ~"$OPERATOR_USER")
ENGINE_URL="http://127.0.0.1:5000/print"
ARCHIVE_DIR="$OPERATOR_HOME/pdf_printed_archive"
PRINTER_NAME="TruthChain"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  TruthChain Print Subsystem Setup"
echo "══════════════════════════════════════════════════════════════"
echo "  Operator : $OPERATOR_USER"
echo "  Home     : $OPERATOR_HOME"
echo "  Engine   : $ENGINE_URL"
echo "  Archive  : $ARCHIVE_DIR"
echo "  Printer  : $PRINTER_NAME"
echo "══════════════════════════════════════════════════════════════"
echo ""

# ── Phase 1: Install dependencies ────────────────────────────────
echo "[*] Phase 1: Installing CUPS and dependencies..."
apk update --quiet
apk add --no-cache \
    cups \
    cups-filters \
    cups-libs \
    ghostscript \
    curl \
    bash \
    file

echo "[✔] Packages installed."

# ── Phase 2: Directory structure ─────────────────────────────────
echo "[*] Phase 2: Creating directories..."
mkdir -p /usr/lib/cups/backend/
mkdir -p /var/log/cups/
mkdir -p /run/cups/
chmod 755 /run/cups/

mkdir -p "$ARCHIVE_DIR"
chown -R "$OPERATOR_USER:$OPERATOR_USER" "$ARCHIVE_DIR"
chmod 700 "$ARCHIVE_DIR"
echo "[✔] Archive directory: $ARCHIVE_DIR"

# ── Phase 3: Groups ───────────────────────────────────────────────
echo "[*] Phase 3: Configuring groups..."
getent group lpadmin > /dev/null || addgroup lpadmin
getent group lp      > /dev/null || addgroup lp

addgroup "$OPERATOR_USER" lpadmin 2>/dev/null || true
addgroup "$OPERATOR_USER" lp      2>/dev/null || true
addgroup root lpadmin              2>/dev/null || true

echo "[✔] $OPERATOR_USER added to lpadmin and lp groups."

# ── Phase 4: CUPS configuration ───────────────────────────────────
echo "[*] Phase 4: Writing CUPS configuration..."

cat > /etc/cups/cups-files.conf << 'CUPSFILES'
SystemGroup lpadmin sys root
PeerCred on
AccessLog /var/log/cups/access_log
ErrorLog /var/log/cups/error_log
PageLog /var/log/cups/page_log
CUPSFILES

cat > /etc/cups/cupsd.conf << 'CUPSDCONF'
Listen 127.0.0.1:631
Listen /run/cups/cups.sock
Browsing Off
LogLevel warn
MaxLogSize 1m

<Policy default>
  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job
         Purge-Jobs Set-Job-Attributes Create-Job-Subscription
         Renew-Subscription Cancel-Subscription Get-Notifications
         Reprocess-Job Cancel-Current-Job Suspend-Current-Job
         Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job
         CUPS-Get-Document>
    Require user @OWNER @SYSTEM
    Order allow,deny
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer
         CUPS-Add-Modify-Class CUPS-Delete-Class
         CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order allow,deny
  </Limit>

  <Limit All>
    Order allow,deny
  </Limit>
</Policy>
CUPSDCONF

echo "[✔] CUPS configuration written."

# ── Phase 5: TruthChain backend ───────────────────────────────────
echo "[*] Phase 5: Installing TruthChain backend..."

cat > /usr/lib/cups/backend/truthchain << BACKEND
#!/bin/bash
# TruthChain CUPS Backend — ORP Engine Integration
# Stamps every print job via the ORP Engine /print endpoint.
# Saves stamped PDF to $ARCHIVE_DIR automatically.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Device discovery — required by CUPS protocol
if [ -z "\$1" ]; then
    echo 'direct truthchain "Unknown" "TruthChain Secure Stamp Printer"'
    exit 0
fi

JOB_ID="\$1"
USER_NAME="\$2"
JOB_TITLE="\$3"
COPIES="\$4"
OPTIONS="\$5"
INPUT_FILE="\${6:-}"

ENGINE_URL="$ENGINE_URL"
ARCHIVE_DIR="$ARCHIVE_DIR"
OPERATOR="$OPERATOR_USER"
LOG_TAG="TRUTHCHAIN"

# Authorization check
if [ "\$USER_NAME" != "\$OPERATOR" ] && [ "\$USER_NAME" != "root" ]; then
    logger -t "\$LOG_TAG" "BLOCKED: Unauthorized job from \$USER_NAME"
    exit 1
fi

logger -t "\$LOG_TAG" "Job \$JOB_ID: '\$JOB_TITLE' from \$USER_NAME"

# Prepare temp files
TMP_IN=\$(mktemp /tmp/orp_print_in.XXXXXX)
TMP_OUT=\$(mktemp /tmp/orp_print_out.XXXXXX)

cleanup() { rm -f "\$TMP_IN" "\$TMP_OUT"; }
trap cleanup EXIT

# Get PDF input
if [ -n "\$INPUT_FILE" ] && [ -f "\$INPUT_FILE" ]; then
    cp "\$INPUT_FILE" "\$TMP_IN"
else
    cat > "\$TMP_IN"
fi

# Convert PostScript to PDF if needed
if command -v file > /dev/null 2>&1; then
    if file "\$TMP_IN" 2>/dev/null | grep -q "PostScript"; then
        TMP_PDF=\$(mktemp /tmp/orp_converted.XXXXXX.pdf)
        ps2pdf "\$TMP_IN" "\$TMP_PDF" 2>/dev/null && mv "\$TMP_PDF" "\$TMP_IN" \
            || rm -f "\$TMP_PDF"
    fi
fi

# Sanitize job title for doc_type field
DOC_TYPE=\$(echo "\$JOB_TITLE" \
    | tr '[:lower:]' '[:upper:]' \
    | tr -cs 'A-Z0-9' '-' \
    | sed 's/^-//;s/-\$//' \
    | cut -c1-20)
[ -z "\$DOC_TYPE" ] && DOC_TYPE="PRINT"

# POST to ORP Engine
HTTP_STATUS=\$(curl -s \
    -w "%{http_code}" \
    -o "\$TMP_OUT" \
    -X POST \
    -H "X-Print-Source: cups" \
    -H "X-Operator-ID: \$USER_NAME" \
    -H "X-Print-Job-Title: \$JOB_TITLE" \
    -F "document=@\${TMP_IN};type=application/pdf" \
    -F "doc_type=\${DOC_TYPE}" \
    "\$ENGINE_URL" 2>/dev/null)

if [ "\$HTTP_STATUS" = "200" ]; then
    # Save stamped PDF to archive
    STAMP_FILE="\${ARCHIVE_DIR}/Job_\${JOB_ID}_\${DOC_TYPE}.pdf"
    cp "\$TMP_OUT" "\$STAMP_FILE"
    chown "\$OPERATOR:\$OPERATOR" "\$STAMP_FILE" 2>/dev/null || true
    chmod 600 "\$STAMP_FILE"
    logger -t "\$LOG_TAG" "SUCCESS: Job \$JOB_ID → \$STAMP_FILE"
    exit 0
else
    BODY=\$(cat "\$TMP_OUT" 2>/dev/null | head -c 200)
    logger -t "\$LOG_TAG" "FAILED: Job \$JOB_ID HTTP=\$HTTP_STATUS body=\$BODY"
    exit 1
fi
BACKEND

chown root:root /usr/lib/cups/backend/truthchain
chmod 700 /usr/lib/cups/backend/truthchain
echo "[✔] Backend installed: /usr/lib/cups/backend/truthchain"

# ── Phase 6: Harden CUPS binaries ────────────────────────────────
echo "[*] Phase 6: Hardening CUPS binaries..."
for binary in lp lpr lpstat cancel cupsdisable cupsenable \
              lpadmin lpinfo lpmove lpoptions; do
    for dir in /usr/bin /usr/sbin; do
        if [ -f "$dir/$binary" ]; then
            chown root:lpadmin "$dir/$binary"
            chmod 750 "$dir/$binary"
        fi
    done
done
echo "[✔] CUPS binaries locked to lpadmin group."

# ── Phase 7: Start CUPS ───────────────────────────────────────────
echo "[*] Phase 7: Starting CUPS daemon..."
rc-update add cupsd default 2>/dev/null || true
rc-service cupsd restart
sleep 2

if ! rc-service cupsd status > /dev/null 2>&1; then
    echo "[✘] CUPS failed to start — check: /var/log/cups/error_log"
    exit 1
fi
echo "[✔] CUPS daemon running."

# ── Phase 8: Register TruthChain printer ─────────────────────────
echo "[*] Phase 8: Registering TruthChain printer..."

# Remove old registration if exists
lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
sleep 1

lpadmin -p "$PRINTER_NAME" \
    -E \
    -v "truthchain://localhost/stamp" \
    -m drv:///sample.drv/generic.ppd \
    -D "TruthChain Secure Stamp Printer" \
    -L "ORP Engine — Sovereign Verification" \
    -u "allow:$OPERATOR_USER" \
    -o printer-is-shared=false \
    -o media=A4 2>/dev/null || \
lpadmin -p "$PRINTER_NAME" \
    -E \
    -v "truthchain://localhost/stamp" \
    -P /usr/share/cups/model/Generic-PDF_Printer-PDF.ppd \
    -D "TruthChain Secure Stamp Printer" \
    -L "ORP Engine — Sovereign Verification" \
    -u "allow:$OPERATOR_USER" \
    -o printer-is-shared=false 2>/dev/null || \
lpadmin -p "$PRINTER_NAME" \
    -E \
    -v "truthchain://localhost/stamp" \
    -D "TruthChain Secure Stamp Printer" \
    -L "ORP Engine — Sovereign Verification" \
    -u "allow:$OPERATOR_USER" \
    -o printer-is-shared=false

# Set as system default
lpadmin -d "$PRINTER_NAME"

echo "[✔] Printer registered: $PRINTER_NAME"

# ── Phase 9: Verify ───────────────────────────────────────────────
echo ""
echo "[*] Phase 9: Verification..."
sleep 1

lpstat -p "$PRINTER_NAME" -v 2>/dev/null && \
    echo "[✔] Printer status confirmed." || \
    echo "[!] lpstat check failed — may need group re-login."

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  ✅ TruthChain Print Subsystem Ready"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Printer name : $PRINTER_NAME (system default)"
echo "  Backend      : /usr/lib/cups/backend/truthchain"
echo "  Archive dir  : $ARCHIVE_DIR"
echo "  Engine URL   : $ENGINE_URL"
echo ""
echo "  Usage:"
echo "    Ctrl+P in browser → select '$PRINTER_NAME' → Print"
echo "    Stamped PDF saved to: $ARCHIVE_DIR"
echo ""
echo "  ⚠️  You may need to log out and back in for group"
echo "     membership changes (lpadmin, lp) to take effect."
echo ""
echo "  To test:"
echo "    lp -d $PRINTER_NAME /path/to/document.pdf"
echo ""
