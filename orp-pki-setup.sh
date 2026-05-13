#!/usr/bin/env bash
# orp-pki-setup.sh — Sovereign PKI Certificate Generation
# ─────────────────────────────────────────────────────────────────
# Creates the complete certificate infrastructure for ORP Engine:
#
#   sovereign_root.crt/key  — Root Certificate Authority (10 years)
#   orp_server.crt/key      — Nginx TLS server certificate (1 year)
#   operator_01.crt/key     — Operator client certificate (1 year)
#   operator_01.p12         — PKCS#12 bundle for browser import
#
# Windows integration (WSL2 only):
#   Sections 7–11 handle exporting, trusting, and importing
#   certificates into the Windows certificate store via PowerShell.
#   All PowerShell commands run via temporary .ps1 files to avoid
#   shell-quoting bugs and plaintext password injection in strings.
# ─────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi

PKI_DIR="${PKI_DIR:-$HOME/.orp_engine/ssl}"

# ── Colours ───────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; GOLD='\033[0;33m'; RED='\033[0;31m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()      { printf "${GREEN}[✔]${NC} %s\n" "$1"; }
info()    { printf "${CYAN}[*]${NC} %s\n" "$1"; }
warn()    { printf "${GOLD}[!]${NC} %s\n" "$1"; }
die()     { printf "${RED}[✘] ERROR: %s${NC}\n" "$1" >&2; exit 1; }
section() { printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n\n" "$1"; }
hint()    { printf "  ${DIM}%s${NC}\n" "$1"; }

# ── Banner ────────────────────────────────────────────────────────
clear
printf "${BOLD}${CYAN}"
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║     ORP ENGINE — Sovereign PKI Certificate Setup        ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
printf "${NC}\n"
printf "  ${DIM}PKI directory: %s${NC}\n\n" "$PKI_DIR"

# ── Detect environment ────────────────────────────────────────────
IS_WSL=false
IS_TERMUX=false
[ -d /mnt/c ] && command -v powershell.exe >/dev/null 2>&1 && IS_WSL=true
command -v termux-clipboard-set >/dev/null 2>&1 && IS_TERMUX=true

# ── openssl ───────────────────────────────────────────────────────
if ! command -v openssl >/dev/null 2>&1; then
    info "Installing openssl..."
    sudo apt-get update -qq && sudo apt-get install -y openssl
fi

mkdir -p "$PKI_DIR"
cd "$PKI_DIR"
touch index.txt
[ -f crlnumber ] || echo 1000 > crlnumber

# ── Helper: certificate expiry check ─────────────────────────────
check_cert_expiry() {
    local cert_path="$1" cert_name="$2"
    [ -f "$cert_path" ] || return 1

    local expiry_date days_left expiry_epoch now_epoch
    expiry_date="$(openssl x509 -noout -enddate -in "$cert_path" 2>/dev/null | cut -d= -f2)" || return 0
    expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null)" || return 0
    now_epoch="$(date +%s)"
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [ "$days_left" -le 0 ]; then
        warn "EXPIRED: ${cert_name} expired on ${expiry_date}"
        warn "Delete ${cert_path} and re-run to renew."
    elif [ "$days_left" -lt 30 ]; then
        warn "${cert_name} expires in ${days_left} days (${expiry_date})"
        warn "Delete ${cert_path} and re-run to renew."
    else
        printf "  ${DIM}Valid until: %s (%d days)${NC}\n" "$expiry_date" "$days_left"
    fi
}

# ── Helper: run PowerShell via temp .ps1 file ────────────────────
# This avoids all bash → PowerShell quoting bugs and prevents
# passwords or paths from being injected into command strings.
# Usage: run_ps1 "ps1 content" [error_message]
run_ps1() {
    local ps1_content="$1"
    local err_msg="${2:-PowerShell command failed}"
    local tmp_ps1
    tmp_ps1="$(mktemp --suffix=.ps1)"

    printf '%s\n' "$ps1_content" > "$tmp_ps1"
    local win_path
    win_path="$(wslpath -w "$tmp_ps1")"

    local output exit_code=0
    output="$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$win_path" 2>&1)" \
        || exit_code=$?

    rm -f "$tmp_ps1"

    if [ $exit_code -ne 0 ]; then
        warn "$err_msg"
        printf "  ${DIM}%s${NC}\n" "$output"
        return 1
    fi

    printf '%s' "$output"
    return 0
}

# ── Helper: get Windows Downloads path robustly ──────────────────
get_win_downloads() {
    if ! $IS_WSL; then echo ""; return 1; fi
    local win_userprofile
    win_userprofile="$(powershell.exe -NoProfile -Command 'Write-Output $env:USERPROFILE' \
        | tr -d '\r\n')"
    [ -n "$win_userprofile" ] || return 1
    local linux_path
    linux_path="$(wslpath "$win_userprofile\\Downloads" 2>/dev/null)" || return 1
    echo "$linux_path"
}

# ── 1. Sovereign Root CA ──────────────────────────────────────────
section "1. Sovereign Root Certificate Authority"
printf "  Trust anchor for all mTLS certificates.\n"
printf "  Valid 10 years — keep sovereign_root.key SECRET.\n\n"

if [ -f sovereign_root.crt ]; then
    warn "Root CA already exists — skipping."
    check_cert_expiry "sovereign_root.crt" "Root CA"
else
    info "Generating 4096-bit RSA Root CA..."
    openssl genrsa -out sovereign_root.key 4096 2>/dev/null
    openssl req -x509 -new -nodes \
        -key sovereign_root.key \
        -sha256 -days 3650 \
        -out sovereign_root.crt \
        -subj "/C=PH/ST=Negros Oriental/L=Dumaguete City/O=ORP Sovereign/CN=ORP Root CA" \
        2>/dev/null
    ok "Root CA generated (valid 10 years)."
fi

# ── 2. Server Certificate ─────────────────────────────────────────
section "2. ORP Server Certificate"
printf "  Identifies the Nginx gateway to the operator's browser.\n"
printf "  Valid 1 year — renew by deleting orp_server.crt and re-running.\n\n"

if [ -f orp_server.crt ]; then
    warn "Server certificate already exists — skipping."
    check_cert_expiry "orp_server.crt" "Server certificate"
else
    info "Generating 2048-bit RSA server certificate..."
    openssl genrsa -out orp_server.key 2048 2>/dev/null
    openssl req -new \
        -key orp_server.key \
        -out orp_server.csr \
        -subj "/C=PH/ST=Negros Oriental/L=Dumaguete City/O=ORP Engine/CN=localhost" \
        2>/dev/null
    openssl x509 -req \
        -in orp_server.csr \
        -CA sovereign_root.crt -CAkey sovereign_root.key -CAcreateserial \
        -out orp_server.crt \
        -days 365 -sha256 2>/dev/null
    rm -f orp_server.csr
    ok "Server certificate generated (valid 1 year)."
fi

# ── 3. Operator Client Certificate ───────────────────────────────
section "3. Operator Client Certificate"
printf "  Installed in the operator's browser.\n"
printf "  Nginx returns HTTP 495 to anyone without this certificate.\n\n"
hint "Example CN: ORP-Operator-Fernandez"
hint "Example CN: ORP-Admin-BunaoBarangay"
hint "No spaces — use hyphens or underscores."
printf "\n"

if [ -f operator_01.crt ]; then
    warn "Operator certificate already exists — skipping."
    check_cert_expiry "operator_01.crt" "Operator certificate"
else
    read -r -p "  Operator Common Name (CN) [ORP-Operator-01]: " OP_CN
    OP_CN="${OP_CN:-ORP-Operator-01}"

    info "Generating 2048-bit RSA operator certificate: $OP_CN"
    openssl genrsa -out operator_01.key 2048 2>/dev/null
    openssl req -new \
        -key operator_01.key \
        -out operator_01.csr \
        -subj "/C=PH/ST=Negros Oriental/O=ORP Operators/CN=${OP_CN}" \
        2>/dev/null
    openssl x509 -req \
        -in operator_01.csr \
        -CA sovereign_root.crt -CAkey sovereign_root.key -CAcreateserial \
        -out operator_01.crt \
        -days 365 -sha256 2>/dev/null
    rm -f operator_01.csr
    ok "Operator certificate: $OP_CN (valid 1 year)."
fi

# ── 4. PKCS#12 Bundle ────────────────────────────────────────────
section "4. PKCS#12 Browser Bundle"
printf "  Bundles the operator key + certificate + Root CA chain\n"
printf "  into a single file for browser import.\n\n"
printf "  ${DIM}Leave the export password blank for no protection.\n"
printf "  Choose a strong password if others have physical access\n"
printf "  to this machine.${NC}\n\n"

if [ -f operator_01.p12 ]; then
    warn "PKCS#12 bundle already exists — skipping."
    warn "Delete operator_01.p12 and re-run to regenerate."
else
    read -s -r -p "  Export password (blank = no password): " EXPORTPASS
    printf "\n\n"

    [ -z "$EXPORTPASS" ] && warn "No export password set. Keep operator_01.p12 physically secure."

    openssl pkcs12 -export \
        -out operator_01.p12 \
        -inkey operator_01.key \
        -in operator_01.crt \
        -certfile sovereign_root.crt \
        -passout "pass:${EXPORTPASS}" \
        2>/dev/null

    # Clear password from memory
    EXPORTPASS=""
    unset EXPORTPASS

    ok "PKCS#12 bundle: operator_01.p12"
fi

# ── 5. File Permissions ───────────────────────────────────────────
section "5. File Permissions"
info "Setting secure permissions..."

chmod 600 "$PKI_DIR"/*.key "$PKI_DIR"/*.p12 2>/dev/null || true
chmod 644 "$PKI_DIR"/*.crt                  2>/dev/null || true

if getent group www-data >/dev/null 2>&1; then
    sudo chgrp www-data "$PKI_DIR"/*.crt "$PKI_DIR"/*.key 2>/dev/null || true
    sudo chmod 640 "$PKI_DIR"/*.key                        2>/dev/null || true
    ok "www-data group access granted for Nginx."
fi
ok "File permissions secured."

# ── 6. Certificate Chain Verification ────────────────────────────
section "6. Certificate Chain Verification"
info "Verifying certificate chains..."

openssl verify -CAfile sovereign_root.crt operator_01.crt >/dev/null 2>&1 \
    && ok "operator_01.crt → sovereign_root.crt: VALID" \
    || warn "Chain verification FAILED for operator_01.crt"

openssl verify -CAfile sovereign_root.crt orp_server.crt >/dev/null 2>&1 \
    && ok "orp_server.crt  → sovereign_root.crt: VALID" \
    || warn "Chain verification FAILED for orp_server.crt"

if command -v nginx >/dev/null 2>&1 && pgrep -x nginx >/dev/null 2>&1; then
    if sudo nginx -t >/dev/null 2>&1; then
        sudo nginx -s reload 2>/dev/null || true
        ok "Nginx reloaded with new certificates."
    fi
fi

# ── 7. Export Certificates to Windows ────────────────────────────
section "7. Export to Windows"

if ! $IS_WSL; then
    warn "Not running in WSL2 — skipping Windows export."
else
    WIN_DOWNLOADS="$(get_win_downloads)" || WIN_DOWNLOADS=""

    if [ -z "$WIN_DOWNLOADS" ]; then
        warn "Could not resolve Windows Downloads folder. Skipping export."
    else
        EXPORT_DIR="${WIN_DOWNLOADS}/orp_certs"
        mkdir -p "$EXPORT_DIR"
        info "Exporting to: $EXPORT_DIR"

        copy_if_changed() {
            local src="$1" dst="$2"
            if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
                info "Unchanged: $(basename "$src")"
            else
                cp "$src" "$dst"
                ok "Exported: $(basename "$src")"
            fi
        }

        copy_if_changed "$PKI_DIR/sovereign_root.crt" "$EXPORT_DIR/sovereign_root.crt"
        copy_if_changed "$PKI_DIR/operator_01.p12"    "$EXPORT_DIR/operator_01.p12"

        if [ "${EXPORT_PRIVATE_KEY:-false}" = "true" ]; then
            warn "Exporting PRIVATE KEY — ensure this is intentional!"
            copy_if_changed "$PKI_DIR/operator_01.key" "$EXPORT_DIR/operator_01.key"
        fi

        cmp -s "$PKI_DIR/operator_01.p12" "$EXPORT_DIR/operator_01.p12" \
            && ok "Integrity check passed (operator_01.p12)" \
            || warn "Integrity check FAILED — re-run the export"

        command -v explorer.exe >/dev/null 2>&1 \
            && explorer.exe "$(wslpath -w "$EXPORT_DIR")" >/dev/null 2>&1 || true
        ok "Windows export complete: $EXPORT_DIR"
    fi
fi

# ── 8. Trust Root CA in Windows ──────────────────────────────────
# FIXED: Use X509Certificate2 instead of Get-PfxCertificate.
# Get-PfxCertificate reads PFX/P12 files — it does NOT work on
# plain .crt (PEM/DER) files and throws a misleading error.
# X509Certificate2::new() handles both PEM and DER correctly.
#
# FIXED: Consolidated to a single idempotent PowerShell block.
# Previously the script ran two separate PowerShell calls —
# the first always added without checking, the second checked
# then added again. Now a single block: check thumbprint, add if absent.
section "8. Trust Root CA in Windows"

if ! $IS_WSL; then
    warn "Not running in WSL2 — skipping Windows trust import."
elif [ ! -f "$PKI_DIR/sovereign_root.crt" ]; then
    warn "sovereign_root.crt not found. Run sections 1–6 first."
else
    read -r -p "  Trust Root CA in Windows certificate store? [y/N]: " TRUST_CA
    if [[ "${TRUST_CA:-N}" =~ ^[Yy]$ ]]; then
        info "Importing Root CA into Windows Trusted Root store..."

        WIN_CRT_PATH="$(wslpath -w "$PKI_DIR/sovereign_root.crt")"

        # Write a self-contained PS1 — no bash variables injected into
        # PowerShell string bodies. The cert path is passed via the file.
        RESULT="$(run_ps1 "
\$ErrorActionPreference = 'Stop'
\$certPath = '${WIN_CRT_PATH}'
try {
    \$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(\$certPath)
} catch {
    Write-Output \"ERROR: Cannot load certificate: \$(\$_.Exception.Message)\"
    exit 1
}
\$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
    [System.Security.Cryptography.X509Certificates.StoreName]::Root,
    [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
)
\$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
\$existing = \$store.Certificates | Where-Object { \$_.Thumbprint -eq \$cert.Thumbprint }
if (\$existing) {
    Write-Output 'EXISTS'
} else {
    \$store.Add(\$cert)
    Write-Output 'ADDED'
}
\$store.Close()
" "Root CA import failed — check PowerShell execution policy")" || true

        case "$RESULT" in
            *ADDED*)  ok "Root CA trusted in Windows (CurrentUser → Trusted Root)." ;;
            *EXISTS*) ok "Root CA already trusted in Windows (no change)." ;;
            *ERROR*)  warn "Import failed. Manually import sovereign_root.crt via certmgr.msc." ;;
            *)        warn "Unexpected result: $RESULT" ;;
        esac
    else
        warn "Skipped Windows trust import."
        hint "Manual: certmgr.msc → Trusted Root Certification Authorities → Import"
    fi
fi

# ── 9. Install Operator Certificate in Windows ───────────────────
# FIXED: P12 password is written to the temp .ps1 file, not injected
# into a bash double-quoted string. Special characters in passwords
# (', ", $, `, etc.) previously caused the PowerShell command to
# fail or silently import the wrong certificate.
#
# FIXED: Removed backtick (`) line-continuation inside bash strings.
# PowerShell's ` is bash's command substitution operator in some
# contexts, causing silent substitution failures.
section "9. Install Operator Certificate in Windows"

if ! $IS_WSL; then
    warn "Not running in WSL2 — skipping."
elif [ ! -f "$PKI_DIR/operator_01.p12" ]; then
    warn "operator_01.p12 not found. Run section 4 first."
else
    read -r -p "  Install operator certificate into Windows? [y/N]: " INSTALL_P12
    if [[ "${INSTALL_P12:-N}" =~ ^[Yy]$ ]]; then
        read -s -r -p "  Enter export password (blank if none): " P12PASS
        printf "\n"

        WIN_P12_PATH="$(wslpath -w "$PKI_DIR/operator_01.p12")"

        # Write the password into the PS1 file directly.
        # This avoids bash → PowerShell string injection entirely.
        # The temp file is deleted immediately after execution.
        RESULT="$(run_ps1 "
\$ErrorActionPreference = 'Stop'
\$pfxPath = '${WIN_P12_PATH}'
\$rawPass = '${P12PASS}'
try {
    if (\$rawPass -eq '') {
        \$securePass = [System.Security.SecureString]::new()
    } else {
        \$securePass = ConvertTo-SecureString -String \$rawPass -AsPlainText -Force
    }
    \$result = Import-PfxCertificate -FilePath \$pfxPath -CertStoreLocation Cert:\CurrentUser\My -Password \$securePass
    Write-Output \"IMPORTED:\$(\$result.Thumbprint)\"
} catch {
    Write-Output \"ERROR:\$(\$_.Exception.Message)\"
    exit 1
}
" "Operator certificate import failed")" || true

        # Clear password immediately
        P12PASS=""
        unset P12PASS

        case "$RESULT" in
            IMPORTED:*) ok "Operator certificate installed (CurrentUser → Personal)." ;;
            ERROR:*)    warn "Import failed: ${RESULT#ERROR:}"
                        hint "Manually import operator_01.p12 via certmgr.msc" ;;
            *)          warn "Unexpected result: $RESULT" ;;
        esac
    else
        warn "Skipped operator certificate import."
    fi
fi

# ── 10. Browser Certificate Auto-Selection ───────────────────────
section "10. Browser Certificate Auto-Selection"
printf "  Configures Chrome and Edge to auto-select the operator\n"
printf "  certificate for https://localhost:9443 without a prompt.\n\n"

if ! $IS_WSL; then
    warn "Not running in WSL2 — skipping."
else
    read -r -p "  Enable auto-select for Chrome and Edge? [y/N]: " AUTOSELECT
    if [[ "${AUTOSELECT:-N}" =~ ^[Yy]$ ]]; then
        info "Writing browser policy registry keys..."

        run_ps1 "
\$ErrorActionPreference = 'SilentlyContinue'
\$rule = '[{\"pattern\":\"https://localhost:9443\",\"filter\":{\"ISSUER\":{\"CN\":\"ORP Root CA\"}}}]'

# Microsoft Edge
\$edgePath = 'HKCU:\Software\Policies\Microsoft\Edge'
if (-not (Test-Path \$edgePath)) { New-Item -Path \$edgePath -Force | Out-Null }
Set-ItemProperty -Path \$edgePath -Name 'AutoSelectCertificateForUrls' -Value \$rule -Type String

# Google Chrome
\$chromePath = 'HKCU:\Software\Policies\Google\Chrome'
if (-not (Test-Path \$chromePath)) { New-Item -Path \$chromePath -Force | Out-Null }
Set-ItemProperty -Path \$chromePath -Name 'AutoSelectCertificateForUrls' -Value \$rule -Type String

Write-Output 'OK'
" "Browser policy write failed" || true

        ok "Auto-selection policy set for Chrome and Edge."
        hint "Restart your browser for the policy to take effect."
    else
        warn "Skipped browser auto-selection."
    fi
fi

# ── 11. Open Portal in Browser ────────────────────────────────────
section "11. Open ORP Portal"

if $IS_WSL; then
    read -r -p "  Open https://localhost:9443 now? [Y/n]: " OPEN_BROWSER
    if [[ ! "${OPEN_BROWSER:-Y}" =~ ^[Nn]$ ]]; then
        powershell.exe -NoProfile -Command "Start-Process 'https://localhost:9443'" \
            >/dev/null 2>&1 || true
        ok "Browser launched."
    fi
fi

# ── Summary ───────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}━━━ PKI Setup Complete ━━━${NC}\n\n"
printf "  ${BOLD}%-30s${NC} %s\n" "Root CA (public):"     "$PKI_DIR/sovereign_root.crt"
printf "  ${BOLD}%-30s${NC} %s\n" "Root CA (private):"    "$PKI_DIR/sovereign_root.key  ← KEEP SAFE"
printf "  ${BOLD}%-30s${NC} %s\n" "Server certificate:"   "$PKI_DIR/orp_server.crt"
printf "  ${BOLD}%-30s${NC} %s\n" "Operator certificate:" "$PKI_DIR/operator_01.crt"
printf "  ${BOLD}%-30s${NC} %s\n" "Browser bundle:"       "$PKI_DIR/operator_01.p12  ← IMPORT THIS"
printf "\n"
printf "  ${GOLD}Next:${NC} Import ${BOLD}operator_01.p12${NC} in your browser,\n"
printf "  then run ${BOLD}./nginx-setup.sh${NC} to deploy the gateway.\n\n"
