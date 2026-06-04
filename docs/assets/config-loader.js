async function loadConfig() {
    try {
        // Try to fetch from 'config.json'. 
        // If your file is in a /docs folder, use 'docs/config.json'
        const response = await fetch('config.json'); 
        if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
        
        const config = await response.json();

        // Helper: gets the value from the config object
        const getValue = (path) => {
            return path.split('.').reduce((acc, part) => acc && acc[part], config);
        };

        // TreeWalker: Finds all text nodes containing {{...}} and replaces them safely
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
        let node;
        while(node = walker.nextNode()) {
            if (node.nodeValue.includes('{{')) {
                node.nodeValue = node.nodeValue.replace(/{{([\w.]+)}}/g, (match, path) => {
                    const val = getValue(path);
                    return val !== undefined ? val : match;
                });
            }
        }
        console.log("TruthChain: Config loaded successfully.");
    } catch (error) {
        console.error("TruthChain: Configuration failed to load.", error);
    }
}

document.addEventListener('DOMContentLoaded', loadConfig);
