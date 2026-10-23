// portal.js — ORP Engine Operator Portal
// Full polish edition: vault status strip, print panel,
// hash chain view, corrected ledger URLs, no immudb references.
'use strict';

// ── Constants ─────────────────────────────────────────────────────
const MANIFEST_URL =
    'https://openrespublica.github.io/orp-practice/docs/records/manifest.json';
const STATUS_URL   = '/status';
const UPLOAD_URL   = '/upload';
const PRINT_URL    = '/print';
const MAX_BYTES    = 20 * 1024 * 1024;
const LP           = 15;   // ledger rows per page

// ── State ─────────────────────────────────────────────────────────
let lData = [];
let lPage = 1;
let statusPollTimer = null;

// ── Boot ──────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
    initNavigation();
    initLockButton();
    initFileDrop('dropZone',      'pdfFile',   'selectedFileName');
    initFileDrop('printDropZone', 'printFile', 'printFileName');
    initUploadForm();
    initPrintForm();
    initLedgerPagination();
    startStatusPolling();
});

// ── Navigation ────────────────────────────────────────────────────
function initNavigation() {
    document.querySelectorAll('.nav-item[data-target]').forEach(btn => {
        btn.addEventListener('click', e => {
            e.preventDefault();
            const target = e.currentTarget.dataset.target;
            if (!target) return;

            document.querySelectorAll('.nav-item')
                    .forEach(n => { n.classList.remove('active');
                                    n.removeAttribute('aria-current'); });
            e.currentTarget.classList.add('active');
            e.currentTarget.setAttribute('aria-current', 'page');

            document.querySelectorAll('.panel')
                    .forEach(p => p.classList.remove('active'));
            const panel = document.getElementById('panel-' + target);
            if (panel) panel.classList.add('active');

            if (target === 'ledger')    loadLedger();
            if (target === 'dashboard') loadDashboard();
            if (target === 'chain')     loadChainView();
        });
    });
}

// ── Lock button ───────────────────────────────────────────────────
function initLockButton() {
    const btn = document.getElementById('lockBtn');
    if (!btn) return;
    btn.addEventListener('click', async () => {
        if (!confirm('Shut down engine and seal vault?\nThis cannot be undone.')) return;
        btn.disabled = true;
        btn.textContent = '⏳ Locking…';
        try {
            await fetch('/lock_engine', { method: 'POST' });
        } catch { /* connection reset is expected */ }
        document.body.innerHTML =
            '<div style="display:flex;align-items:center;justify-content:center;' +
            'min-height:100vh;font-family:system-ui;background:#001530;color:#fff;' +
            'flex-direction:column;gap:1rem;text-align:center;padding:2rem">' +
            '<div style="font-size:3rem">🏛</div>' +
            '<h1 style="margin:0;font-size:1.5rem">Engine locked</h1>' +
            '<p style="margin:0;opacity:0.6">Vault sealed. Session closed securely.</p>' +
            '</div>';
    });
}

// ── File drop ─────────────────────────────────────────────────────
function initFileDrop(zoneId, inputId, labelId) {
    const zone  = document.getElementById(zoneId);
    const input = document.getElementById(inputId);
    if (!zone || !input) return;

    zone.addEventListener('keydown', e => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); input.click(); }
    });
    zone.addEventListener('click', () => input.click());

    zone.addEventListener('dragover', e => {
        e.preventDefault(); e.stopPropagation();
        zone.classList.add('dragover');
    });
    zone.addEventListener('dragleave', () => zone.classList.remove('dragover'));
    zone.addEventListener('drop', e => {
        e.preventDefault(); e.stopPropagation();
        zone.classList.remove('dragover');
        const file = e.dataTransfer.files[0];
        if (file?.name.toLowerCase().endsWith('.pdf')) {
            input.files = e.dataTransfer.files;
            showFileLabel(labelId, file);
        } else {
            alert('Please drop a PDF file.');
        }
    });
    input.addEventListener('change', () => {
        if (input.files[0]) showFileLabel(labelId, input.files[0]);
    });
}

function showFileLabel(labelId, file) {
    const el = document.getElementById(labelId);
    if (!el) return;
    el.textContent   = `✓ ${file.name} (${(file.size/1024).toFixed(1)} KB)`;
    el.style.display = 'inline-block';
}

// ── Progress helpers ──────────────────────────────────────────────
function setProgress(prefix, barId, step, total) {
    for (let i = 1; i <= total; i++) {
        const el = document.getElementById(prefix + i);
        if (!el) continue;
        el.className = 'progress-step' +
            (i < step ? ' done' : i === step ? ' active' : '');
    }
    const bar = document.getElementById(barId);
    if (bar) bar.style.width = `${Math.min(100, (step / total) * 100)}%`;
}

function showResult(boxId, ok, title, details, blob, filename) {
    const el     = document.getElementById(boxId);
    el.className = 'result-box ' + (ok ? 'result-success' : 'result-error');
    el.style.display = 'block';

    let dHtml = '';
    if (details && typeof details === 'object') {
        dHtml = '<div class="result-kv">' +
            Object.entries(details).map(([k, v]) =>
                `<span class="result-key">${esc(k)}</span>` +
                `<span class="result-val">${esc(String(v))}</span>`
            ).join('') + '</div>';
    } else if (details) {
        dHtml = `<p style="margin-top:.5rem">${esc(String(details))}</p>`;
    }

    let dlHtml = '';
    if (blob && filename) {
        const url = URL.createObjectURL(blob);
        dlHtml = `<a href="${url}" download="${esc(filename)}" class="download-btn">` +
                 `⬇ Download ${esc(filename)}</a>`;
    }

    el.innerHTML =
        `<div class="result-header"><h4>${ok ? '✅' : '❌'} ${esc(title)}</h4></div>` +
        `<div class="result-body">${dHtml}${dlHtml}</div>`;
    el.setAttribute('role', 'alert');
}

function esc(str) {
    const d = document.createElement('div');
    d.textContent = str;
    return d.innerHTML;
}

function sanitizeDocType(val) {
    return val.toUpperCase()
              .replace(/[^A-Z0-9\-\s]/g, '')
              .trim()
              .replace(/\s+/g, '-')
              .slice(0, 30);
}

// ── Upload form ───────────────────────────────────────────────────
function initUploadForm() {
    const form = document.getElementById('uploadForm');
    if (!form) return;

    form.addEventListener('submit', async e => {
        e.preventDefault();
        const file     = document.getElementById('pdfFile').files[0];
        const typeEl   = document.getElementById('uploadDocType');
        const btn      = document.getElementById('uploadBtn');
        const progress = document.getElementById('uploadProgress');
        const result   = document.getElementById('uploadResult');

        if (!file) { alert('Please select a PDF file.'); return; }
        if (file.size > MAX_BYTES) {
            alert(`File too large. Max 20 MB, yours is ${(file.size/1024/1024).toFixed(1)} MB.`);
            return;
        }

        typeEl.value = sanitizeDocType(typeEl.value);
        const docType = typeEl.value || 'DOCUMENT';

        btn.disabled         = true;
        progress.style.display = 'block';
        result.style.display   = 'none';

        [1, 2, 3].forEach((s, i) =>
            setTimeout(() => setProgress('us', 'uploadBar', s, 4), i * 700 + 100));

        const fd = new FormData();
        fd.append('document', file);
        fd.append('doc_type', docType);

        try {
            const res = await fetch(UPLOAD_URL, {
                method: 'POST', body: fd,
                signal: AbortSignal.timeout(180000)
            });
            setProgress('us', 'uploadBar', 4, 4);

            if (res.ok) {
                const blob        = await res.blob();
                const disposition = res.headers.get('Content-Disposition') || '';
                const filename    = disposition.match(/filename="?([^"]+)"?/)?.[1]
                                    || `${docType}.pdf`;
                showResult('uploadResult', true, 'Anchored to TruthChain',
                    { File: file.name, Type: docType,
                      Status: 'Anchored · publishing to ledger…' },
                    blob, filename);
            } else {
                let msg = '';
                try { const j = await res.json(); msg = j.message || j.error || ''; }
                catch { msg = await res.text(); }
                showResult('uploadResult', false, 'Upload failed', msg);
            }
        } catch (err) {
            const msg = err.name === 'AbortError'
                ? 'Request timed out. The server may be busy.' : err.message;
            showResult('uploadResult', false, 'Connection error', msg);
        } finally {
            btn.disabled = false;
            setTimeout(() => {
                progress.style.display = 'none';
                setProgress('us', 'uploadBar', 0, 4);
            }, 3500);
        }
    });
}

// ── Print form ────────────────────────────────────────────────────
function initPrintForm() {
    const form = document.getElementById('printForm');
    if (!form) return;

    form.addEventListener('submit', async e => {
        e.preventDefault();
        const file     = document.getElementById('printFile').files[0];
        const typeEl   = document.getElementById('printDocType');
        const btn      = document.getElementById('printBtn');
        const progress = document.getElementById('printProgress');
        const result   = document.getElementById('printResult');

        if (!file) { alert('Please select a PDF file.'); return; }
        if (file.size > MAX_BYTES) {
            alert(`File too large. Max 20 MB.`);
            return;
        }

        typeEl.value = sanitizeDocType(typeEl.value);
        const docType = typeEl.value || 'PRINT';

        btn.disabled           = true;
        progress.style.display = 'block';
        result.style.display   = 'none';

        [1, 2, 3].forEach((s, i) =>
            setTimeout(() => setProgress('ps', 'printBar', s, 4), i * 700 + 100));

        const fd = new FormData();
        fd.append('document', file);
        fd.append('doc_type', docType);

        try {
            const res = await fetch(PRINT_URL, {
                method: 'POST',
                headers: { 'X-Print-Source': 'portal' },
                body: fd,
                signal: AbortSignal.timeout(180000)
            });
            setProgress('ps', 'printBar', 4, 4);

            if (res.ok) {
                const blob        = await res.blob();
                const disposition = res.headers.get('Content-Disposition') || '';
                const filename    = disposition.match(/filename="?([^"]+)"?/)?.[1]
                                    || `${docType}-PRINT.pdf`;

                // Download stamped PDF
                const url = URL.createObjectURL(blob);
                const a   = document.createElement('a');
                a.href = url; a.download = filename; a.click();

                showResult('printResult', true, 'Stamped — ready to print',
                    { File: file.name, Type: docType,
                      Downloaded: filename,
                      Note: 'Open the file and press Ctrl+P to print.' },
                    null, null);

                // Open in new tab so browser print dialog is available
                setTimeout(() => {
                    const w = window.open(url);
                    if (w) w.addEventListener('load', () => w.print(), { once: true });
                }, 1200);
            } else {
                let msg = '';
                try { const j = await res.json(); msg = j.message || j.error || ''; }
                catch { msg = await res.text(); }
                showResult('printResult', false, 'Print stamp failed', msg);
            }
        } catch (err) {
            showResult('printResult', false, 'Connection error', err.message);
        } finally {
            btn.disabled = false;
            setTimeout(() => {
                progress.style.display = 'none';
                setProgress('ps', 'printBar', 0, 4);
            }, 3500);
        }
    });
}

// ── Live status polling ───────────────────────────────────────────
function startStatusPolling() {
    pollStatus();
    statusPollTimer = setInterval(pollStatus, 15000);
}

async function pollStatus() {
    const pip    = document.getElementById('enginePip');
    const label  = document.getElementById('engineStatus');
    const strip  = document.getElementById('vaultStrip');
    const pill   = document.getElementById('vaultPill');
    const chain  = document.getElementById('stripChain');
    const recs   = document.getElementById('stripRecords');
    const time   = document.getElementById('stripTime');

    try {
        const res  = await fetch(STATUS_URL, { signal: AbortSignal.timeout(5000) });
        if (!res.ok) throw new Error('Non-200');
        const data = await res.json();

        if (pip) {
            pip.className = 'status-pip status-pip--online';
        }
        if (label) label.textContent = 'Engine online';

        if (strip) strip.style.display = 'flex';
        if (pill) {
            pill.textContent = data.vault_mounted ? '⬤ Vault mounted' : '⬤ Vault sealed';
            pill.className   = data.vault_mounted
                ? 'vault-pill vault-pill--mounted'
                : 'vault-pill vault-pill--sealed';
        }
        if (chain)  chain.textContent   = `Chain #${data.chain_entries ?? '—'}`;
        if (recs)   recs.textContent    = `${data.records ?? '—'} records`;
        if (time)   time.textContent    = new Date().toLocaleTimeString('en-PH',
                        { hour: '2-digit', minute: '2-digit' }) + ' PHT';

        // Sync dashboard stats if panel is visible
        const dChain = document.getElementById('dChain');
        const dVault = document.getElementById('dVault');
        if (dChain) dChain.textContent = data.chain_entries ?? '—';
        if (dVault) dVault.textContent = data.vault_mounted ? '✓ Mounted' : '⚠ Sealed';

    } catch {
        if (pip)   pip.className   = 'status-pip status-pip--offline';
        if (label) label.textContent = 'Engine offline';
        if (strip) strip.style.display = 'none';
    }
}

// ── Ledger ────────────────────────────────────────────────────────
async function loadLedger() {
    document.getElementById('ledgerBody').innerHTML =
        '<tr><td colspan="6" style="text-align:center;padding:1.5rem;color:var(--muted)">' +
        '<div class="spinner"></div> Loading…</td></tr>';
    try {
        const res = await fetch(MANIFEST_URL + '?t=' + Date.now(),
                                { signal: AbortSignal.timeout(15000) });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        lData = await res.json();
        lPage = 1;
        renderLedgerTable();
    } catch (err) {
        document.getElementById('ledgerBody').innerHTML =
            '<tr><td colspan="6" style="text-align:center;padding:1.5rem;color:var(--muted)">' +
            'Could not load manifest. Check your connection.</td></tr>';
    }
}

function renderLedgerTable() {
    const total = lData.length;
    const start = (lPage - 1) * LP;
    const end   = Math.min(start + LP, total);

    document.getElementById('ledgerBody').innerHTML =
        lData.slice(start, end).map(r => `
        <tr>
            <td><strong class="ctrl-no">${esc(r.control_number || '—')}</strong></td>
            <td><span class="badge-type">${esc(r.document_type || 'GENERAL')}</span></td>
            <td style="font-size:.75rem;color:var(--muted)">${esc(r.timestamp || '—')}</td>
            <td><span class="mono">${esc((r.sha256_hash||'').slice(0,14))}…</span></td>
            <td><span class="mono">#${esc(String(r.sequence || '—'))}</span></td>
            <td style="text-align:center">
                <a href="https://openrespublica.github.io/orp-practice/verify.html?hash=${encodeURIComponent(r.sha256_hash)}"
                   target="_blank" rel="noopener noreferrer" class="btn-outline">Verify</a>
            </td>
        </tr>`).join('');

    const countEl = document.getElementById('ledgerCount');
    if (countEl) countEl.textContent = `Showing ${start+1}–${end} of ${total}`;

    const prevBtn = document.getElementById('lPrev');
    const nextBtn = document.getElementById('lNext');
    if (prevBtn) prevBtn.disabled = lPage === 1;
    if (nextBtn) nextBtn.disabled = end >= total;
}

function initLedgerPagination() {
    document.getElementById('lPrev')?.addEventListener('click', () => {
        lPage = Math.max(1, lPage - 1);
        renderLedgerTable();
        document.querySelector('table')?.scrollIntoView({ behavior: 'smooth' });
    });
    document.getElementById('lNext')?.addEventListener('click', () => {
        lPage = Math.min(lPage + 1, Math.ceil(lData.length / LP));
        renderLedgerTable();
        document.querySelector('table')?.scrollIntoView({ behavior: 'smooth' });
    });
}

// ── Dashboard ─────────────────────────────────────────────────────
async function loadDashboard() {
    try {
        const res  = await fetch(MANIFEST_URL + '?t=' + Date.now(),
                                 { signal: AbortSignal.timeout(15000) });
        if (!res.ok) return;
        const data = await res.json();
        const el   = (id, val) => {
            const e = document.getElementById(id);
            if (e) e.textContent = val;
        };
        el('dTotal',  data.length);
        el('dLatest', (data[0]?.timestamp || '').split(' ')[0] || '—');
    } catch { /* non-critical */ }
}

// ── Hash chain view ───────────────────────────────────────────────
async function loadChainView() {
    const container = document.getElementById('chainView');
    if (!container) return;
    container.innerHTML =
        '<p style="color:var(--muted);font-size:.88rem">Loading chain…</p>';

    try {
        const res  = await fetch('/status', { signal: AbortSignal.timeout(5000) });
        const data = await res.json();

        if (!data.vault_mounted) {
            container.innerHTML =
                '<p style="color:var(--muted)">Vault not mounted — ' +
                'insert Kingston USB and restart the engine.</p>';
            return;
        }

        // Fetch chain from the local engine's manifest
        const mres  = await fetch(MANIFEST_URL + '?t=' + Date.now(),
                                  { signal: AbortSignal.timeout(10000) });
        const recs  = await mres.json();

        if (!recs.length) {
            container.innerHTML =
                '<p style="color:var(--muted)">No records yet.</p>';
            return;
        }

        const rows = recs.slice(0, 20).map(r => `
            <div class="chain-entry">
                <div class="chain-seq">#${esc(String(r.sequence || '—'))}</div>
                <div class="chain-meta">
                    <div class="ctrl-no">${esc(r.control_number || '—')}</div>
                    <div class="chain-hashes">
                        <span class="mono" title="SHA-256">${esc((r.sha256_hash||'').slice(0,20))}…</span>
                        <span class="chain-arrow">→</span>
                        <span class="mono chain-hash-val" title="Chain hash">
                            ${esc((r.chain_hash||'').slice(0,20))}…
                        </span>
                    </div>
                    <div style="font-size:.72rem;color:var(--muted);margin-top:.2rem">
                        ${esc(r.timestamp || '')}
                    </div>
                </div>
                <div class="chain-status">
                    ${r.status?.includes('✅') || r.status?.includes('VERIFIED')
                        ? '<span class="badge-ok">✓ Verified</span>'
                        : '<span class="badge-type">' + esc(r.document_type||'') + '</span>'}
                </div>
            </div>`).join('');

        container.innerHTML =
            `<p style="font-size:.8rem;color:var(--muted);margin-bottom:.75rem">
                Showing last ${Math.min(20, recs.length)} of ${recs.length} entries.
                Each entry's chain hash is derived from the previous — any tampering
                breaks the sequence.
            </p>` + rows;

    } catch (err) {
        container.innerHTML =
            `<p style="color:var(--muted)">Could not load chain: ${esc(err.message)}</p>`;
    }
}
