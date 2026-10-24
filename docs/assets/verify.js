// verify.js — TruthChain Document Verification
// Reads config from window.__orp_config set by config-loader.js
'use strict';

(function () {

function esc(str) {
    const d = document.createElement('div');
    d.textContent = String(str ?? '');
    return d.innerHTML;
}

function fmtHash(h) {
    if (!h) return '—';
    return `<span class="hash-block">${h.slice(0,16)}</span>` +
           `<span class="hash-block">${h.slice(16,32)}</span>` +
           `<span class="hash-block">${h.slice(32,48)}</span>` +
           `<span class="hash-block">${h.slice(48)}</span>`;
}

function getManifestUrl(config) {
    return config?.github?.manifest_url
        || 'https://openrespublica.github.io/orp-practice/docs/records/manifest.json';
}

function getRecordUrl(config, hash) {
    const base = (config?.github?.manifest_url || '')
        .replace('manifest.json', '');
    return `${base}${hash}.json`;
}

async function verify(hash, config) {
    // 1. Try direct record file first (fastest)
    try {
        const url = getRecordUrl(config, hash);
        const res = await fetch(url + '?t=' + Date.now(),
                                { signal: AbortSignal.timeout(10000) });
        if (res.ok) {
            const record = await res.json();
            if (record.sha256_hash === hash) return record;
        }
    } catch { /* fall through to manifest search */ }

    // 2. Fall back to manifest search
    try {
        const murl = getManifestUrl(config);
        const res  = await fetch(murl + '?t=' + Date.now(),
                                 { signal: AbortSignal.timeout(15000) });
        if (!res.ok) throw new Error('Manifest fetch failed');
        const records = await res.json();
        return records.find(r => r.sha256_hash === hash) || null;
    } catch {
        return null;
    }
}

function showFound(record) {
    document.getElementById('verifyStatus').style.display   = 'none';
    document.getElementById('resultNotFound').style.display = 'none';
    const found = document.getElementById('resultFound');
    found.style.display = 'block';

    const fields = {
        'Control number':  record.control_number,
        'Document type':   record.document_type,
        'Issued':          record.timestamp,
        'Operator':        record.signer,
        'Position':        record.position,
        'Status':          record.status,
        'Chain sequence':  record.sequence != null ? `#${record.sequence}` : '—',
    };

    document.getElementById('resultDetails').innerHTML =
        Object.entries(fields).map(([k, v]) =>
            `<dt>${esc(k)}</dt><dd>${esc(String(v ?? '—'))}</dd>`
        ).join('');

    // Hash display
    const sig = record.data_signature || {};
    document.getElementById('resultChain').innerHTML = `
        <h3>Cryptographic anchors</h3>
        <dl>
            <dt>SHA-256 fingerprint</dt>
            <dd class="hash-formatted">${fmtHash(record.sha256_hash)}</dd>
            <dt>Chain hash</dt>
            <dd class="hash-formatted">${fmtHash(record.chain_hash)}</dd>
            <dt>Integrity scope</dt>
            <dd>${esc(sig.integrity_scope || '—')}</dd>
        </dl>`;

    document.getElementById('resultSig').innerHTML = `
        <details class="sig-details">
            <summary>GPG signature</summary>
            <pre class="sig-pre">${esc(sig.gpg_signature || '(none)')}</pre>
        </details>`;

    found.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function showNotFound(hash) {
    document.getElementById('verifyStatus').style.display   = 'none';
    document.getElementById('resultFound').style.display    = 'none';
    const nf = document.getElementById('resultNotFound');
    nf.style.display = 'block';
    const el = document.getElementById('notFoundHash');
    if (el) el.textContent = hash;
    nf.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function showLoading(show) {
    const el = document.getElementById('verifyStatus');
    if (el) el.style.display = show ? 'block' : 'none';
    document.getElementById('resultFound').style.display    = 'none';
    document.getElementById('resultNotFound').style.display = 'none';
}

async function run(hash, config) {
    const btn = document.getElementById('verifyBtn');
    if (btn) btn.disabled = true;
    showLoading(true);
    try {
        const record = await verify(hash, config);
        if (record) showFound(record);
        else         showNotFound(hash);
    } finally {
        if (btn) btn.disabled = false;
    }
}

function initForm(config) {
    // Pre-fill hash from URL ?hash= or #hash
    const params = new URLSearchParams(window.location.search);
    const hashParam = params.get('hash') || window.location.hash.replace('#', '');
    const input = document.getElementById('hashInput');

    if (hashParam && /^[0-9a-fA-F]{64}$/.test(hashParam)) {
        if (input) input.value = hashParam;
        run(hashParam.toLowerCase(), config);
    }

    const form = document.getElementById('verifyForm');
    if (!form) return;
    form.addEventListener('submit', e => {
        e.preventDefault();
        const val = (input?.value || '').trim().toLowerCase();
        if (!/^[0-9a-f]{64}$/.test(val)) {
            input?.setCustomValidity('Please enter a valid 64-character SHA-256 hash.');
            input?.reportValidity();
            return;
        }
        input?.setCustomValidity('');
        // Update URL without reload for shareability
        history.replaceState(null, '', `?hash=${val}`);
        run(val, config);
    });

    input?.addEventListener('input', () => input.setCustomValidity(''));
}

// Wait for config to be ready
if (window.__orp_config) {
    initForm(window.__orp_config);
} else {
    document.addEventListener('orp:config', ({ detail }) => initForm(detail));
    // Fallback in case config fails
    setTimeout(() => {
        if (!window.__orp_config) initForm(null);
    }, 3000);
}

})();
