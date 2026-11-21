const destinations = ["music", "tv", "downloads", "downloadsAudio"];

// The popup remembers what was ticked last time; until then it opens on
// Apple Music alone, as popup.html has it (#84).
// Send stays disabled until they're restored, so a late restore can't undo a
// box ticked in the meantime.
browser.storage.local.get("destinations").then(({ destinations: saved }) => {
  for (const id of destinations) {
    if (typeof saved?.[id] === "boolean") document.getElementById(id).checked = saved[id];
  }
}).finally(() => {
  document.getElementById("send").disabled = false;
});

document.getElementById("send").addEventListener("click", async () => {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  const options = Object.fromEntries(destinations.map((id) => [id, document.getElementById(id).checked]));
  await browser.storage.local.set({ destinations: options });
  // Awaited: closing the popup straight away could drop the message before the
  // background script received it (#84).
  await browser.runtime.sendMessage({ type: "send", url: tab?.url, options });
  window.close();
});
