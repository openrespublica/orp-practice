/**
 * config-loader.js — OpenResPublica TruthChain
 *
 * Loads config.json and populates the page via two safe mechanisms:
 *   1. [data-config="lgu.name"] attribute → sets textContent of that element
 *   2. document.title uses [data-title-suffix] to build a page title
 *
 * This avoids the innerHTML-replace pattern which can break event listeners
 * and cause security issues if config values ever contain HTML characters.
 */
(function () {
  // Walk a dot-path like "lgu.name" through a nested object.
  function resolvePath(obj, path) {
    return path.split('.').reduce((acc, key) => (acc != null ? acc[key] : undefined), obj);
  }

  async function loadConfig() {
    let config;
    try {
      // Path must work whether loaded from / or /docs/ on GitHub Pages.
      // Try a sibling config.json first (works when JS lives in assets/).
      const base = document.currentScript
        ? document.currentScript.src.replace(/assets\/config-loader\.js.*$/, '')
        : './';

      const url = base + 'config.json';
      const res = await fetch(url + '?t=' + Date.now());
      if (!res.ok) throw new Error('HTTP ' + res.status);
      config = await res.json();
    } catch (err) {
      console.warn('[config-loader] Could not load config.json:', err);
      return;
    }

    // ── 1. Populate all [data-config] elements ────────────────────────────
    document.querySelectorAll('[data-config]').forEach(el => {
      const path = el.getAttribute('data-config');
      const value = resolvePath(config, path);
      if (value != null) el.textContent = value;
    });

    // ── 2. Populate [data-config-href] for anchor hrefs ───────────────────
    document.querySelectorAll('[data-config-href]').forEach(el => {
      const path = el.getAttribute('data-config-href');
      const value = resolvePath(config, path);
      if (value != null) el.href = value;
    });

    // ── 3. Update <title> ─────────────────────────────────────────────────
    const titleEl = document.querySelector('title[data-config]');
    if (titleEl) {
      const path = titleEl.getAttribute('data-config');
      const value = resolvePath(config, path);
      if (value != null) titleEl.textContent = value;
    }

    // ── 4. Expose config globally for other scripts ───────────────────────
    window.__orp_config = config;

    // Fire a custom event so other scripts can react after config is ready.
    document.dispatchEvent(new CustomEvent('orp:config', { detail: config }));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', loadConfig);
  } else {
    loadConfig();
  }
})();
