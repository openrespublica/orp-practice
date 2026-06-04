// ledger.js — Public Audit Ledger Logic for records.html
// ─────────────────────────────────────────────────────────────────

let ledgerData   = [];
let filteredData = [];
let currentPage  = 1;
const PAGE_SIZE  = 15;

document.addEventListener('DOMContentLoaded', loadLedger);

/**
 * Strict structural context HTML escaping sanitizer
 * Prevents XSS attacks from rogue operators injecting HTML into document_type or control_number
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

async function loadLedger() {
    const tbody = document.getElementById('ledger-body');

    try {
        // Cache-buster so citizens always see the current ledger state.
        const response = await fetch(`records/manifest.json?t=${Date.now()}`);
        if (!response.ok) throw new Error('Manifest unavailable');

        // manifest.json is already newest-first — NO .reverse() here.
        // main.py uses records.insert(0, record), so index 0 = most recent.
        ledgerData   = await response.json();
        filteredData = ledgerData;

        // ── Stats ─────────────────────────────────────────────────
        const statTotal  = document.getElementById('statTotal');
        const statLatest = document.getElementById('statLatest');
        const statYear   = document.getElementById('statYear');

        if (statTotal)  statTotal.textContent  = ledgerData.length;

        if (statLatest && ledgerData.length > 0) {
            // ledgerData[0] is the NEWEST record
            const ts = (ledgerData[0] && ledgerData[0].timestamp) || '';
            statLatest.textContent = ts ? ts.split(' ')[0] : '—';
        }

        // Auto-update the ledger year from the current date
        if (statYear) statYear.textContent = new Date().getFullYear();

        renderPage();

    } catch {
        if (tbody) {
            tbody.innerHTML =
                '<tr><td colspan="5"><div class="table-msg">' +
                'No records found in the public ledger yet.' +
                '</div></td></tr>';
        }
        const countEl = document.getElementById('recordCount');
        if (countEl) countEl.textContent = '0 records';

        const prevBtn = document.getElementById('prevBtn');
        const nextBtn = document.getElementById('nextBtn');
        if (prevBtn) prevBtn.disabled = true;
        if (nextBtn) nextBtn.disabled = true;
    }
}

function renderPage() {
    const tbody = document.getElementById('ledger-body');
    if (!tbody) return;

    const total = filteredData.length;
    const start = (currentPage - 1) * PAGE_SIZE;
    const end   = Math.min(start + PAGE_SIZE, total);
    const slice = filteredData.slice(start, end);

    if (slice.length === 0) {
        tbody.innerHTML =
            '<tr><td colspan="5"><div class="table-msg">' +
            'No matching records found.' +
            '</div></td></tr>';
        const countEl = document.getElementById('recordCount');
        if (countEl) countEl.textContent = '0 records';
        const prevBtn = document.getElementById('prevBtn');
        const nextBtn = document.getElementById('nextBtn');
        if (prevBtn) prevBtn.disabled = true;
        if (nextBtn) nextBtn.disabled = true;
        return;
    }

    // Null-safe template literals WITH strict HTML escaping
    tbody.innerHTML = slice.map(item => `
        <tr>
            <td><span class="ctrl-num">${escapeHtml(item.control_number) || '—'}</span></td>
            <td><span class="date-cell">${escapeHtml(formatDate(item.timestamp))}</span></td>
            <td><span class="badge-type">${escapeHtml(item.document_type) || 'GENERAL'}</span></td>
            <td><span class="hash-cell">${escapeHtml(item.sha256_hash || '').substring(0, 16)}…</span></td>
            <td class="action-cell">
                <a href="verify.html?hash=${encodeURIComponent(item.sha256_hash || '')}" class="verify-link">Verify</a>
            </td>
        </tr>
    `).join('');

    const countEl = document.getElementById('recordCount');
    if (countEl) {
        countEl.textContent =
            `Showing ${start + 1}–${end} of ${total} record${total !== 1 ? 's' : ''}`;
    }

    const prevBtn = document.getElementById('prevBtn');
    const nextBtn = document.getElementById('nextBtn');
    if (prevBtn) prevBtn.disabled = currentPage === 1;
    if (nextBtn) nextBtn.disabled = end >= total;
}

function changePage(dir) {
    const maxPage = Math.ceil(filteredData.length / PAGE_SIZE);
    currentPage   = Math.max(1, Math.min(currentPage + dir, maxPage));
    renderPage();
    window.scrollTo({ top: 0, behavior: 'smooth' });
}

function searchLedger() {
    const term = (document.getElementById('search')?.value || '').toLowerCase().trim();
    filteredData = term
        ? ledgerData.filter(item =>
            (item.control_number || '').toLowerCase().includes(term) ||
            (item.document_type  || '').toLowerCase().includes(term)
          )
        : ledgerData;
    currentPage = 1;
    renderPage();
}

function formatDate(ts) {
    if (!ts) return '—';
    return ts.split(' ')[0] || '—';
}
