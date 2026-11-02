# Changelog

## 0.1.6-alpha (not released yet)
- **Tab groups.** Right-click a tab > Add to Group > New Group (or Navigate > Add Tab to New Group). Groups have a name and a color, sit together in the sidebar, fold away by clicking their header, and are saved with your session. Drop a tab on a header to add it; links opened from a grouped tab stay in the group; pinning a tab takes it out. Not yet: dragging a whole group, or putting a tab before a group that is first in the list by dragging.
- Fixed: a tab that was playing audio kept playing for a while after it was closed (or unloaded). Media is now paused and the page emptied before the web view is released.
- Security keys: every refused request, and every key plugged in or removed, is now written to the system log (Console, subsystem `dev.feather`, category `webauthn`), so a failed sign-in can be traced.

## 0.1.5-alpha
- The start page now shows up to **20** bookmarks (it showed 12), in rows of five, and scrolls when the window is too short to show them all. The Bookmarks menu always listed every bookmark.

## 0.1.4-alpha
- The automatic update check no longer depends on a timer alone (macOS slows timers of background apps): it also runs when you switch back to Feather, and logs why a check ran or was skipped. This is the first version that can be reached by a real automatic update from 0.1.3.

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
