async function loadConfig() {
  try {
    const response = await fetch('./config.json'); // explicit relative path
    const metadata = await response.json();

    document.body.innerHTML = document.body.innerHTML.replace(/{{(.*?)}}/g, (_, path) => {
      return path.split('.').reduce((acc, key) => acc?.[key], metadata) || '';
    });
  } catch (err) {
    console.error("Failed to load config.json:", err);
  }
}

document.addEventListener("DOMContentLoaded", loadConfig);
