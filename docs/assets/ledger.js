// ledger.js — TruthChain Public Ledger
// GitHub Pages URL: /orp-practice/records/manifest.json
'use strict';

(function () {

const PER_PAGE = 20;
let all      = [];
let filtered = [];
let page     = 1;

function esc(str) {
    const d = document.createElement('div');
    d.textContent = String(str ?? '');
    return d.innerHTML;
}

function manifestUrl(config) {
    return config?.github?.manifest_url
        || 'https://openrespublica.github.io/orp-practice/records/manifest.json';
}

function verifyUrl(hash) {
    return `verify.html?hash=${encodeURIComponent(hash)}`;
}

async function load(config) {
    setBody('<tr><td colspan="6" class="tbl-center"><div class="spinner"></div> Loading…</td></tr>');
    try {
        const res = await fetch(
            manifestUrl(config) + '?t=' + Date.now(),
            { signal: AbortSignal.timeout(20000) }
        );
        if (!res.ok) throw new Error('HTTP ' + res.status);
        all      = await res.json();
        filtered = all;
        page     = 1;
        renderTable();
        initSearch();
        updateStats();
    } catch (err) {
        setBody(`<tr><td colspan="6" class="tbl-center tbl-error">
            Could not load ledger. Check your connection.<br>
            <small style="font-family:monospace">${esc(err.message)}</small>
        </td></tr>`);
        const c = document.getElementById('ledgerCount');
        if (c) c.textContent = 'Failed to load';
    }
}

function setBody(html) {
    const el = document.getElementById('ledgerBody');
    if (el) el.innerHTML = html;
}

function renderTable() {
    const start = (page - 1) * PER_PAGE;
    const end   = Math.min(start + PER_PAGE, filtered.length);
    const rows  = filtered.slice(start, end);

    setBody(rows.length ? rows.map(r => `
        <tr>
            <td><span class="chain-seq-badge">#${esc(String(r.sequence ?? '—'))}</span></td>
            <td><span class="ctrl-no">${esc(r.control_number ?? '—')}</span></td>
            <td><span class="badge-type">${esc(r.document_type ?? 'GENERAL')}</span></td>
            <td class="ts-cell">${esc((r.timestamp ?? '').split(' ').slice(0,2).join(' '))}</td>
            <td title="${esc(r.sha256_hash ?? '')}">
                <span class="hash-short">${esc((r.sha256_hash ?? '').slice(0,16))}…</span>
            </td>
            <td style="text-align:center">
                <a href="${verifyUrl(r.sha256_hash ?? '')}"
                   class="btn-verify-link">Verify</a>
            </td>
        </tr>`).join('')
    : '<tr><td colspan="6" class="tbl-center">No records found.</td></tr>');

    // Pagination controls
    setText('pageInfo', filtered.length
        ? `Showing ${start + 1}–${end} of ${filtered.length}`
        : 'No results');
    setText('ledgerCount', `${filtered.length} record${filtered.length !== 1 ? 's' : ''}`);

    const prevBtn = document.getElementById('lPrev');
    const nextBtn = document.getElementById('lNext');
    if (prevBtn) prevBtn.disabled = page === 1;
    if (nextBtn) nextBtn.disabled = end >= filtered.length;
}

function setText(id, val) {
    const el = document.getElementById(id);
    if (el) el.textContent = val;
}

function updateStats() {
    setText('statTotal',  all.length);
    setText('statLatest', all[0]?.timestamp?.split(' ')[0] || '—');
}

function initSearch() {
    const box = document.getElementById('searchBox');
    if (!box) return;
    box.addEventListener('input', () => {
        const q = box.value.trim().toLowerCase();
        filtered = q ? all.filter(r =>
            (r.control_number ?? '').toLowerCase().includes(q) ||
            (r.document_type  ?? '').toLowerCase().includes(q) ||
            (r.sha256_hash    ?? '').toLowerCase().includes(q) ||
            (r.timestamp      ?? '').toLowerCase().includes(q) ||
            String(r.sequence ?? '').includes(q)
        ) : all;
        page = 1;
        renderTable();
    });
}

function initPagination() {
    document.getElementById('lPrev')?.addEventListener('click', () => {
        if (page > 1) { page--; renderTable(); scrollUp(); }
    });
    document.getElementById('lNext')?.addEventListener('click', () => {
        if ((page * PER_PAGE) < filtered.length) { page++; renderTable(); scrollUp(); }
    });
}

function scrollUp() {
    document.querySelector('table')
        ?.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

initPagination();

if (window.__orp_config) load(window.__orp_config);
else {
    document.addEventListener('orp:config', e => load(e.detail));
    setTimeout(() => { if (!window.__orp_config) load(null); }, 3000);
}

})();
