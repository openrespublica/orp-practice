// ledger.js — TruthChain Public Ledger
'use strict';

(function () {

const PAGE = 20;
let allRecords = [];
let filtered   = [];
let page       = 1;

function esc(str) {
    const d = document.createElement('div');
    d.textContent = String(str ?? '');
    return d.innerHTML;
}

function getManifestUrl(config) {
    return config?.github?.manifest_url
        || 'https://openrespublica.github.io/orp-practice/docs/records/manifest.json';
}

async function loadLedger(config) {
    try {
        const res = await fetch(getManifestUrl(config) + '?t=' + Date.now(),
                                { signal: AbortSignal.timeout(20000) });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        allRecords = await res.json();
        filtered   = allRecords;
        page       = 1;
        renderTable();
        initSearch();
    } catch (err) {
        document.getElementById('ledgerBody').innerHTML =
            `<tr><td colspan="6" style="text-align:center;padding:3rem;color:#6B7280">
                Could not load ledger. Check your connection.<br>
                <small style="font-family:monospace">${esc(err.message)}</small>
            </td></tr>`;
    }
}

function renderTable() {
    const start = (page - 1) * PAGE;
    const end   = Math.min(start + PAGE, filtered.length);
    const rows  = filtered.slice(start, end);

    document.getElementById('ledgerBody').innerHTML = rows.length
        ? rows.map(r => `
            <tr>
                <td><span class="chain-seq-badge">#${esc(String(r.sequence ?? '—'))}</span></td>
                <td><span class="ctrl-no">${esc(r.control_number ?? '—')}</span></td>
                <td><span class="badge-type">${esc(r.document_type ?? 'GENERAL')}</span></td>
                <td class="ts-cell">${esc((r.timestamp ?? '').split(' ')[0])}</td>
                <td><span class="hash-short" title="${esc(r.sha256_hash ?? '')}">
                    ${esc((r.sha256_hash ?? '').slice(0,16))}…</span></td>
                <td style="text-align:center">
                    <a href="verify.html?hash=${encodeURIComponent(r.sha256_hash ?? '')}"
                       class="btn-verify-link">Verify</a>
                </td>
            </tr>`)
            .join('')
        : '<tr><td colspan="6" style="text-align:center;padding:2rem;color:#6B7280">No records found.</td></tr>';

    const count   = document.getElementById('ledgerCount');
    const info    = document.getElementById('pageInfo');
    const prevBtn = document.getElementById('lPrev');
    const nextBtn = document.getElementById('lNext');

    if (count) count.textContent = `${filtered.length} record${filtered.length !== 1 ? 's' : ''}`;
    if (info)  info.textContent  = filtered.length
        ? `Showing ${start + 1}–${end} of ${filtered.length}`
        : 'No results';
    if (prevBtn) prevBtn.disabled = page === 1;
    if (nextBtn) nextBtn.disabled = end >= filtered.length;
}

function initSearch() {
    const box = document.getElementById('searchBox');
    if (!box) return;
    box.addEventListener('input', () => {
        const q = box.value.trim().toLowerCase();
        filtered = q
            ? allRecords.filter(r =>
                (r.control_number ?? '').toLowerCase().includes(q) ||
                (r.document_type  ?? '').toLowerCase().includes(q) ||
                (r.sha256_hash    ?? '').toLowerCase().includes(q) ||
                (r.timestamp      ?? '').toLowerCase().includes(q))
            : allRecords;
        page = 1;
        renderTable();
    });
}

function initPagination() {
    document.getElementById('lPrev')?.addEventListener('click', () => {
        if (page > 1) { page--; renderTable();
            document.querySelector('table')?.scrollIntoView({ behavior: 'smooth' }); }
    });
    document.getElementById('lNext')?.addEventListener('click', () => {
        if ((page * PAGE) < filtered.length) { page++;  renderTable();
            document.querySelector('table')?.scrollIntoView({ behavior: 'smooth' }); }
    });
}

initPagination();

if (window.__orp_config) {
    loadLedger(window.__orp_config);
} else {
    document.addEventListener('orp:config', ({ detail }) => loadLedger(detail));
    setTimeout(() => { if (!window.__orp_config) loadLedger(null); }, 3000);
}

})();
