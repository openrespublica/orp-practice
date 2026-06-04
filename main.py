# main.py — ORP Engine · PDF Stamp & Anchor Service (IMPROVED v5)
# Part of the OpenResPublica TruthChain stack.
# Must be launched via run_orp.sh — never directly.

# ── IMPORTS ──────────────────────────────────────────────────────
import hashlib
import io
import os
import json
import datetime
import threading
import signal
import time
import fcntl
import subprocess
import logging

import gnupg
import pytz
import qrcode

from flask import Flask, request, send_file, jsonify, render_template
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from immudb.client import ImmudbClient
from dotenv import load_dotenv
import getpass

load_dotenv()

# ── LOGGING ──────────────────────────────────────────────────────
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

if not GPG_HOME.startswith("/dev/shm") and not GPG_HOME.startswith("/tmp"):
    logger.critical("VULNERABILITY: GNUPGHOME must be in /dev/shm or /tmp (ephemeral)")
    raise RuntimeError("Launch via the boot script with ephemeral keyring")

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
MAX_PDF_SIZE      = int(os.getenv("MAX_PDF_SIZE", str(20 * 1024 * 1024)))


# ── 3. FLASK INITIALIZATION ───────────────────────────────────────
app = Flask(__name__,
            template_folder='templates',
            static_folder='static')

ctrl_lock = threading.Lock()
git_lock  = threading.Lock()

os.makedirs(RECORDS_DIR, exist_ok=True)
logger.info(f"✅ Records directory ready: {RECORDS_DIR}")


# ── 4. VAULT CONNECTION ───────────────────────────────────────────
_vault_password: str | None = None

def get_client() -> ImmudbClient:
    global _vault_password

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
        c = ImmudbClient(f"{host}:{port}")
        c.login(IMMUDB_USER, _vault_password, database=IMMUDB_DB)
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
    try:
        data_str = json.dumps(record, sort_keys=True)
        sig      = gpg.sign(data_str, keyid=GPG_EMAIL)

        if sig.status != "signature created":
            logger.error(f"GPG signing failed: {sig.stderr}")
            return None

        return {
            "gpg_signature":   str(sig),
            "hash_anchor":     hashlib.sha256(data_str.encode()).hexdigest(),
            "integrity_scope": "EPHEMERAL_RAM_LEGAL_SIGNATURE",
        }
    except Exception as e:
        logger.error(f"Error during JSON signing: {e}")
        return None


def next_control_number() -> str:
    with ctrl_lock:
        local_tz     = pytz.timezone(TZ_NAME)
        current_year = str(datetime.datetime.now(local_tz).year)

        if not os.path.exists(CONTROL_FILE):
            try:
                fd = os.open(CONTROL_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.write(fd, b"2026-0000")
                os.close(fd)
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
    try:
        reader   = PdfReader(io.BytesIO(original_pdf))
        writer   = PdfWriter()
        qr_image = ImageReader(qr_buf)

        for page in reader.pages:
            packet = io.BytesIO()
            c      = canvas.Canvas(packet, pagesize=A4)

            # ── FIX: THE OVERLAP PROBLEM (OPAQUE BACKGROUND PLATE) ──
            c.setFillColorRGB(1, 1, 1)
            # Expanded the plate downward to 3mm to cover the new text position
            c.rect(24 * mm, 3 * mm, 162 * mm, 20 * mm, fill=1, stroke=0)

            # Reset fill to black for text assets
            c.setFillColorRGB(0, 0, 0)
            c.setLineWidth(0.5)
            c.line(25 * mm, 22 * mm, 185 * mm, 22 * mm)

            # ── FIX: CALL TO ACTION (CTA) ──
            # Moved below the QR code (Y axis set to 4mm)
            c.setFont("Helvetica-Bold", 6)
            c.drawCentredString(172.5 * mm, 4 * mm, "SCAN TO VERIFY")

            # ── FIX: CRYPTOGRAPHIC TRUNCATION ELIMINATED ──
            items = [
                ("TIMESTAMP", timestamp),
                ("CTRL NO",   control_number),
                ("HASH",      sha256_hash),
            ]
            
            y = 18 * mm
            for label, val in items:
                c.setFont("Helvetica-Bold", 7)
                c.drawString(30 * mm, y, f"{label}:")
                
                # Dynamically drop text scaling for the hash property so it completely fits
                if label == "HASH":
                    c.setFont("Helvetica", 5.5)
                else:
                    c.setFont("Helvetica", 7)
                    
                c.drawString(55 * mm, y, str(val))
                y -= 3.5 * mm

            # Nudged the QR code up to 6mm to make room for the text below it
            c.drawImage(qr_image, 165 * mm, 6 * mm, width=15 * mm, height=15 * mm)
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
    try:
        manifest_path = os.path.join(RECORDS_DIR, "manifest.json")
        records: list = []

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
    try:
        git_env = os.environ.copy()
        live_ssh_sock = os.environ.get("SSH_AUTH_SOCK") or SSH_AUTH_SOCK
        live_gpg_home = os.environ.get("GNUPGHOME")     or GPG_HOME

        if not live_ssh_sock:
            logger.error("SSH_AUTH_SOCK is unset — cannot reach gpg-agent")
            return False

        git_env["SSH_AUTH_SOCK"] = live_ssh_sock
        git_env["GNUPGHOME"]     = live_gpg_home

        logger.debug(f"SSH_AUTH_SOCK → {live_ssh_sock}")
        logger.debug(f"GNUPGHOME     → {live_gpg_home}")

        git_env["GIT_SSH_COMMAND"] = (
            "ssh -o BatchMode=yes "
            "-o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null "
            f"-o IdentityAgent={git_env['SSH_AUTH_SOCK']}"
        )

        defensive_cmd = [
            "git",
            "-c", "commit.gpgsign=false",
            "-c", "user.email=marcofernandez0204@gmail.com",
            "-c", "user.name=Shandy Nazareno",
        ] + cmd[1:]

        logger.debug(f"Git command: {' '.join(defensive_cmd)}")

        result = subprocess.run(
            defensive_cmd,
            check=True,
            env=git_env,
            capture_output=True,
            text=True,
            cwd=REPO_PATH,
            timeout=30,
        )

        if result.stdout.strip():
            logger.debug(f"stdout: {result.stdout.strip()}")

        logger.info(f"✅ {description}")
        return True

    except subprocess.TimeoutExpired:
        logger.error(
            f"❌ {description} — TIMED OUT after 30s. "
            f"SSH_AUTH_SOCK={git_env.get('SSH_AUTH_SOCK', 'MISSING')} "
            f"— verify the gpg-agent socket is reachable from this process."
        )
        return False

    except subprocess.CalledProcessError as e:
        logger.error(f"❌ {description} — exit {e.returncode}")
        if e.stderr:
            logger.error(f"   stderr: {e.stderr[:500]}")
        if e.stdout:
            logger.debug(f"   stdout: {e.stdout[:200]}")
        return False

    except Exception as e:
        logger.error(f"❌ {description} — unexpected error: {e}")
        return False


def _verify_ssh_agent(git_env: dict) -> None:
    try:
        result = subprocess.run(
            ["ssh-add", "-l"],
            env=git_env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        keys = result.stdout.strip() or result.stderr.strip() or "(none)"
        logger.info(f"SSH agent keys visible to subprocess:\n  {keys}")
    except Exception as e:
        logger.warning(f"Could not query SSH agent: {e}")


def sync_to_github(json_path: str, record: dict) -> None:
    with git_lock:
        try:
            update_manifest(record)
            anchor_hash = os.path.basename(json_path).replace(".json", "")

            logger.info(f"Starting git sync for {anchor_hash[:16]}...")

            probe_env = os.environ.copy()
            probe_env["SSH_AUTH_SOCK"] = (
                os.environ.get("SSH_AUTH_SOCK") or SSH_AUTH_SOCK
            )
            _verify_ssh_agent(probe_env)

            if not run_git_command(["git", "add", "."], "Stage files"):
                return

            committed = run_git_command(
                ["git", "commit", "-m", f"Audit: Anchor {anchor_hash}"],
                "Commit changes",
            )
            if not committed:
                logger.warning("Commit failed or nothing to commit — continuing to push")

            if not run_git_command(["git", "fetch", "origin"], "Fetch from remote"):
                return

            rebase_ok = run_git_command(
                ["git", "pull", "--rebase", "origin", "main"],
                "Rebase onto remote main",
            )

            if not rebase_ok:
                logger.warning("⚠️ Rebase conflict — initiating self-healing...")

                run_git_command(
                    ["git", "rebase", "--abort"],
                    "Abort stuck rebase",
                )
                run_git_command(
                    ["git", "merge", "origin/main", "-X", "ours", "--no-edit"],
                    "Self-healing merge (ours)",
                )
                run_git_command(["git", "add", "."], "Stage conflict resolutions")
                run_git_command(
                    ["git", "commit", "-m", f"Auto-healed conflict for {anchor_hash}"],
                    "Commit resolutions",
                )
                logger.info("✅ Self-healing complete")

            if not run_git_command(
                ["git", "push", "origin", "main"], "Push to remote"
            ):
                return

            logger.info(f"✅ TruthChain synchronized: {anchor_hash[:16]}...")

        except Exception as e:
            logger.error(f"Sync thread error: {e}", exc_info=True)


def start_sync(json_path: str, record: dict) -> None:
    threading.Thread(
        target=sync_to_github,
        args=(json_path, record),
        daemon=True,
    ).start()


# ── 7. ROUTES ────────────────────────────────────────────────────

@app.route("/")
def home():
    return render_template("portal.html")


@app.route("/cert_error.html")
def cert_error():
    return (
        "<h1>Sovereign Identity Required</h1>"
        "<p>A valid operator certificate is required.</p>",
        403,
    )


@app.route("/lock_engine", methods=["POST"])
def lock_engine():
    logger.warning("Lock signal received — initiating secure shutdown")
    threading.Timer(0.5, lambda: os.kill(os.getpid(), signal.SIGINT)).start()
    return "Engine locked. RAM disk purged.", 200

@app.route("/upload", methods=["POST"])
def upload_pdf():
    global client

    try:
        # ── Step 1: Validate ─────────────────────────────────────
        file = request.files.get("document")
        if not file or not file.filename.lower().endswith(".pdf"):
            logger.warning(f"Invalid file: {file.filename if file else 'None'}")
            return "Only PDF files are accepted.", 400

        # ── FIX: DROPDOWN MISMATCH VALIDATION ──
        # Detects unselected dropdowns or generic client-side fallback tokens
        doc_type = request.form.get("doc_type", "").strip()
        if not doc_type or doc_type.upper() in ["", "CHOOSE", "SELECT", "DEFAULT"]:
            logger.warning("Upload blocked: Operator skipped selecting a definitive document type.")
            return "Validation Error: You must select an explicit Document Type before uploading.", 400

        pdf_bytes = file.read()

        if len(pdf_bytes) > MAX_PDF_SIZE:
            logger.warning(f"File too large: {len(pdf_bytes)} bytes")
            return "File exceeds maximum size (20MB).", 413

        # ── Step 2: Fingerprint ──────────────────────────────────
        sha256_hash = hashlib.sha256(pdf_bytes).hexdigest()
        logger.info(f"Processing document: {sha256_hash[:16]}...")

        # ── Step 3: Anchor to immudb with retry ──────────────────
        tx         = None
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
                    except Exception as reconnect_err:
                        logger.warning(f"Reconnection failed: {reconnect_err}")
                        last_error = reconnect_err
                else:
                    logger.error(f"Vault unavailable after {VAULT_MAX_RETRIES} attempts")

        if tx is None:
            logger.error(f"Failed to anchor: {last_error}")
            return jsonify({
                "status":  "ERROR",
                "message": f"Failed to anchor hash after {VAULT_MAX_RETRIES} attempts",
                "error":   str(last_error),
                "sha256":  sha256_hash,
            }), 503

        # ── Step 4: Control number & timestamp ───────────────────
        local_tz     = pytz.timezone(TZ_NAME)
        timestamp_ph = datetime.datetime.now(local_tz).strftime("%Y-%m-%d %I:%M %p PHT")
        control_no   = next_control_number()
        final_ctrl   = f"Verified_{control_no}-{doc_type}"

        # ── Step 5: Assemble & sign the audit record ─────────────
        operator_identity = request.headers.get("X-Operator-ID", "UNKNOWN")

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

        # ── Step 6: Save JSON record ──────────────────────────────
        json_path = os.path.join(RECORDS_DIR, f"{sha256_hash}.json")
        with open(json_path, "w") as f:
            json.dump(record, f, indent=2)

        # ── Step 7: Sync to GitHub (background) ──────────────────
        start_sync(json_path, record)

        # ── Step 8: Stamp the PDF ─────────────────────────────────
        qr_buf, _       = generate_qr(sha256_hash)
        stamped_pdf_buf = add_footer(
            pdf_bytes, sha256_hash, qr_buf, timestamp_ph, final_ctrl
        )

        # ── Step 9: Return stamped PDF ────────────────────────────
        logger.info(f"✅ Upload complete: {final_ctrl}")
        return send_file(
            stamped_pdf_buf,
            as_attachment=True,
            download_name=f"{final_ctrl}.pdf",
        )

    except Exception as e:
        logger.error(f"Unhandled error in upload: {e}", exc_info=True)
        return jsonify({
            "status":  "ERROR",
            "message": "An unexpected error occurred",
            "error":   str(e),
        }), 500


# ── 8. ENTRY POINT ───────────────────────────────────────────────
if __name__ == "__main__":
    port = int(os.getenv("FLASK_PORT", 5000))
    logger.info(f"Starting ORP Engine on 127.0.0.1:{port}")
    app.run(host="127.0.0.1", port=port, debug=False)
