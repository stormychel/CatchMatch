// Everything goes to the extension's native handler, which opens the
// catchmatch:// link the app registers. Safari won't open a custom scheme from
// an extension's script, so this can't do it directly (#84).

function sendToCatchMatch(url, options = {}) {
  if (!url) return Promise.resolve(false);
  return browser.runtime.sendNativeMessage("com.michelstorms.dlp2music", { url, ...options });
}

browser.runtime.onInstalled.addListener(() => {
  browser.contextMenus.create({
    id: "send-link",
    title: "Send to CatchMatch",
    contexts: ["link", "video"],
  });
});

browser.contextMenus.onClicked.addListener((info) => {
  sendToCatchMatch(info.linkUrl || info.srcUrl);
});

// Returning the promise keeps the popup's sendMessage open until the page has
// been handed over.
browser.runtime.onMessage.addListener((message) => {
  if (message?.type === "send") {
    return sendToCatchMatch(message.url, message.options);
  }
});
