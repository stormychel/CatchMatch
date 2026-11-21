# Safari extension

The Safari Web Extension for #84. It is the `CatchMatchExtension` target, embedded
in CatchMatch.app under `Contents/PlugIns`:

- `CatchMatchExtension/Resources/` holds the manifest, popup and background script.
- `CatchMatchExtension/SafariWebExtensionHandler.swift` is the principal class Safari
  requires. It does nothing, since the handoff below doesn't use native messaging.
- `CatchMatchExtension-Info.plist` and `CatchMatchExtension.entitlements` sit beside
  the app's own. The extension is sandboxed; the app isn't.

To try it: run the app once, then enable CatchMatch in Safari ▸ Settings ▸
Extensions. A development build may also need Develop ▸ **Allow Unsigned
Extensions**.

## How it talks to the app

Everything goes through the `catchmatch://` URL scheme the app now registers:

```
catchmatch://add?url=<encoded>&music=1&tv=0
```

`music` and `tv` are optional — omitted, the item inherits whatever the window's
chips are set to. Only `http` and `https` URLs are accepted, and a request queues
an item without starting it: any web page can navigate to a custom scheme, so the
handler will not read a local path or begin an import on its own.

The scheme was chosen over `sendNativeMessage` because it needs no app group, works
whether or not the app is running, and is useful on its own: a Shortcut, a script or
`open "catchmatch://add?url=…"` in a terminal all reach the queue the same way.

Its one cost is that the app comes to the front. If that turns out to be annoying in
daily use, the handoff can move to native messaging without changing the extension's
UI.
