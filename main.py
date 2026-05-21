# main.py — ORP Engine · PDF Stamp & Anchor Service (IMPROVED v3)
# Part of the OpenResPublica TruthChain stack.
# Must be launched via run_orp.sh or run_orp-gum.sh — never directly.

# ── IMPORTS ──────────────────────────────────────────────────────
import hashlib      # SHA-256 fingerprinting
import io           # in-memory byte streams (PDF processing)
import os           # environment variables, file paths, signals
import json         # reading and writing JSON records
import datetime     # timestamps for records
import threading    # Lock() for control numbers, Timer for shutdown                      import signal       # graceful shutdown on SIGINT / SIGTERM
import time         # retry delays
import fcntl        # file locking for process safety
import subprocess   # git commands
import logging      # structured logging

# Third-party — all listed in requirements.txt.
import gnupg        # GPG signing of audit records
import pytz         # Philippine timezone (Asia/Manila)
import qrcode       # QR code generation

from flask import (
    Flask,
    request,
    send_file,
    jsonify,
    render_template
)
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from immudb.client import ImmudbClient
from dotenv import load_dotenv
import getpass

# Load .env file into environment before reading any variables.
load_dotenv()

# ── LOGGING CONFIGURATION ────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


# ── 1. SECURITY ENVIRONMENT VALIDATION ───────────────────────────
GPG_HOME      = os.getenv("GNUPGHOME")
GPG_EMAIL     = os.getenv("OPERATOR_GPG_EMAIL")
SSH_AUTH_SOCK = os.getenv("SSH_AUTH_SOCK")

if not all([GPG_HOME, GPG_EMAIL, SSH_AUTH_SOCK]):
    logger.critical("SECURITY FAILURE: Required environment variables missing")
    logger.critical(f"  - GPG_HOME: {'✅' if GPG_HOME else '❌ MISSING'}")
    logger.critical(f"  - GPG_EMAIL: {'✅' if GPG_EMAIL else '❌ MISSING'}")
    logger.critical(f"  - SSH_SOCK: {'✅' if SSH_AUTH_SOCK else '❌ MISSING'}")
    raise RuntimeError("Engine must be launched via run_orp.sh or run_orp-gum.sh")

if not GPG_HOME.startswith("/tmp"):
    logger.critical("VULNERABILITY: GNUPGHOME must be in RAM (/tmp)")
    raise RuntimeError("Launch via the boot script with RAM-based keyring")

gpg = gnupg.GPG(gnupghome=GPG_HOME)
gpg.decode_errors = 'replace'
logger.info(f"✅ GPG environment initialized in {GPG_HOME}")


# ── 2. CONFIGURATION ─────────────────────────────────────────────
IMMUDB_HOST = os.getenv("IMMUDB_HOST", "127.0.0.1:3322")
IMMUDB_USER = os.getenv("IMMUDB_USER", "immudb")
IMMUDB_DB   = os.getenv("IMMUDB_DB",   "defaultdb")

LGU_NAME    = os.getenv("LGU_NAME",             "Local Government Unit")
SIGNER_NAME = os.getenv("LGU_SIGNER_NAME",       "Authorized Signatory")
SIGNER_POS  = os.getenv("LGU_SIGNER_POSITION",   "Official")
TZ_NAME     = os.getenv("LGU_TIMEZONE",           "Asia/Manila")

REPO_PATH     = os.getenv("GITHUB_REPO_PATH",  "/home/orp/openrespublica.github.io")
GITHUB_PORTAL = os.getenv("GITHUB_PORTAL_URL", "https://openrespublica.github.io/verify.html")

RECORDS_DIR  = os.path.join(REPO_PATH, "docs", "records")
CONTROL_FILE = os.path.join(REPO_PATH, "docs", "control_number.txt")

VAULT_MAX_RETRIES = int(os.getenv("VAULT_MAX_RETRIES", "3"))
VAULT_RETRY_DELAY = int(os.getenv("VAULT_RETRY_DELAY", "1"))
MAX_PDF_SIZE = int(os.getenv("MAX_PDF_SIZE", str(20 * 1024 * 1024)))

# ── 3. FLASK INITIALIZATION ───────────────────────────────────────
app = Flask(__name__,
            template_folder='templates',
            static_folder='static')

ctrl_lock = threading.Lock()
git_lock  = threading.Lock()

os.makedirs(RECORDS_DIR, exist_ok=True)                                                   logger.info(f"✅ Records directory ready: {RECORDS_DIR}")


# ── 4. VAULT CONNECTION ───────────────────────────────────────────
_vault_password: str | None = None                                                        
def get_client() -> ImmudbClient:
    """                                                                                       Connect to the immudb vault with explicit host:port parsing.
    Prompts for password on first call only.
    """                                                                                       global _vault_password                                                                
    if ":" in IMMUDB_HOST:
        host, port = IMMUDB_HOST.rsplit(":", 1)
        try:
            port = int(port)
        except ValueError:
            logger.error(f"Invalid port in IMMUDB_HOST: {IMMUDB_HOST}")
            port = 3322
    else:
        host, port = IMMUDB_HOST, 3322

    if _vault_password is None:
        logger.info("Prompting for vault password...")
        _vault_password = getpass.getpass(
            f"Enter password for vault user [{IMMUDB_USER}]: "
        )

    try:
        c = ImmudbClient(f"{host}:{port}")                                                        c.login(IMMUDB_USER, _vault_password, database=IMMUDB_DB)
        logger.info(f"✅ Vault unlocked → {host}:{port}/{IMMUDB_DB}")
        return c
    except Exception as e:
        logger.error(f"Vault access denied: {e}")
        raise

try:
    client = get_client()
except Exception as e:
    logger.critical(f"Failed to initialize vault connection: {e}")
    exit(1)


# ── 5. GRACEFUL SHUTDOWN ──────────────────────────────────────────
def graceful_shutdown(signum, frame):
    """
    Called when SIGINT or SIGTERM is received.
    Logs out of immudb, then forces exit.
    """
    logger.warning("Received shutdown signal — purging session...")
    try:
        client.logout()
        logger.info("✅ Vault session closed")
    except Exception as e:
        logger.warning(f"Vault logout error: {e}")
    os._exit(0)

signal.signal(signal.SIGINT,  graceful_shutdown)
signal.signal(signal.SIGTERM, graceful_shutdown)


# ── 6. CRYPTO & DATA UTILITIES ───────────────────────────────────
                                                                                          def sign_json_data(record: dict) -> dict | None:
    """Signs the audit record JSON using the ephemeral GPG key in RAM."""
    try:
        data_str = json.dumps(record, sort_keys=True)
        sig      = gpg.sign(data_str, keyid=GPG_EMAIL)                                    
        if sig.status != "signature created":
            logger.error(f"GPG signing failed: {sig.stderr}")                                         return None

        return {                                                                                      "gpg_signature":   str(sig),
            "hash_anchor":     hashlib.sha256(data_str.encode()).hexdigest(),
            "integrity_scope": "EPHEMERAL_RAM_LEGAL_SIGNATURE",                                   }
    except Exception as e:
        logger.error(f"Error during JSON signing: {e}")
        return None                                                                       

def next_control_number() -> str:
    """Issues the next sequential control number for this calendar year."""                   with ctrl_lock:
        local_tz     = pytz.timezone(TZ_NAME)
        current_year = str(datetime.datetime.now(local_tz).year)
                                                                                                  if not os.path.exists(CONTROL_FILE):
            try:
                fd = os.open(CONTROL_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.write(fd, b"2026-0000")                                                                os.close(fd)
            except FileExistsError:
                pass

        with open(CONTROL_FILE, "r+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                content = f.read().strip()
                if not content:
                    parts = [current_year, 0]
                else:
                    parts = content.split("-")

                year, num = parts[0], int(parts[1]) if len(parts) > 1 else 0

                if year != current_year:
                    year, num = current_year, 0

                new_ctrl = f"{year}-{(num + 1):04d}"
                f.seek(0)
                f.write(new_ctrl)
                f.truncate()
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)

        logger.info(f"Control number issued: {new_ctrl}")
        return new_ctrl


def generate_qr(sha256_hash: str) -> tuple[io.BytesIO, str]:
    """Generates a QR code linking to the public verification portal."""
    try:
        qr_url = f"{GITHUB_PORTAL}?hash={sha256_hash}"
        qr     = qrcode.QRCode(
            version=1,
            error_correction=qrcode.constants.ERROR_CORRECT_L,
            box_size=10,
            border=4,
        )
        qr.add_data(qr_url)
        qr_img = qr.make_image(fill_color="black", back_color="white")

        buf = io.BytesIO()
        qr_img.save(buf, format="PNG")
        buf.seek(0)
        return buf, qr_url
    except Exception as e:
        logger.error(f"QR code generation failed: {e}")
        raise


def add_footer(
    original_pdf:   bytes,
    sha256_hash:    str,
    qr_buf:         io.BytesIO,
    timestamp:      str,
    control_number: str,
) -> io.BytesIO:
    """Stamps every page of the PDF with metadata footer and QR code."""
    try:
        reader   = PdfReader(io.BytesIO(original_pdf))
        writer   = PdfWriter()
        qr_image = ImageReader(qr_buf)

        for page in reader.pages:
            packet = io.BytesIO()
            c      = canvas.Canvas(packet, pagesize=A4)

            c.setLineWidth(0.5)
            c.line(25 * mm, 22 * mm, 185 * mm, 22 * mm)

            items = [
                ("TIMESTAMP", timestamp),
                ("CTRL NO",   control_number),
                ("HASH",      sha256_hash[:32] + "..."),
            ]
            y = 18 * mm
            for label, val in items:
                c.setFont("Helvetica-Bold", 7)
                c.drawString(30 * mm, y, f"{label}:")
                c.setFont("Helvetica", 7)
                c.drawString(55 * mm, y, str(val))
                y -= 3.5 * mm

            c.drawImage(qr_image, 165 * mm, 5 * mm, width=15 * mm, height=15 * mm)
            c.save()
            packet.seek(0)

            page.merge_page(PdfReader(packet).pages[0])
            writer.add_page(page)

        out = io.BytesIO()
        writer.write(out)
        out.seek(0)
        return out
    except Exception as e:
        logger.error(f"PDF stamping failed: {e}")
        raise


def update_manifest(record: dict) -> None:
    """Prepends the new record to manifest.json (newest first)."""
    try:
        manifest_path = os.path.join(RECORDS_DIR, "manifest.json")                                records: list = []

        if os.path.exists(manifest_path):
            try:
                with open(manifest_path, "r") as f:
                    records = json.load(f)
            except Exception as e:
                logger.warning(f"Could not read manifest (will overwrite): {e}")
                records = []

        records.insert(0, record)
        records = records[:1000]

        with open(manifest_path, "w") as f:
            json.dump(records, f, indent=2)
        logger.info(f"✅ Manifest updated: {len(records)} records")
    except Exception as e:
        logger.error(f"Manifest update failed: {e}")
        raise


def run_git_command(cmd: list, description: str) -> bool:
    """
    Runs a git command with proper SSH environment.

    CRITICAL FIX: Uses SSH_AUTH_SOCK from environment to connect SSH agent.
    This allows git to use the ephemeral SSH key stored in gpg-agent.

    Returns True on success, False on failure.
    """
    try:
        git_env = os.environ.copy()

        # CRITICAL: Ensure SSH_AUTH_SOCK is set so git uses SSH agent
        if not git_env.get("SSH_AUTH_SOCK"):
            logger.error("SSH_AUTH_SOCK not in environment — SSH will fail")
            return False

        # Configure SSH to use the gpg-agent socket
        git_env["GIT_SSH_COMMAND"] = (
            "ssh -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            "-o IdentityFile=/dev/null "  # Don't use default keys
            "-o IdentitiesOnly=yes "       # Use only SSH agent
        )

        logger.debug(f"Git command: {' '.join(cmd)}")
        logger.debug(f"SSH_AUTH_SOCK: {git_env.get('SSH_AUTH_SOCK')}")

        result = subprocess.run(
            cmd,
            check=True,
            env=git_env,
            capture_output=True,
            text=True,
            timeout=30
        )

        logger.info(f"✅ {description}")
        if result.stdout:
            logger.debug(f"stdout: {result.stdout[:200]}")
        return True

    except subprocess.TimeoutExpired as e:
        logger.error(f"❌ {description} — TIMEOUT: {e}")
        return False
    except subprocess.CalledProcessError as e:
        logger.error(f"❌ {description} — FAILED: {e.returncode}")
        logger.error(f"stderr: {e.stderr[:500] if e.stderr else 'none'}")
        logger.error(f"stdout: {e.stdout[:500] if e.stdout else 'none'}")
        return False
    except Exception as e:
        logger.error(f"❌ {description} — ERROR: {e}")
        return False


def sync_to_github(json_path: str, record: dict) -> None:
    """
    Runs in a background daemon thread.
    Writes the manifest, commits the new record JSON, and pushes
    to GitHub Pages using SSH. Includes self-healing for Git conflicts.
    """
    with git_lock:
        try:
            update_manifest(record)
            anchor_hash = os.path.basename(json_path).replace(".json", "")

            logger.info(f"Starting git sync for {anchor_hash}...")

            # 1. Stage files (Consider replacing '.' with 'docs/' to avoid staging core scripts)
            if not run_git_command(
                ['git', '-C', REPO_PATH, 'add', '.'],
                "Stage files"
            ):
                return

            # 2. Commit (may fail if nothing changed, that's OK)
            if not run_git_command(
                ['git', '-C', REPO_PATH, 'commit', '-m', f"Audit: Anchor {anchor_hash}"],
                "Commit changes"
            ):
                logger.warning("Commit failed or nothing to commit (may be OK)")

            # 3. Fetch latest from remote
            if not run_git_command(
                ['git', '-C', REPO_PATH, 'fetch', 'origin'],
                "Fetch from remote"
            ):
                return

            # 4. Attempt standard rebase
            rebase_success = run_git_command(
                ['git', '-C', REPO_PATH, 'pull', '--rebase', 'origin', 'main'],
                "Rebase onto remote main"
            )

            # 5. 🛠️ SELF-HEALING BLOCK
            if not rebase_success:
                logger.warning("⚠️ Git conflict detected! Initiating self-healing sequence...")

                # A. Abort the frozen rebase
                run_git_command(
                    ['git', '-C', REPO_PATH, 'rebase', '--abort'],
                    "Abort stuck rebase"
                )

                # B. Execute a merge, instructing Git to favor local file contents (-X ours)
                run_git_command(
                    ['git', '-C', REPO_PATH, 'merge', 'origin/main', '-X', 'ours', '--no-edit'],
                    "Self-healing merge"
                )

                # C. Force resolve modify/delete conflicts (keeps local file existence state)
                run_git_command(
                    ['git', '-C', REPO_PATH, 'add', '.'],
                    "Stage conflict resolutions"
                )
                run_git_command(
                    ['git', '-C', REPO_PATH, 'commit', '-m', f"Auto-healed conflict for {anchor_hash}"],
                    "Commit resolutions"
                )

                logger.info("✅ Self-healing successful.")

            # 6. Push to remote
            if not run_git_command(
                ['git', '-C', REPO_PATH, 'push', 'origin', 'main'],
                "Push to remote"
            ):
                return

            logger.info(f"✅ TruthChain synchronized: {anchor_hash}")

        except Exception as e:
            logger.error(f"Sync thread error: {e}", exc_info=True)

def start_sync(json_path: str, record: dict) -> None:
    """Launches sync_to_github in a daemon thread."""
    threading.Thread(
        target=sync_to_github,
        args=(json_path, record),
        daemon=True
    ).start()


# ── 7. ROUTES ────────────────────────────────────────────────────

@app.route("/")
def home():
    """Serves the operator portal."""
    return render_template("portal.html")


@app.route("/cert_error.html")
def cert_error():
    """Fallback route for Nginx error_page 495/496 directive."""
    return (
        "<h1>Sovereign Identity Required</h1>"
        "<p>A valid operator certificate is required.</p>",
        403,
    )


@app.route('/lock_engine', methods=['POST'])
def lock_engine():
    """Secure kill switch — triggers graceful shutdown."""
    logger.warning("Lock signal received — initiating secure shutdown")
    threading.Timer(0.5, lambda: os.kill(os.getpid(), signal.SIGINT)).start()
    return "Engine locked. RAM disk purged.", 200
@app.route("/upload", methods=["POST"])
def upload_pdf():
    """
    Core route — PDF upload, hash, anchor, sign, stamp, publish.

    Pipeline:
      1. Validate the uploaded file (PDF only, size limit)
      2. Compute SHA-256 fingerprint
      3. Anchor hash to immudb with retry logic
      4. Issue unique control number
      5. GPG-sign the audit record
      6. Save JSON record locally
      7. Sync to GitHub Pages (background daemon thread)
      8. Stamp the PDF with QR + metadata footer
      9. Return stamped PDF to browser for download
    """
    global client

    try:
        # ── Step 1: Validate ─────────────────────────────────────────
        file = request.files.get("document")
        if not file or not file.filename.lower().endswith('.pdf'):
            logger.warning(f"Invalid file type: {file.filename if file else 'None'}")
            return "Only PDF files are accepted.", 400

        doc_type  = request.form.get("doc_type", "BARANGAY-CERT")
        pdf_bytes = file.read()

        if len(pdf_bytes) > MAX_PDF_SIZE:
            logger.warning(f"File too large: {len(pdf_bytes)} bytes")
            return "File exceeds maximum size (20MB).", 413

        # ── Step 2: Fingerprint ──────────────────────────────────────
        sha256_hash = hashlib.sha256(pdf_bytes).hexdigest()
        logger.info(f"Processing document: {sha256_hash[:16]}...")

        # ── Step 3: Anchor to immudb with RETRY LOGIC ─────────────────
        tx = None
        last_error = None

        for attempt in range(1, VAULT_MAX_RETRIES + 1):
            try:
                logger.info(f"Anchoring hash (attempt {attempt}/{VAULT_MAX_RETRIES})...")
                tx = client.set(sha256_hash.encode(), b"VERIFIED_BY_ORP_ENGINE")
                logger.info(f"✅ Hash anchored with tx_id={tx.id}")
                break
            except Exception as e:
                last_error = e
                if attempt < VAULT_MAX_RETRIES:
                    logger.warning(f"Vault error (attempt {attempt}): {e}")
                    logger.info(f"Retrying in {VAULT_RETRY_DELAY}s...")
                    time.sleep(VAULT_RETRY_DELAY)

                    try:
                        logger.info("Reconnecting to vault...")
                        client = get_client()
                    except Exception as reconnect_error:
                        logger.warning(f"Reconnection failed: {reconnect_error}")
                        last_error = reconnect_error
                else:
                    logger.error(f"Vault unavailable after {VAULT_MAX_RETRIES} attempts")

        if tx is None:
            logger.error(f"Failed to anchor: {last_error}")
            return jsonify({
                "status": "ERROR",
                "message": f"Failed to anchor hash after {VAULT_MAX_RETRIES} attempts",
                "error": str(last_error),
                "sha256": sha256_hash
            }), 503

        # ── Step 4: Control number & timestamp ───────────────────────
        local_tz     = pytz.timezone(TZ_NAME)
        timestamp_ph = datetime.datetime.now(local_tz).strftime("%Y-%m-%d %I:%M %p PHT")
        control_no   = next_control_number()
        final_ctrl   = f"Verified_{control_no}-{doc_type}"

        # ── Step 5: Assemble & sign the audit record ─────────────────
        operator_identity = request.headers.get('X-Operator-ID', 'UNKNOWN')

        record = {
            "status":                "VERIFIED ✅",
            "signer":                SIGNER_NAME,
            "position":              f"{SIGNER_POS}, {LGU_NAME}",
            "operator_identity":     operator_identity,
            "document_type":         doc_type,
            "control_number":        final_ctrl,
            "sha256_hash":           sha256_hash,
            "timestamp":             timestamp_ph,
            "immudb_transaction_id": tx.id,
            "verification_url":      f"{GITHUB_PORTAL}?hash={sha256_hash}",
        }

        pgp_sig = sign_json_data(record)
        if pgp_sig:
            record["data_signature"] = pgp_sig

        # ── Step 6: Save JSON record locally ─────────────────────────
        json_path = os.path.join(RECORDS_DIR, f"{sha256_hash}.json")
        with open(json_path, "w") as f:
            json.dump(record, f, indent=2)

        # ── Step 7: Sync to GitHub (background) ──────────────────────
        start_sync(json_path, record)

        # ── Step 8: Stamp the PDF ────────────────────────────────────
        qr_buf, _       = generate_qr(sha256_hash)
        stamped_pdf_buf = add_footer(
            pdf_bytes, sha256_hash, qr_buf, timestamp_ph, final_ctrl
        )

        # ── Step 9: Return stamped PDF to browser ────────────────────
        logger.info(f"✅ Upload complete: {final_ctrl}")
        return send_file(
            stamped_pdf_buf,
            as_attachment=True,
            download_name=f"{final_ctrl}.pdf"
        )

    except Exception as e:
        logger.error(f"Unhandled error in upload: {e}", exc_info=True)
        return jsonify({
            "status": "ERROR",
            "message": "An unexpected error occurred",
            "error": str(e)
        }), 500


# ── 8. ENTRY POINT ───────────────────────────────────────────────
if __name__ == "__main__":
    port = int(os.getenv("FLASK_PORT", 5000))
    logger.info(f"Starting ORP Engine on 127.0.0.1:{port}")
    app.run(host="127.0.0.1", port=port, debug=False)
