// /assets/config-loader.js
async function loadConfig() {
    try {
        const response = await fetch('/assets/config.json');
        const config = await response.json();

        // Helper to get nested values (e.g., "lgu.name" -> config.lgu.name)
        const getNestedValue = (obj, path) => {
            return path.split('.').reduce((acc, part) => acc && acc[part], obj);
        };

        // Replace all {{key.path}} patterns in the entire document body
        document.body.innerHTML = document.body.innerHTML.replace(/{{([\w.]+)}}/g, (match, path) => {
            const value = getNestedValue(config, path);
            return value !== undefined ? value : match;
        });
    } catch (error) {
        console.error("Failed to load configuration:", error);
    }
}

document.addEventListener('DOMContentLoaded', loadConfig);
