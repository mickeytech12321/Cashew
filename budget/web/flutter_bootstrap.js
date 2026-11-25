{{flutter_js}}
{{flutter_build_config}}

const loading = document.getElementById("loading");
function showRetry(error) {
  console.error("CashU could not start", error);
  const arabic = navigator.language.toLowerCase().startsWith("ar");
  const retry = document.createElement("button");
  retry.textContent = arabic ? "تعذّر فتح CashU. أعد المحاولة" : "CashU could not open. Retry";
  retry.addEventListener("click", () => location.reload());
  loading.replaceChildren(retry);
}

const startupTimeLimit = setTimeout(() => showRetry("Startup timed out"), 30000);
window.addEventListener("flutter-first-frame", () => {
  clearTimeout(startupTimeLimit);
  loading.remove();
}, { once: true });

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
    useColorEmoji: true,
  },
  onEntrypointLoaded: async (engineInitializer) => {
    try {
      const app = await engineInitializer.initializeEngine();
      await app.runApp();
    } catch (error) {
      clearTimeout(startupTimeLimit);
      showRetry(error);
    }
  },
}).catch((error) => {
  clearTimeout(startupTimeLimit);
  showRetry(error);
});
