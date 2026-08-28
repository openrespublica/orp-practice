#!/bin/bash
# orp_verify_chain.sh — Verify hash chain integrity offline
set -euo pipefail

VAULT_MOUNT="${ORP_VAULT_MOUNT:-/mnt/orp_vault}"
CHAIN_FILE="$VAULT_MOUNT/chain.json"

[ -f "$CHAIN_FILE" ] || { echo "[✘] Chain file not found: $CHAIN_FILE"; exit 1; }

echo ""
echo "══════════════════════════════════════════════════"
echo "  ORP Hash Chain Verification"
echo "══════════════════════════════════════════════════"
echo ""

python3 - "$CHAIN_FILE" << 'PYEOF'
import json, hashlib, sys

with open(sys.argv[1]) as f:
    chain = json.load(f)

entries = chain.get("entries", [])
genesis = chain.get("genesis", "0" * 64)

if not entries:
    print("  Chain is empty — no documents processed yet.")
    sys.exit(0)

errors = 0
prev   = genesis

for e in entries:
    seq        = e["seq"]
    doc_hash   = e["sha256_hash"]
    prev_stored = e["prev_chain_hash"]
    stored_hash = e["chain_hash"]
    ts          = e["timestamp"]

    if prev_stored != prev:
        print(f"  [✘] CHAIN BREAK at #{seq}: prev_hash mismatch")
        errors += 1

    computed = hashlib.sha256(
        f"{seq}|{doc_hash}|{prev_stored}|{ts}".encode()
    ).hexdigest()

    if computed != stored_hash:
        print(f"  [✘] TAMPERED at #{seq}: hash mismatch")
        errors += 1
    else:
        print(f"  [✔] #{seq:04d} {stored_hash[:24]}... {ts[:19]}")

    prev = stored_hash

print("")
if errors == 0:
    print(f"  ✅ Chain VALID — {len(entries)} entries, no tampering detected.")
else:
    print(f"  ❌ Chain COMPROMISED — {errors} error(s) found!")
    sys.exit(1)
print("")
PYEOF
