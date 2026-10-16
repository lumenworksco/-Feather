# Changelog

## 0.1.2-alpha
- **USB security keys (YubiKey and other FIDO2 keys)** now work for sign-in and registration, including PIN entry. WebKit does not offer this to third-party browsers, so Feather talks to the key itself. Not supported: iCloud passkeys, Touch ID, NFC/Bluetooth keys (these need an Apple entitlement).
- Site icons are kept across relaunches (small local cache, refreshed weekly, cleared with Clear History).

## 0.1.1-alpha
- Fixed blurry Google Sheets and Docs (`window.outerWidth/outerHeight` was 0 in `WKWebView`).
- Background tabs now get a real viewport.

## 0.1.0-alpha
- First public alpha: sidebar and pinned tabs, memory-conscious tab lifecycle, crash-safe sessions, bookmarks, history, downloads, find, zoom, printing.
