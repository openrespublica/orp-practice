document.addEventListener('DOMContentLoaded', () => {
    const params = new URLSearchParams(window.location.search);
    const fileHash = params.get('hash');
    const container = document.getElementById('card-container');

    if (fileHash) {
        // A direct QR code scan target hash was given
        executeVerification(fileHash.trim());
    } else {
        // Fallback interface for manual record lookup
        renderManualForm(container);
    }
});

/**
 * Executes async fetch operation to find cryptographic proof records
 */
async function executeVerification(hash, retryCount = 0) {
    const container = document.getElementById('card-container');
    
    // Set loading visual status display
    renderLoadingState(container, retryCount > 0 ? `Propagation lag detected... Retrying signature verification (Attempt ${retryCount}/2)...` : "Searching Immutable Ledger...");

    try {
        // Prevent aggressive local browser caching using timestamp flags
        const response = await fetch(`records/${hash}.json?t=${Date.now()}`);
        
        if (!response.ok) throw new Error("Target ledger record missing");
        
        const recordData = await response.json();
        renderVerificationSuccess(container, recordData);
    } catch (error) {
        // Attempt network fallback logic if synchronization lag occurs
        if (retryCount < 2) {
            setTimeout(() => {
                executeVerification(hash, retryCount + 1);
            }, 8000); // 8-second window before secondary checking sequence
        } else {
            renderVerificationFailure(
                container, 
                "Verification Pending or Not Found", 
                "This document hash could not be located in our ledger system. If this certificate was issued within the last few minutes, the secure background synchronization node may still be processing data. Please wait 60 seconds and refresh."
            );
        }
    }
}

/**
 * Renders the loading spinner overlay with updated copy context
 */
function renderLoadingState(container, message) {
    container.innerHTML = `
        <div class="status-banner status-pending">
            <div class="spinner"></div>
            ${escapeHtml(message)}
        </div>
    `;
}

/**
 * Generates the clean validated document information card structural layout
 */
function renderVerificationSuccess(container, data) {
    // Check for optional PhilID structural fields securely
    const philIdMarkup = data.philid_pcn ? `
        <h3 class="section-title">Verified Subject Identity</h3>
        <div class="data-grid">
            <div class="data-item">
                <span class="data-label">PhilSys PCN (Masked)</span>
                <span class="data-value">${escapeHtml(data.philid_pcn.replace(/.(?=.{4})/g, '*'))}</span>
            </div>
            <div class="data-item">
                <span class="data-label">Subject ID Salt-Hash</span>
                <span class="data-value data-mono" style="font-size: 0.65rem;">${escapeHtml(data.philid_hash)}</span>
            </div>
        </div>
    ` : '';

    const gpgSignatureLabel = data.data_signature?.gpg_signature ? "Valid OpenPGP Cryptographic Signature" : "N/A";

    container.innerHTML = `
        <div class="status-banner status-verified">
            ✅ AUTHENTIC CIVIC RECORD VERIFIED
        </div>
        <div class="card-body">
            <h3 class="section-title">Official Document Details</h3>
            <div class="data-grid">
                <div class="data-item">
                    <span class="data-label">Control Number</span>
                    <span class="data-value" style="font-weight: 700; color: var(--navy-mid);">${escapeHtml(data.control_number) || '—'}</span>
                </div>
                <div class="data-item">
                    <span class="data-label">Document Type Classification</span>
                    <span class="data-value"><span class="badge">${escapeHtml(data.document_type).toUpperCase() || 'GENERAL'}</span></span>
                </div>
                <div class="data-item">
                    <span class="data-label">Cryptographic Timestamp</span>
                    <span class="data-value">${escapeHtml(data.timestamp) || '—'}</span>
                </div>
                <div class="data-item">
                    <span class="data-label">Authorized Public Signatory</span>
                    <span class="data-value">
                        ${escapeHtml(data.signer) || '—'}<br>
                        <small style="color: var(--muted); font-size: 0.8rem;">${escapeHtml(data.position) || ''}</small>
                    </span>
                </div>
            </div>

            ${philIdMarkup}

            <div class="crypto-proofs">
                <h3 class="section-title" style="margin-top: 0; padding-bottom: 0.3rem; font-size: 1rem;">TruthChain Cryptographic Audit Path</h3>
                
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
                        <span>Transaction Block ID: #${escapeHtml(data.immudb_transaction_id) || 'Anchored'}</span>
                    </div>
                </div>
                
                <div class="crypto-item">
                    <div class="crypto-icon">✍️</div>
                    <div class="crypto-text">
                        <strong>Signatory GPG Integrity Seal</strong>
                        <span>${escapeHtml(gpgSignatureLabel)}</span>
                    </div>
                </div>
            </div>
        </div>
    `;
}

/**
 * Handles error display rendering logic
 */
function renderVerificationFailure(container, title, message) {
    container.innerHTML = `
        <div class="status-banner status-error">
            ⚠️ ${escapeHtml(title)}
        </div>
        <div class="card-body" style="text-align: center; padding: 3rem 2rem;">
            <p class="fallback-text">${escapeHtml(message)}</p>
            <button onclick="window.location.reload()" class="btn-submit" style="display:inline-block; width:auto; padding: 10px 24px;">Refresh Engine</button>
        </div>
    `;
}

/**
 * Renders manual input form elements when direct queries are missing
 */
function renderManualForm(container) {
    container.innerHTML = `
        <div class="status-banner status-pending" style="background: var(--navy-deep);">
            🔍 Manual Document Verification Lookup
        </div>
        <div class="card-body fallback-form">
            <p class="fallback-text">
                Welcome to the OpenResPublica Verification Portal. If you do not have a camera or QR reader handy, paste the target SHA-256 document string printed on the footer of the legal certificate below.
            </p>
            <div class="form-group">
                <label class="form-label" for="manualHashInput">Enter 64-Character Document Hash</label>
                <input type="text" id="manualHashInput" class="form-input" placeholder="e.g., 9c91053dfde699fe01d56f8acea8cfb3..." maxlength="64" autocomplete="off">
            </div>
            <button id="manualSubmitBtn" class="btn-submit">Query Ledger Registry</button>
        </div>
    `;

    // Hook up manual submission button event handling actions
    const submitBtn = document.getElementById('manualSubmitBtn');
    const inputField = document.getElementById('manualHashInput');

    const handleSubmission = () => {
        const structuralHashValue = inputField.value.trim();
        if (structuralHashValue.length === 64) {
            // Re-route to standard lookup processing execution paths
            executeVerification(structuralHashValue);
        } else {
            alert("Invalid input: Please ensure your hash is exactly 64 characters long.");
        }
    };

    submitBtn.addEventListener('click', handleSubmission);
    inputField.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') handleSubmission();
    });
}

/**
 * Strict structural context HTML escaping sanitizer helper component
 */
function escapeHtml(unsafeString) {
    if (!unsafeString) return '';
    return String(unsafeString)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
}
