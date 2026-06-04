// assets/config-loader.js
async function loadConfig() {
    try {
        // Fetching from the specified path
        const response = await fetch('docs/config.json');
        if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
        
        const config = await response.json();

        // Helper to get nested values (e.g., "lgu.name" -> config.lgu.name)
        const getNestedValue = (obj, path) => {
            return path.split('.').reduce((acc, part) => acc && acc[part], obj);
        };

        // Replace all {{key.path}} patterns in the document body
        document.body.innerHTML = document.body.innerHTML.replace(/{{([\w.]+)}}/g, (match, path) => {
            const value = getNestedValue(config, path);
            return value !== undefined ? value : match;
        });
    } catch (error) {
        console.error("Failed to load configuration:", error);
    }
}

document.addEventListener('DOMContentLoaded', loadConfig);
