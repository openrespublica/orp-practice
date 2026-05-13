/**
 * config-loader.js — ORP Engine Portal Configuration Loader
 * ─────────────────────────────────────────────────────────────────
 * Loads docs/config.json and exposes window.ORP for use by all
 * docs/*.html and docs/records/*.html pages.
 *
 * Canonical config.json schema (written by master-bootstrap.sh):
 * {
 *   "lgu": {
 *     "name": "Barangay Buñao",
 *     "signer_name": "HON. JUAN DELA CRUZ",
 *     "signer_position": "Punong Barangay",
 *     "timezone": "Asia/Manila"
 *   },
 *   "portal": {
 *     "title": "TruthChain Verification",
 *     "subtitle": "..."
 *   },
 *   "github": {
 *     "owner": "openrespublica-ph",
 *     "repo": "truthchain-ledger",
 *     "portal_url": "https://..."
 *   },
 *   "generated": "2026-01-01T00:00:00Z",
 *   "version": "1.0.0"
 * }
 *
 * DOM data attributes:
 *   data-orp-lgu-name          → lgu.name
 *   data-orp-signer-name       → lgu.signer_name
 *   data-orp-signer-position   → lgu.signer_position
 *   data-orp-portal-url        → github.portal_url
 *   data-orp-portal-title      → portal.title
 *
 * Usage:
 *   <script src="assets/config-loader.js"></script>
 *   <span data-orp-lgu-name></span>
 *
 * Include this script in docs/*.html and docs/records/*.html pages.
 * Path resolution is script-relative, so it works from any depth.
 * ─────────────────────────────────────────────────────────────────
 */

(function (global) {
    'use strict';

    // ── Path resolution ──────────────────────────────────────────
    // Resolve config.json relative to THIS script file, not the
    // page that includes it. This ensures pages at any directory
    // depth (docs/index.html, docs/records/verify.html, etc.) all
    // resolve to the same docs/config.json.
    //
    // document.currentScript is the <script> element being executed
    // right now. Its .src is the absolute URL of this file.
    // We strip "/assets/config-loader.js" to get the docs/ base.
    function resolveConfigUrl() {
        const scriptSrc = (document.currentScript && document.currentScript.src) || '';
        if (scriptSrc) {
            // Strip "/assets/config-loader.js" to get the docs base URL
            const assetsDir = scriptSrc.substring(0, scriptSrc.lastIndexOf('/'));
            const docsBase  = assetsDir.substring(0, assetsDir.lastIndexOf('/assets'));
            return docsBase + '/config.json';
        }
        // Fallback: assume page is in docs/ (works for direct includes)
        return 'config.json';
    }

    // Cache-bust with 5-minute resolution.
    // Daily deployments don't need per-request busting; 5 minutes
    // balances freshness after a deployment with CDN efficiency.
    const CACHE_WINDOW_MS = 5 * 60 * 1000;
    function cacheBuster() {
        return Math.floor(Date.now() / CACHE_WINDOW_MS);
    }

    // ── ORP namespace ────────────────────────────────────────────
    const ORP = {
        config: null,

        /**
         * Load config.json. Returns a Promise<config|null>.
         * Cached after first successful load — safe to call repeatedly.
         */
        async load() {
            if (this.config) return this.config;

            const url = resolveConfigUrl() + '?v=' + cacheBuster();

            try {
                const response = await fetch(url, { cache: 'no-store' });
                if (!response.ok) {
                    throw new Error('HTTP ' + response.status + ' loading ' + url);
                }
                this.config = await response.json();
                this._applyToDOM();
                return this.config;
            } catch (err) {
                console.error('[ORP] Config load failed:', err.message);
                this._applyFallback();
                return null;
            }
        },

        /**
         * Read a nested value by dot-path.
         * e.g. ORP.get('lgu.name', 'Unknown LGU')
         */
        get(path, fallback) {
            if (fallback === undefined) fallback = '';
            if (!this.config) return fallback;
            return path.split('.').reduce(function (obj, key) {
                return (obj && obj[key] !== undefined) ? obj[key] : undefined;
            }, this.config) || fallback;
        },

        // ── DOM application ──────────────────────────────────────
        _applyToDOM() {
            if (!this.config) return;

            const bindings = {
                '[data-orp-lgu-name]':        this.get('lgu.name'),
                '[data-orp-signer-name]':      this.get('lgu.signer_name'),
                '[data-orp-signer-position]':  this.get('lgu.signer_position'),
                '[data-orp-portal-url]':       this.get('github.portal_url'),
                '[data-orp-portal-title]':     this.get('portal.title'),
            };

            Object.entries(bindings).forEach(function ([selector, value]) {
                document.querySelectorAll(selector).forEach(function (el) {
                    // If the element is a link, set href; otherwise set text.
                    if (el.tagName === 'A' && selector.includes('url')) {
                        el.href = value;
                        if (!el.textContent.trim()) el.textContent = value;
                    } else {
                        el.textContent = value;
                    }
                    // Mark as loaded for CSS targeting
                    el.removeAttribute('data-orp-loading');
                });
            });

            // Dispatch event so page scripts can react to config being ready.
            document.dispatchEvent(new CustomEvent('orp:config-ready', {
                detail: this.config
            }));
        },

        // Apply minimal fallback markers when config is unavailable.
        // This prevents completely blank UI for public visitors — the
        // page still renders; only LGU-specific text is missing.
        _applyFallback() {
            document.querySelectorAll('[data-orp-loading]').forEach(function (el) {
                el.textContent = '—';
                el.setAttribute('title', 'Configuration unavailable');
            });
        }
    };

    // ── Auto-load on DOMContentLoaded ────────────────────────────
    // Mark all data-orp-* elements as loading before the fetch so
    // CSS can show a placeholder state (e.g. skeleton shimmer).
    // This prevents the flash of empty content.
    document.addEventListener('DOMContentLoaded', function () {
        const orpSelectors = [
            '[data-orp-lgu-name]',
            '[data-orp-signer-name]',
            '[data-orp-signer-position]',
            '[data-orp-portal-url]',
            '[data-orp-portal-title]',
        ];
        orpSelectors.forEach(function (selector) {
            document.querySelectorAll(selector).forEach(function (el) {
                if (!el.textContent.trim()) {
                    el.setAttribute('data-orp-loading', '');
                    el.textContent = '\u00A0'; // non-breaking space preserves layout
                }
            });
        });

        ORP.load();
    });

    // ── Expose globally ───────────────────────────────────────────
    global.ORP = ORP;

})(window);
