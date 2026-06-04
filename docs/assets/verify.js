/**
 * verify.js — Document Verification Logic
 * OpenResPublica TruthChain · verify.html
 *
 * Flow:
 *   ?hash=<sha256>  →  auto-verify via ledger lookup
 *   (no hash)       →  render manual input form
 */

document.addEventListener('DOMContentLoaded', () => {
  const params   = new URLSearchParams(window.location.search);
  const fileHash = params.get('hash');
  const container = document.getElementById('card-container');

  if (fileHash) {
    executeVerification(fileHash.trim());
  } else {
    renderManualForm(container);
  }
});

// ── Helpers ────────────────────────────────────────────────────────────────

/**
 * HTML-escape to prevent XSS from ledger data injected via innerHTML.
 */
function escapeHtml(str) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

// ── Core verification flow ─────────────────────────────────────────────────

async function executeVerification(hash, retryCount = 0) {
  const container = document.getElementById('card-container');
  const msg = retryCount > 0
    ? `Propagation lag detected — retrying (${retryCount}/2)…`
    : 'Searching immutable ledger…';
  renderLoadingState(container, msg);

  try {
    const response = await fetch(`records/${hash}.json?t=${Date.now()}`);
    if (!response.ok) throw new Error('Record not found');
    const record = await response.json();
    renderVerificationSuccess(container, record);
  } catch {
    if (retryCount < 2) {
      setTimeout(() => executeVerification(hash, retryCount + 1), 8000);
    } else {
      renderVerificationFailure(
        container,
        'Record Not Found',
        'This document fingerprint could not be located in our ledger. ' +
        'If the certificate was issued within the last few minutes, the ' +
        'synchronization node may still be processing. Please wait 60 seconds and refresh.'
      );
    }
  }
}

// ── Render functions ───────────────────────────────────────────────────────

function renderLoadingState(container, message) {
  container.innerHTML = `
    <div class="status-banner status-pending">
      <div class="spinner"></div>
      <span>${escapeHtml(message)}</span>
    </div>
  `;
}

function renderVerificationSuccess(container, data) {
  // Optional PhilSys identity block
  const philIdBlock = data.philid_pcn ? `
    <h3 class="section-title">Verified Subject Identity</h3>
    <div class="data-grid">
      <div class="data-item">
        <span class="data-label">PhilSys PCN (Masked)</span>
        <span class="data-value">${escapeHtml(data.philid_pcn.replace(/.(?=.{4})/g, '•'))}</span>
      </div>
      <div class="data-item">
        <span class="data-label">Subject ID Salt-Hash</span>
        <span class="data-value" style="font-family:var(--font-mono);font-size:0.68rem;word-break:break-all;">${escapeHtml(data.philid_hash)}</span>
      </div>
    </div>
  ` : '';

  const gpgLabel = data.data_signature?.gpg_signature
    ? 'Valid OpenPGP Cryptographic Signature'
    : 'N/A';

  container.innerHTML = `
    <div class="status-banner status-verified">
      <span class="status-icon">✓</span>
      AUTHENTIC CIVIC RECORD — VERIFIED
    </div>
    <div class="card-body">

      <h3 class="section-title">Official Document Details</h3>
      <div class="data-grid">
        <div class="data-item">
          <span class="data-label">Control Number</span>
          <span class="data-value" style="font-weight:700;color:var(--navy-mid);">${escapeHtml(data.control_number) || '—'}</span>
        </div>
        <div class="data-item">
          <span class="data-label">Document Type</span>
          <span class="data-value"><span class="badge">${escapeHtml(data.document_type || 'GENERAL').toUpperCase()}</span></span>
        </div>
        <div class="data-item">
          <span class="data-label">Timestamp</span>
          <span class="data-value">${escapeHtml(data.timestamp) || '—'}</span>
        </div>
        <div class="data-item">
          <span class="data-label">Authorized Signatory</span>
          <span class="data-value">
            ${escapeHtml(data.signer) || '—'}
            ${data.position ? `<br><small style="color:var(--muted);font-size:0.8rem;">${escapeHtml(data.position)}</small>` : ''}
          </span>
        </div>
      </div>

      ${philIdBlock}

      <h3 class="section-title">TruthChain Cryptographic Audit Path</h3>
      <div class="crypto-proofs">

        <div class="crypto-item">
          <div class="crypto-icon">🔗</div>
          <div class="crypto-text">
            <strong>Document Body Hash (SHA-256)</strong>
            <span>${escapeHtml(data.sha256_hash) || '—'}</span>
          </div>
        </div>

        <div class="crypto-item">
          <div class="crypto-icon">🗄️</div>
          <div class="crypto-text">
            <strong>immudb Immutable Root Anchor</strong>
            <span>Transaction Block ID: #${escapeHtml(String(data.immudb_transaction_id || 'Anchored'))}</span>
          </div>
        </div>

        <div class="crypto-item">
          <div class="crypto-icon">✍️</div>
          <div class="crypto-text">
            <strong>Signatory GPG Integrity Seal</strong>
            <span>${escapeHtml(gpgLabel)}</span>
          </div>
        </div>

      </div>
    </div>
  `;
}

function renderVerificationFailure(container, title, message) {
  container.innerHTML = `
    <div class="status-banner status-error">
      <span class="status-icon">✕</span>
      ${escapeHtml(title)}
    </div>
    <div class="card-body" style="text-align:center;padding:2.5rem 2rem;">
      <p class="fallback-text">${escapeHtml(message)}</p>
      <button onclick="window.location.reload()" class="btn-retry">Retry Verification</button>
    </div>
  `;
}

function renderManualForm(container) {
  container.innerHTML = `
    <div class="status-banner" style="background:var(--navy-deep);">
      🔍 Manual Document Verification
    </div>
    <div class="card-body fallback-form">
      <p class="fallback-text">
        Paste the 64-character SHA-256 fingerprint printed on the footer of the
        document, or scan its QR code with a camera-enabled device.
      </p>
      <div class="form-group">
        <label class="form-label" for="manualHashInput">SHA-256 Document Fingerprint</label>
        <input
          type="text"
          id="manualHashInput"
          class="form-input"
          placeholder="e.g. 9c91053dfde699fe01d56f8acea8cfb3…"
          maxlength="64"
          autocomplete="off"
          spellcheck="false"
        >
        <p class="form-hint">Must be exactly 64 hexadecimal characters.</p>
      </div>
      <button id="manualSubmitBtn" class="btn-submit">Query Ledger Registry</button>
    </div>
  `;

  const btn   = document.getElementById('manualSubmitBtn');
  const input = document.getElementById('manualHashInput');

  function handleSubmit() {
    const hash = input.value.trim();
    if (/^[0-9a-fA-F]{64}$/.test(hash)) {
      executeVerification(hash);
    } else {
      input.classList.add('input-error');
      input.focus();
      setTimeout(() => input.classList.remove('input-error'), 2000);
    }
  }

  btn.addEventListener('click', handleSubmit);
  input.addEventListener('keydown', e => { if (e.key === 'Enter') handleSubmit(); });
  input.addEventListener('input', () => input.classList.remove('input-error'));
}
