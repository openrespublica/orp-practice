/**
 * config-loader.js — Loads docs/config.json and exposes ORP_CONFIG
 * Include on every docs/*.html page to display consistent branding
 * Usage: <script src="assets/config-loader.js"></script>
 */

(function (global) {
  const ORP = {
    config: null,
    async load() {
      if (this.config) return this.config;
      try {
        const r = await fetch('config.json?t=' + Date.now(), {cache: 'no-store'});
        if (!r.ok) throw new Error('Failed to load config.json');
        this.config = await r.json();
        this.applyToDOM();
        return this.config;
      } catch (err) {
        console.error('ORP config load error:', err);
        return null;
      }
    },
    applyToDOM() {
      if (!this.config) return;
      const nameEl = document.querySelector('[data-orp-lgu-name]');
      if (nameEl) nameEl.textContent = this.config.LGU_NAME || '';
      const signerEl = document.querySelector('[data-orp-signer-name]');
      if (signerEl) signerEl.textContent = this.config.SIGNER_NAME || '';
      const footerEls = document.querySelectorAll('[data-orp-portal-url]');
      footerEls.forEach(el => el.textContent = this.config.GITHUB_PORTAL_URL || '');
    },
    get(key, fallback = '') {
      return (this.config && this.config[key]) || fallback;
    }
  };

  global.ORP = ORP;
  document.addEventListener('DOMContentLoaded', () => ORP.load());
})(window);
