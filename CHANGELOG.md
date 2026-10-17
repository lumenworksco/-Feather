# Changelog

## 0.1.3-alpha
- **Updates inside the app.** Feather checks GitHub for a newer release about once a day (switch off in Settings), shows a banner, and installs it with one click: it saves your tabs, swaps itself, and reopens. Updates are signed by the project owner and checked for size and SHA-256; downgrades are refused. This is the first version with the updater, so it has to be installed by hand once; later versions can update themselves.

## 0.1.2-alpha
- **USB security keys (YubiKey and other FIDO2 keys)** now work for sign-in and registration, including PIN entry. WebKit does not offer this to third-party browsers, so Feather talks to the key itself. Not supported: iCloud passkeys, Touch ID, NFC/Bluetooth keys (these need an Apple entitlement).
- Site icons are kept across relaunches (small local cache, refreshed weekly, cleared with Clear History).

## 0.1.1-alpha
- Fixed blurry Google Sheets and Docs (`window.outerWidth/outerHeight` was 0 in `WKWebView`).
- Background tabs now get a real viewport.

## 0.1.0-alpha
- First public alpha: sidebar and pinned tabs, memory-conscious tab lifecycle, crash-safe sessions, bookmarks, history, downloads, find, zoom, printing.
