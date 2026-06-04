(function (global) {
    'use strict';

    /**
     * Updated resolveConfigUrl:
     * Since your site is hosted at /orp-practice/ and GitHub Pages treats 
     * /docs as the root, this path will correctly point to the config 
     * file regardless of which sub-page calls it.
     */
    function resolveConfigUrl() {
        return '/orp-practice/config.json';
    }

    const CACHE_WINDOW_MS = 5 * 60 * 1000;
    function cacheBuster() {
        return Math.floor(Date.now() / CACHE_WINDOW_MS);
    }

    const ORP = {
        config: null,

        async load() {
            if (this.config) return this.config;

            const url = resolveConfigUrl() + '?v=' + cacheBuster();

            try {
                const response = await fetch(url);
                if (!response.ok) {
                    throw new Error(`Config HTTP ${response.status} at ${url}`);
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

        get(path, fallback) {
            if (fallback === undefined) fallback = '';
            if (!this.config) return fallback;
            return path.split('.').reduce((obj, key) => (obj && obj[key] !== undefined) ? obj[key] : undefined, this.config) || fallback;
        },

        _applyToDOM() {
            if (!this.config) return;

            const bindings = {
                '[data-orp-lgu-name]': this.get('lgu.name'),
                '[data-orp-signer-name]': this.get('lgu.signer_name'),
                '[data-orp-signer-position]': this.get('lgu.signer_position'),
                '[data-orp-portal-url]': this.get('github.portal_url'),
                '[data-orp-portal-title]': this.get('portal.title'),
            };

            Object.entries(bindings).forEach(([selector, value]) => {
                document.querySelectorAll(selector).forEach(el => {
                    if (el.tagName === 'A' && selector.includes('url')) {
                        el.href = value;
                        if (!el.textContent.trim()) el.textContent = value;
                    } else {
                        el.textContent = value;
                    }
                    el.removeAttribute('data-orp-loading');
                });
            });

            document.dispatchEvent(new CustomEvent('orp:config-ready', { detail: this.config }));
        },

        _applyFallback() {
            document.querySelectorAll('[data-orp-loading]').forEach(el => {
                el.textContent = 'Data Unavailable';
            });
        }
    };

    document.addEventListener('DOMContentLoaded', () => {
        // Initial setup for UI placeholders
        document.querySelectorAll('[data-orp-lgu-name], [data-orp-signer-name]').forEach(el => {
            el.setAttribute('data-orp-loading', '');
        });
        ORP.load();
    });

    global.ORP = ORP;
})(window);
