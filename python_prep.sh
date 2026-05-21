#!/bin/bash
# python_prep.sh — Alpine Secure Python Virtual Environment Setup
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
REQ_IN="$SCRIPT_DIR/requirements.in"
REQ_FILE="$SCRIPT_DIR/requirements.txt"
CA_CERT="/etc/ssl/certs/ca-certificates.crt"                PIP_LOG="$SCRIPT_DIR/pip-secure.log"
                                                            echo "[*] Initializing Python Environment Setup"
                                                            # ── 1. System Dependencies ─────────────────────────────────────────                                                   echo "[*] Ensuring required Alpine system packages are installed..."
apk add --no-cache python3 py3-pip py3-virtualenv libmagic ca-certificates gnupg libffi-dev git
                                                            if [ ! -f "$CA_CERT" ]; then
    echo "[✘] ERROR: CA certificate bundle not found at $CA_CERT" >&2
    exit 1
fi

[ -f "$REQ_IN" ] || { echo "[✘] ERROR: $REQ_IN missing" >&2; exit 1; }

# ── 2. Virtual Environment ─────────────────────────────────────────
if [ -d "$VENV_DIR" ]; then
    echo "[!] Virtual environment already exists at $VENV_DIR"
else
    echo "[*] Creating virtual environment..."                  python3 -m venv "$VENV_DIR" || { echo "[✘] ERROR: venv creation failed"; exit 1; }
fi                                                                                                                      if [ -f "$VENV_DIR/bin/activate" ]; then
    . "$VENV_DIR/bin/activate"                                  echo "[✔] Activated venv at $VENV_DIR"
    echo "[*] Python inside venv: $(which python3)"
else
    echo "[✘] ERROR: activate script missing at $VENV_DIR/bin/activate" >&2                                                 exit 1
fi                                                          
# ── 3. Upgrade core tools ──────────────────────────────────────────
echo "[*] Upgrading core tools..."                          python3 -m pip install --quiet --upgrade pip setuptools wheel                                                           
# ── 4. Bootstrap Pin Check ─────────────────────────────────────────
MISSING_PINS=""
for PKG in pip setuptools wheel; do
    if ! grep -iq "^${PKG}==" "$REQ_IN"; then                       MISSING_PINS="$MISSING_PINS $PKG"
    fi
done                                                        
if [ -n "$MISSING_PINS" ]; then
    echo "[*] Auto-pinning missing bootstraps:$MISSING_PINS"
    PIP_VER="$(python3 -m pip --version | awk '{print $2}')"
    PY_OUT=$(python3 -c 'import setuptools, wheel; print(f"{setuptools.__version__} {wheel.__version__}")')
    SETUPTOOLS_VER=$(echo "$PY_OUT" | awk '{print $1}')
    WHEEL_VER=$(echo "$PY_OUT" | awk '{print $2}')
                                                                TMP="$(mktemp)"                                             cp "$REQ_IN" "$TMP"
    printf '\n# ── Bootstrap (auto-pinned by python_prep.sh) ──────────────────\n' >> "$TMP"
    for PKG in $MISSING_PINS; do
        case "$PKG" in
            pip)        printf "pip==%s\n" "$PIP_VER" >> "$TMP" ;;
            setuptools) printf "setuptools==%s\n" "$SETUPTOOLS_VER" >> "$TMP" ;;
            wheel)      printf "wheel==%s\n" "$WHEEL_VER" >> "$TMP" ;;
        esac                                                    done
    mv "$TMP" "$REQ_IN"                                         echo "[✔] Pins added to requirements.in."
fi                                                          
# ── 5. Compilation & Installation ──────────────────────────────────
echo "[*] Installing pip-tools..."
python3 -m pip install --quiet --upgrade pip-tools

echo "[*] Compiling locked requirements.txt (with hashes)..."                                                           "$VENV_DIR/bin/pip-compile" --generate-hashes --quiet "$REQ_IN" --output-file "$REQ_FILE"                               [ -s "$REQ_FILE" ] || { echo "[✘] ERROR: requirements.txt not created" >&2; exit 1; }                                   
echo "[*] Installing dependencies with strict security flags..."
pip install \                                                   --require-virtualenv \
    --isolated \
    --no-cache-dir \                                            --require-hashes \                                          -r "$REQ_FILE" \
    --cert "$CA_CERT" \
    --retries 3 \
    --timeout 10 \                                              --no-input \
    --log "$PIP_LOG" >/dev/null
                                                            # ── 6. Audit & Lock ────────────────────────────────────────────────
echo "[*] Running Security Audit (pip-audit)..."            if python3 -m pip_audit --progress-spinner off 2>/dev/null; then
    echo "[✔] pip-audit passed — no known vulnerabilities." else
    echo "[!] pip-audit found issues. Check $PIP_LOG for details."                                                      fi

python3 -m pip freeze > "$SCRIPT_DIR/requirements.lock"
echo "[✔] Python Environment Ready."                        echo "Venv: $VENV_DIR | Lockfile: requirements.lock"
