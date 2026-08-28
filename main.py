# main.py — ORP Engine · PDF Stamp & Anchor Service
# Alpine Linux — Persistent PKI — LUKS USB Vault — Hash Chain
# immudb REMOVED — replaced with SHA-256 hash chain + LUKS vault
# ─────────────────────────────────────────────────────────────────
import hashlib, io, os, json, datetime, threading, signal, fcntl
import subprocess, logging, shutil
from logging.handlers import TimedRotatingFileHandler

import gnupg, pytz, qrcode
from flask import Flask, request, send_file, jsonify, render_template
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from dotenv import load_dotenv

load_dotenv()

# ── Logging — console + rotating vault audit log ──────────────────
_log_fmt = logging.Formatter(
    '%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
_console = logging.StreamHandler()
_console.setFormatter(_log_fmt)
logging.getLogger().setLevel(logging.INFO)
logging.getLogger().addHandler(_console)
logger = logging.getLogger(__name__)

# ── 1. Environment validation ─────────────────────────────────────
GPG_HOME    = os.getenv("GNUPGHOME", os.path.expanduser("~/.gnupg"))
GPG_EMAIL   = os.getenv("OPERATOR_GPG_EMAIL")
GIT_SSH_CMD = os.getenv("GIT_SSH_COMMAND")
VAULT_MOUNT = os.getenv("ORP_VAULT_MOUNT")
RECORDS_DIR = os.getenv("ORP_RECORDS_DIR")
PDFS_DIR    = os.getenv("ORP_PDFS_DIR")
BACKUP_DIR  = os.getenv("ORP_BACKUP_DIR")
CHAIN_FILE  = os.getenv("ORP_CHAIN_FILE")
AUDIT_LOG   = os.getenv("ORP_AUDIT_LOG")

missing = [k for k, v in {
    "OPERATOR_GPG_EMAIL": GPG_EMAIL,
    "GIT_SSH_COMMAND":    GIT_SSH_CMD,
    "ORP_RECORDS_DIR":    RECORDS_DIR,
    "ORP_VAULT_MOUNT":    VAULT_MOUNT,
}.items() if not v]

if missing:
    for m in missing:
        logger.critical(f"❌ {m} — MISSING")
    raise RuntimeError("Launch via run_orp.sh — environment incomplete")

if not os.path.ismount(VAULT_MOUNT):
    raise RuntimeError(
        f"Vault {VAULT_MOUNT} not mounted. "
        "Insert Kingston USB and run ./run_orp.sh"
    )

# Add vault audit log handler
_audit_handler = TimedRotatingFileHandler(
    AUDIT_LOG, when="midnight", interval=30,
    backupCount=24, encoding="utf-8"
)
_audit_handler.setFormatter(_log_fmt)
logging.getLogger().addHandler(_audit_handler)

gpg = gnupg.GPG(gnupghome=GPG_HOME)
gpg.decode_errors = 'replace'

logger.info(f"✅ GPG          : {GPG_HOME}")
logger.info(f"✅ Vault        : {VAULT_MOUNT}")
logger.info(f"✅ Records      : {RECORDS_DIR}")
logger.info(f"✅ PDF archive  : {PDFS_DIR}")
logger.info(f"✅ Audit log    : {AUDIT_LOG}")

# ── 2. Configuration ──────────────────────────────────────────────
LGU_NAME    = os.getenv("LGU_NAME",            "Office")
SIGNER_NAME = os.getenv("LGU_SIGNER_NAME",     "Authorized Signatory")
SIGNER_POS  = os.getenv("LGU_SIGNER_POSITION", "Official")
TZ_NAME     = os.getenv("LGU_TIMEZONE",        "Asia/Manila")
REPO_PATH   = os.getenv("GITHUB_REPO_PATH")
PORTAL_URL  = os.getenv("GITHUB_PORTAL_URL",
              "https://openrespublica.github.io/orp-practice/verify.html")
MAX_PDF     = int(os.getenv("MAX_PDF_SIZE", str(20 * 1024 * 1024)))
CTRL_FILE   = os.path.join(VAULT_MOUNT, "control_number.txt")
MANIFEST    = os.path.join(VAULT_MOUNT, "manifest.json")

# ── 3. Flask ──────────────────────────────────────────────────────
app        = Flask(__name__, template_folder='templates',
                   static_folder='static')
ctrl_lock  = threading.Lock()
chain_lock = threading.Lock()
git_lock   = threading.Lock()

for d in [RECORDS_DIR, PDFS_DIR, BACKUP_DIR]:
    os.makedirs(d, exist_ok=True)

# ── 4. Shutdown ───────────────────────────────────────────────────
def graceful_shutdown(signum, frame):
    logger.warning("Shutdown signal — engine stopping.")
    os._exit(0)

signal.signal(signal.SIGINT,  graceful_shutdown)
signal.signal(signal.SIGTERM, graceful_shutdown)

# ── 5. Vault health ───────────────────────────────────────────────
def vault_ok() -> bool:
    return os.path.ismount(VAULT_MOUNT)

# ── 6. Date-organized path helper ────────────────────────────────
def dated_subdir(base: str) -> str:
    tz   = pytz.timezone(TZ_NAME)
    now  = datetime.datetime.now(tz)
    path = os.path.join(base, now.strftime("%Y"), now.strftime("%m"))
    os.makedirs(path, exist_ok=True)
    return path

# ── 7. Control number ─────────────────────────────────────────────
def next_control_number() -> str:
    with ctrl_lock:
        tz   = pytz.timezone(TZ_NAME)
        year = str(datetime.datetime.now(tz).year)

        if not os.path.exists(CTRL_FILE):
            try:
                fd = os.open(CTRL_FILE,
                             os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.write(fd, f"{year}-0000".encode())
                os.close(fd)
            except FileExistsError:
                pass

        with open(CTRL_FILE, "r+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                content = f.read().strip()
                parts   = content.split("-") if content else [year, "0"]
                y, n    = parts[0], int(parts[1]) if len(parts) > 1 else 0
                if y != year:
                    y, n = year, 0
                ctrl = f"{y}-{(n + 1):04d}"
                f.seek(0); f.write(ctrl); f.truncate()
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)

        logger.info(f"Control number issued: {ctrl}")
        return ctrl

# ── 8. Hash chain ─────────────────────────────────────────────────
def get_next_seq() -> int:
    try:
        with open(CHAIN_FILE) as f:
            return len(json.load(f).get("entries", [])) + 1
    except Exception:
        return 1

def append_chain(seq: int, doc_hash: str, timestamp: str) -> str:
    """
    Append tamper-evident chain entry.
    chain_hash = SHA-256(seq | doc_hash | prev_chain_hash | timestamp)
    Any modification breaks all subsequent chain_hashes.
    """
    with chain_lock:
        try:
            with open(CHAIN_FILE) as f:
                chain = json.load(f)
        except Exception:
            chain = {"chain_id": "ORP", "genesis": "0" * 64, "entries": []}

        entries   = chain.get("entries", [])
        prev_hash = entries[-1]["chain_hash"] if entries \
                    else chain.get("genesis", "0" * 64)

        raw        = f"{seq}|{doc_hash}|{prev_hash}|{timestamp}"
        chain_hash = hashlib.sha256(raw.encode()).hexdigest()

        entries.append({
            "seq":             seq,
            "sha256_hash":     doc_hash,
            "prev_chain_hash": prev_hash,
            "chain_hash":      chain_hash,
            "timestamp":       timestamp,
        })
        chain["entries"] = entries

        tmp = CHAIN_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(chain, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CHAIN_FILE)

        logger.info(f"Chain #{seq}: {chain_hash[:16]}...")
        return chain_hash

# ── 9. Duplicate detection ────────────────────────────────────────
def find_existing_record(sha256: str) -> dict | None:
    for root, _, files in os.walk(RECORDS_DIR):
        if f"{sha256}.json" in files:
            try:
                with open(os.path.join(root, f"{sha256}.json")) as f:
                    return json.load(f)
            except Exception:
                pass
    return None

# ── 10. GPG signing ───────────────────────────────────────────────
def sign_record(record: dict) -> dict | None:
    try:
        data_str = json.dumps(record, sort_keys=True)
        sig = gpg.sign(data_str, keyid=GPG_EMAIL)
        if sig.status != "signature created":
            logger.error(f"GPG sign failed: {sig.stderr}")
            return None
        return {
            "gpg_signature":   str(sig),
            "record_hash":     hashlib.sha256(data_str.encode()).hexdigest(),
            "integrity_scope": "LUKS2/AES-XTS-512/Argon2id/HashChain/RA10173",
        }
    except Exception as e:
        logger.error(f"GPG error: {e}")
        return None

# ── 11. QR code ───────────────────────────────────────────────────
def make_qr(sha256: str) -> tuple[io.BytesIO, str]:
    url = f"{PORTAL_URL}?hash={sha256}"
    qr  = qrcode.QRCode(version=1,
              error_correction=qrcode.constants.ERROR_CORRECT_M,
              box_size=10, border=4)
    qr.add_data(url)
    buf = io.BytesIO()
    qr.make_image(fill_color="black", back_color="white").save(buf, "PNG")
    buf.seek(0)
    return buf, url

# ── 12. PDF stamping ──────────────────────────────────────────────
def stamp_pdf(pdf_bytes: bytes, sha256: str, qr_buf: io.BytesIO,
              timestamp: str, ctrl: str, chain_hash: str,
              seq: int) -> bytes:
    reader = PdfReader(io.BytesIO(pdf_bytes))
    writer = PdfWriter()
    qr_img = ImageReader(qr_buf)

    for page in reader.pages:
        pkt = io.BytesIO()
        c   = canvas.Canvas(pkt, pagesize=A4)
        c.setLineWidth(0.5)
        c.line(25*mm, 24*mm, 185*mm, 24*mm)
        y = 20*mm
        for label, val in [
            ("TIMESTAMP",  timestamp),
            ("CTRL NO",    ctrl),
            ("SEQ",        f"#{seq}"),
            ("HASH",       sha256[:32] + "..."),
            ("CHAIN",      chain_hash[:24] + "..."),
        ]:
            c.setFont("Helvetica-Bold", 6.5)
            c.drawString(27*mm, y, f"{label}:")
            c.setFont("Helvetica", 6.5)
            c.drawString(52*mm, y, str(val))
            y -= 3.2*mm
        c.drawImage(qr_img, 165*mm, 5*mm, width=18*mm, height=18*mm)
        c.setFont("Helvetica-Bold", 6)
        c.drawString(27*mm, 6*mm, f"{SIGNER_NAME} — {LGU_NAME}")
        c.save()
        pkt.seek(0)
        page.merge_page(PdfReader(pkt).pages[0])
        writer.add_page(page)

    out = io.BytesIO()
    writer.write(out)
    return out.getvalue()

# ── 13. Manifest + rolling backups ───────────────────────────────
def update_manifest(record: dict) -> None:
    records = []
    if os.path.exists(MANIFEST):
        try:
            with open(MANIFEST) as f:
                records = json.load(f)
        except Exception:
            records = []

    records.insert(0, record)
    records = records[:2000]

    tmp = MANIFEST + ".tmp"
    with open(tmp, "w") as f:
        json.dump(records, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, MANIFEST)

    # Rolling backup — 10 snapshots of manifest + chain
    tz = pytz.timezone(TZ_NAME)
    ts = datetime.datetime.now(tz).strftime("%Y%m%dT%H%M%S")
    for src, prefix in [(MANIFEST, "manifest"), (CHAIN_FILE, "chain")]:
        if not os.path.exists(src):
            continue
        dst = os.path.join(BACKUP_DIR, f"{prefix}_{ts}.json")
        shutil.copy2(src, dst)
        os.chmod(dst, 0o600)
        # Prune — keep 10
        old = sorted(f for f in os.listdir(BACKUP_DIR)
                     if f.startswith(f"{prefix}_"))
        for o in old[:-10]:
            os.remove(os.path.join(BACKUP_DIR, o))

    # Also copy manifest to docs/records/ for GitHub Pages
    docs_manifest = os.path.join(REPO_PATH, "docs", "records", "manifest.json")
    os.makedirs(os.path.dirname(docs_manifest), exist_ok=True)
    shutil.copy2(MANIFEST, docs_manifest)

    logger.info(f"✅ Manifest updated ({len(records)} records)")

# ── 14. Git sync ──────────────────────────────────────────────────
def run_git(cmd: list, desc: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "-c", "commit.gpgsign=false",
             "-c", f"user.email={GPG_EMAIL}",
             "-c", f"user.name={SIGNER_NAME}"] + cmd[1:],
            check=True, env=os.environ.copy(),
            capture_output=True, text=True,
            cwd=REPO_PATH, timeout=30,
        )
        if result.stdout.strip():
            logger.debug(result.stdout.strip())
        logger.info(f"✅ {desc}")
        return True
    except subprocess.TimeoutExpired:
        logger.error(f"❌ {desc} — TIMEOUT")
        return False
    except subprocess.CalledProcessError as e:
        logger.error(f"❌ {desc} — exit {e.returncode}")
        if e.stderr:
            logger.error(f"   {e.stderr[:300]}")
        return False
    except Exception as e:
        logger.error(f"❌ {desc} — {e}")
        return False

def sync_to_github(json_path: str, record: dict) -> None:
    with git_lock:
        try:
            update_manifest(record)

            # Copy record JSON to docs/records/ for GitHub Pages
            docs_rec = os.path.join(
                REPO_PATH, "docs", "records",
                os.path.basename(json_path)
            )
            shutil.copy2(json_path, docs_rec)

            anchor = os.path.basename(json_path).replace(".json", "")
            if not run_git(["git", "add", "docs/"], "Stage"):
                return
            if not run_git(
                ["git", "commit", "-m",
                 f"Audit: {record['control_number']} | {anchor[:16]}"],
                "Commit"
            ):
                logger.warning("Nothing to commit")
                return
            if not run_git(["git", "fetch", "origin"], "Fetch"):
                return
            if not run_git(
                ["git", "pull", "--rebase", "origin", "main"], "Rebase"
            ):
                run_git(["git", "rebase", "--abort"], "Abort rebase")
                run_git(["git", "merge", "origin/main",
                         "-X", "ours", "--no-edit"], "Merge")
            run_git(["git", "push", "origin", "main"], "Push")
            logger.info(f"✅ GitHub Pages updated: {anchor[:16]}...")
        except Exception as e:
            logger.error(f"Sync error: {e}", exc_info=True)

# ── 15. Routes ────────────────────────────────────────────────────
@app.route("/")
def home():
    return render_template("portal.html")

@app.route("/cert_error.html")
def cert_error():
    return "<h1>Sovereign Identity Required</h1>", 403

@app.route("/lock_engine", methods=["POST"])
def lock_engine():
    logger.warning("Lock signal received — shutting down")
    threading.Timer(0.5, lambda: os.kill(os.getpid(), signal.SIGINT)).start()
    return "Engine locked. Vault sealed.", 200

@app.route("/status", methods=["GET"])
def status():
    try:
        with open(CHAIN_FILE) as f:
            chain_len = len(json.load(f).get("entries", []))
    except Exception:
        chain_len = 0
    rec_count = sum(
        len(files) for _, _, files in os.walk(RECORDS_DIR)
    )
    return jsonify({
        "status":        "OK",
        "vault_mounted": vault_ok(),
        "records":       rec_count,
        "chain_entries": chain_len,
    })

@app.route("/verify/<sha256>", methods=["GET"])
def verify_local(sha256: str):
    if not vault_ok():
        return jsonify({"status": "ERROR",
                        "message": "Vault not mounted"}), 503
    rec = find_existing_record(sha256)
    if rec:
        return jsonify({"status": "FOUND", "record": rec})
    return jsonify({"status": "NOT_FOUND", "sha256": sha256}), 404

@app.route("/upload", methods=["POST"])
def upload_pdf():
    if not vault_ok():
        return jsonify({
            "status":  "ERROR",
            "message": "Vault not mounted — re-insert Kingston USB and restart."
        }), 503

    try:
        file = request.files.get("document")
        if not file or not file.filename.lower().endswith(".pdf"):
            return "Only PDF files are accepted.", 400

        doc_type  = request.form.get("doc_type", "DOCUMENT")
        pdf_bytes = file.read()

        if len(pdf_bytes) > MAX_PDF:
            return f"File exceeds {MAX_PDF // (1024*1024)}MB limit.", 413

        # Fingerprint
        sha256 = hashlib.sha256(pdf_bytes).hexdigest()
        logger.info(f"Processing: {sha256[:16]}... ({len(pdf_bytes)//1024}KB)")

        # Duplicate check
        existing = find_existing_record(sha256)
        if existing:
            logger.warning(f"Duplicate: {sha256[:16]}...")
            return jsonify({
                "status":           "DUPLICATE",
                "message":          "This document was already processed.",
                "control_number":   existing.get("control_number"),
                "timestamp":        existing.get("timestamp"),
                "verification_url": existing.get("verification_url"),
            }), 409

        # Timestamp + control number
        tz        = pytz.timezone(TZ_NAME)
        now       = datetime.datetime.now(tz)
        timestamp = now.strftime("%Y-%m-%d %I:%M %p PHT")
        ts_iso    = now.isoformat()
        ctrl      = next_control_number()
        ctrl_full = f"Verified_{ctrl}-{doc_type}"

        # Hash chain
        seq        = get_next_seq()
        chain_hash = append_chain(seq, sha256, ts_iso)

        # Build and sign audit record
        record = {
            "status":            "VERIFIED ✅",
            "signer":            SIGNER_NAME,
            "position":          f"{SIGNER_POS} — {LGU_NAME}",
            "operator_identity": request.headers.get("X-Operator-ID", "PORTAL"),
            "document_type":     doc_type,
            "control_number":    ctrl_full,
            "sequence":          seq,
            "sha256_hash":       sha256,
            "chain_hash":        chain_hash,
            "timestamp":         timestamp,
            "timestamp_iso":     ts_iso,
            "verification_url":  f"{PORTAL_URL}?hash={sha256}",
            "vault_storage":     "LUKS2/AES-XTS-512/Argon2id — RA10173",
        }

        sig = sign_record(record)
        if sig:
            record["data_signature"] = sig

        # Write immutable record to date-organized vault
        rec_dir   = dated_subdir(RECORDS_DIR)
        json_path = os.path.join(rec_dir, f"{sha256}.json")
        with open(json_path, "w") as f:
            json.dump(record, f, indent=2)
        os.chmod(json_path, 0o400)  # read-only — immutable

        # Stamp PDF
        qr_buf, _     = make_qr(sha256)
        stamped_bytes = stamp_pdf(pdf_bytes, sha256, qr_buf,
                                  timestamp, ctrl_full, chain_hash, seq)

        # Archive stamped PDF in vault (immutable)
        pdf_dir  = dated_subdir(PDFS_DIR)
        pdf_path = os.path.join(pdf_dir, f"{ctrl_full}.pdf")
        with open(pdf_path, "wb") as f:
            f.write(stamped_bytes)
        os.chmod(pdf_path, 0o400)

        logger.info(f"✅ Record archived: {json_path}")
        logger.info(f"✅ PDF archived   : {pdf_path}")

        # Sync to GitHub Pages (background)
        threading.Thread(
            target=sync_to_github,
            args=(json_path, record),
            daemon=True
        ).start()

        logger.info(f"✅ Complete: {ctrl_full} | chain#{seq}")

        return send_file(
            io.BytesIO(stamped_bytes),
            as_attachment=True,
            download_name=f"{ctrl_full}.pdf",
            mimetype="application/pdf"
        )

    except Exception as e:
        logger.error(f"Upload error: {e}", exc_info=True)
        return jsonify({"status": "ERROR", "error": str(e)}), 500


if __name__ == "__main__":
    port = int(os.getenv("FLASK_PORT", 5000))
    logger.info(f"ORP Engine starting on 127.0.0.1:{port}")
    app.run(host="127.0.0.1", port=port, debug=False)
