// verify.js — TruthChain Document Verification
// Reads config from window.__orp_config (set by config-loader.js).
// URL layout on GitHub Pages (docs/ is the web root):
//   manifest : /orp-practice/records/manifest.json
//   record   : /orp-practice/records/<sha256>.json
'use strict';

(function () {

function esc(str) {
    const d = document.createElement('div');
    d.textContent = String(str ?? '');
    return d.innerHTML;
}

function fmtHash(h) {
    if (!h || h === '—') return '—';
    return ['hash-block'].reduce(() =>
        `<span class="hash-block">${h.slice(0,16)}</span>` +
        `<span class="hash-block">${h.slice(16,32)}</span>` +
        `<span class="hash-block">${h.slice(32,48)}</span>` +
        `<span class="hash-block">${h.slice(48)}</span>`, '');
}

function urls(config) {
    const base = config?.github?.base_url
        || 'https://openrespublica.github.io/orp-practice';
    return {
        manifest: config?.github?.manifest_url
            || `${base}/records/manifest.json`,
        record: hash => config?.github?.records_url
            ? `${config.github.records_url}${hash}.json`
            : `${base}/records/${hash}.json`,
    };
}

async function lookupHash(hash, config) {
    const u = urls(config);

    // 1. Direct record file — fastest, O(1)
    try {
        const res = await fetch(
            u.record(hash) + '?t=' + Date.now(),
            { signal: AbortSignal.timeout(10000) }
        );
        if (res.ok) {
            const r = await res.json();
            // Verify the record actually matches (not a false 200)
            if (r.sha256_hash === hash) return r;
        }
    } catch { /* fall through */ }

    // 2. Manifest scan — fallback for older records
    try {
        const res = await fetch(
            u.manifest + '?t=' + Date.now(),
            { signal: AbortSignal.timeout(15000) }
        );
        if (!res.ok) throw new Error('Manifest HTTP ' + res.status);
        const list = await res.json();
        return list.find(r => r.sha256_hash === hash) ?? null;
    } catch (err) {
        console.error('[verify] manifest lookup failed:', err);
        return null;
    }
}

function renderFound(record) {
    hide('verifyStatus'); hide('resultNotFound');
    show('resultFound');

    const fields = {
        'Control number': record.control_number,
        'Document type':  record.document_type,
        'Issued':         record.timestamp,
        'Operator':       record.signer,
        'Position':       record.position,
        'Status':         record.status,
        'Chain seq':      record.sequence != null ? `#${record.sequence}` : '—',
    };

    document.getElementById('resultDetails').innerHTML =
        Object.entries(fields)
            .map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(String(v ?? '—'))}</dd>`)
            .join('');

    const sig = record.data_signature || {};
    document.getElementById('resultChain').innerHTML = `
        <h3>Cryptographic anchors</h3>
        <dl>
            <dt>SHA-256 fingerprint</dt>
            <dd class="hash-formatted">${fmtHash(record.sha256_hash)}</dd>
            <dt>Chain hash</dt>
            <dd class="hash-formatted">${fmtHash(record.chain_hash || '—')}</dd>
            <dt>Integrity scope</dt>
            <dd>${esc(sig.integrity_scope || '—')}</dd>
        </dl>`;

    document.getElementById('resultSig').innerHTML = `
        <details class="sig-details">
            <summary>GPG signature</summary>
            <pre class="sig-pre">${esc(sig.gpg_signature || '(none)')}</pre>
        </details>`;

    document.getElementById('resultFound')
        .scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function renderNotFound(hash) {
    hide('verifyStatus'); hide('resultFound');
    show('resultNotFound');
    const el = document.getElementById('notFoundHash');
    if (el) el.textContent = hash;
    document.getElementById('resultNotFound')
        .scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function show(id) {
    const el = document.getElementById(id);
    if (el) el.style.display = 'block';
}
function hide(id) {
    const el = document.getElementById(id);
    if (el) el.style.display = 'none';
}

async function run(hash, config) {
    const btn = document.getElementById('verifyBtn');
    if (btn) btn.disabled = true;
    hide('resultFound'); hide('resultNotFound');
    show('verifyStatus');

    try {
        const record = await lookupHash(hash, config);
        if (record) renderFound(record);
        else        renderNotFound(hash);
    } finally {
        if (btn) btn.disabled = false;
    }
}

function init(config) {
    // Pre-fill from ?hash= query param or #hash fragment
    const params    = new URLSearchParams(window.location.search);
    const urlHash   = params.get('hash')
                   || window.location.hash.replace('#', '');
    const input     = document.getElementById('hashInput');

    if (urlHash && /^[0-9a-fA-F]{64}$/.test(urlHash)) {
        if (input) input.value = urlHash;
        run(urlHash.toLowerCase(), config);
    }

    const form = document.getElementById('verifyForm');
    if (!form) return;

    form.addEventListener('submit', e => {
        e.preventDefault();
        const val = (input?.value || '').trim().toLowerCase();
        if (!/^[0-9a-f]{64}$/.test(val)) {
            if (input) {
                input.setCustomValidity(
                    'Please enter a valid 64-character SHA-256 hash.');
                input.reportValidity();
            }
            return;
        }
        input?.setCustomValidity('');
        history.replaceState(null, '', `?hash=${val}`);
        run(val, config);
    });

    input?.addEventListener('input', () => input.setCustomValidity(''));
}

// Boot — wait for config-loader.js
if (window.__orp_config) {
    init(window.__orp_config);
} else {
    document.addEventListener('orp:config', e => init(e.detail));
    setTimeout(() => { if (!window.__orp_config) init(null); }, 3000);
}

})();
