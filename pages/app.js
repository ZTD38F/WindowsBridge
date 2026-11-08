"use strict";
(() => {
  const command = document.getElementById("install-command");
  const status = document.getElementById("copy-status");
  const controls = [...document.querySelectorAll("[data-copy-command]")];
  if (!command || !status || controls.length === 0) return;
  let timer;
  const notify = (message, ok) => {
    status.hidden = false;
    status.textContent = message;
    status.dataset.result = ok ? "success" : "error";
    clearTimeout(timer);
    timer = setTimeout(() => { status.hidden = true; }, 3200);
  };
  const legacyCopy = text => {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.append(area);
    area.select();
    let copied = false;
    try { copied = document.execCommand("copy"); } finally { area.remove(); }
    return copied;
  };
  const copy = async () => {
    const value = command.textContent.trim();
    if (!value) return notify("Команда недоступна", false);
    let copied = false;
    try {
      if (navigator.clipboard?.writeText && window.isSecureContext) {
        await navigator.clipboard.writeText(value);
        copied = true;
      }
    } catch { /* Clipboard permission denied: try local selection fallback. */ }
    if (!copied) copied = legacyCopy(value);
    if (!copied) {
      command.focus?.();
      notify("Выдели команду и скопируй вручную", false);
      return;
    }
    notify("Команда скопирована · Win + R → Ctrl + V → Enter", true);
    const label = document.querySelector(".copy-label");
    if (label) {
      label.textContent = "Скопировано";
      setTimeout(() => { label.textContent = "Скопировать команду"; }, 3200);
    }
  };
  for (const button of controls) button.addEventListener("click", copy);
})();