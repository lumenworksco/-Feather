# Feather

A small, native macOS browser built on WebKit. Vertical sidebar tabs, a calm interface with considered motion, and a tab lifecycle that unloads pages you aren't using to keep memory in check. Swift, SwiftUI and `WKWebView`; no third-party dependencies, no accounts, no telemetry.

> **Status: early alpha.** One developer, one machine. It is usable for everyday browsing, but it is missing things you may rely on (see [What's not there yet](#whats-not-there-yet)) and the app is **not notarized**. Expect rough edges.

![Feather with pinned tabs and the sidebar](docs/screenshots/sidebar.png)

## Features

- **Sidebar tabs**, with **pinned tabs** as an icon grid at the top. Drag to reorder, drag onto the pin area to pin, drag back to unpin. Hide the sidebar with ⌘S for a compact top bar.
- **One address bar** for URLs and Google searches. It takes focus on every new tab.
- **Memory-conscious by design.** Blank and restored tabs have no web view at all; pages in tabs you haven't visited are unloaded according to a setting (Balanced / Memory Saver / Aggressive). A tab is never unloaded while it is loading, playing media, using the camera or microphone, on an excluded site, or has text typed into a form.
- **Crash-safe sessions.** Your tabs, pins, selection, and each tab's back/forward history and scroll position are saved within about a quarter of a second of any change and restored after a quit, crash or `kill -9`, with backups and safeguards against a damaged session file (see [Keeping your tabs safe](#keeping-your-tabs-safe)). Only the selected tab loads at launch. If WebKit's page process dies, the tab reloads itself.
- Bookmarks, local history, downloads, find in page, per-site zoom, printing, camera/microphone/location prompts, file upload, JavaScript dialogs, local HTML files.
- **USB security keys** (YubiKey and other FIDO2 keys) for sign-in and registration, including PIN entry (see [Security keys](#security-keys-yubikey-and-other-usb-fido2-keys)).
- **Updates inside the app**: Feather checks for a new version about once a day (switch off in Settings), shows a banner, and installs it with one click, then reopens with your tabs. Updates are signed by the project owner; see [Updates](#updates).
- **Default-browser support**: opens links from other apps.
- A start page with your bookmarks and recent sites, a lavender brand palette, and animations that only run in response to what you do (all disabled by macOS *Reduce motion*).

![The start page](docs/screenshots/start.png)

## Keeping your tabs safe
Your open tabs, pins, selection, each tab's back/forward list and scroll position, and the recently-closed list are saved within about a quarter of a second of any change, and whenever you leave the app, sleep the Mac, or quit.

- **Writes are durable.** Each save goes to a temporary file, is forced to disk, read back and compared, and only then renamed into place. The previous save is kept as `session.prev.json`.
- **Nothing unreadable is ever overwritten.** If the session file is damaged, Feather restores the previous save, then the newest backup, and first copies every damaged file into `SessionQuarantine/`. One damaged tab entry costs only that tab.
- **Rolling backups** live in `SessionBackups/`: every 10 minutes while things change, at launch, at quit, and *before* a sudden drop in the number of tabs, so a mistaken mass-close can be undone. **History > Restore Previous Session** opens a backup's tabs alongside the ones you have (nothing is replaced).
- **You are told** when something went wrong (a restore from backup, a damaged file, a save that failed and is being retried) in a banner over the window.
- **One Feather per profile.** A second copy opening the same profile can't write to it.

**Limits:** changes in the last fraction of a second before a crash, text typed into web forms, and a page's JavaScript state are not saved. Tested by killing the app (`kill -9`), quitting, damaging the files in every way listed in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md), and loading a copy of a real session. **Not tested:** a power cut or Mac restart in the middle of a save, which needs a real restart.

## Security keys (YubiKey and other USB FIDO2 keys)

Apple does not let third-party browsers use passkeys or security keys through `WKWebView` without a restricted entitlement that needs a paid Apple Developer account. Feather talks to USB keys itself (CTAP2 over USB HID, no third-party code) and answers a page's WebAuthn requests, so signing in and registering with a **USB security key works**, including PIN entry (PIN protocol v1).

* **Works (tested with a real key):** register and sign in with a USB FIDO2 key, with or without a PIN. The sheet always names the site that is asking.
* **Implemented, not yet tested:** several accounts on one key (discoverable credentials and the account picker), sites that use the older `appid` extension, the "this key isn't registered, plug in another" flow, and cancel/timeout paths.
* **Does not work:** iCloud Keychain passkeys and Touch ID (these need Apple's entitlement), NFC and Bluetooth keys, phones as authenticators, "autofill" passkey sign-in. Sites that only offer these show their own fallback.
* **Safety rules:** the site identity is checked against the page's real address (taken from WebKit, not from the page) and the Public Suffix List; only secure (https) pages; only the page in front can ask; no use from frames on other sites; wrong PINs are never retried automatically.
* **Tested:** a real YubiKey (firmware 5.7.4) registered and signed in on a local test page, results verified by Yubico's `python-fido2` (`tests/webauthn-test.py`, also with PIN). **Not tested:** other key models, key lockout, and sign-in on individual large sites; please report problems.

## Updates

Feather asks GitHub for the newest release about once a day (**Settings ▸ Updates** switches it off; **Feather ▸ Check for Updates…** checks now). Nothing is installed without your click.

* **Signed.** Each release carries a small manifest signed with a private key that only the project owner holds (Ed25519, kept in the owner's Keychain, never in the repository or in GitHub). Feather has the matching public key built in and ignores anything that does not verify, so a hacked GitHub account alone cannot push a malicious update. The manifest also pins the download's size and SHA-256, and updates that are not newer (downgrades, replays) are refused.
* **How it installs.** The sandboxed app downloads and checks the update, saves your tabs, then starts a small separate helper (`Contents/Library/FeatherUpdater.app`, not sandboxed) that repeats every check, swaps the app in place and starts the new version. If the new version does not start, the old one is put back; the old version goes to the Trash. Why a helper: everything a sandboxed app writes is marked "downloaded", so macOS would ask "Open Anyway" after every update.
* **Tested:** a full update of a copy of the app against a local test feed (swap, relaunch, tabs restored, no quarantine mark), and refusal of a wrongly signed release, a tampered download, and a tampered download handed straight to the helper (`tests/update-test.py`).
* **Not tested yet:** updating the real installed copy from a real GitHub release (the first real update happens when the next version after this one is published), and apps installed from a browser download (macOS may ask once about the helper). If an update ever fails, the banner offers the download page.
* Privacy: the check is a request to GitHub (your IP address and Feather's version are visible to GitHub), nothing else.

## What's not there yet

No password manager or AutoFill, no passkeys stored on the Mac (USB security keys work, see above), no extensions, no ad/tracker blocking, no private browsing, no download list (just a progress badge), no sync, one window only. Text typed into a web form and a page's JavaScript state are **not** restored after a crash. Sign-in flows for large sites (Google, Microsoft) inside `WKWebView` are not systematically tested.

## Memory: a goal, not a result

Feather is designed to be light, but **no measurements against Safari or any other browser have been recorded yet**, so it makes no claim to use less memory than they do. A benchmark harness is included ([BENCHMARKING.md](BENCHMARKING.md)); run it before trusting any comparison.

## Privacy

No analytics, accounts or telemetry. Tabs, history and bookmarks are stored locally in the app's sandbox container. Besides the pages you open, Feather makes two kinds of request of its own: it downloads the icon of sites you visit to show in the tab, and it asks GitHub for the newest release about once a day (Settings ▸ Updates switches this off). Icons are saved locally (about 1-4 KB each, at most 400 files, refreshed weekly) so tabs show them straight after a relaunch; Clear History removes them except for sites you still have open or bookmarked. The default search engine is Google, so searches typed in the address bar go to Google. The app runs in the macOS App Sandbox.

## Build and run

Requires macOS 14 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Feather.app
```

The app is signed ad hoc, not with a Developer ID, and is not notarized. If you copy it elsewhere and macOS refuses to open it, use *System Settings → Privacy & Security → Open Anyway*. To make it your default browser, use the button in Feather's Settings.

## Keyboard shortcuts

| | | | |
|---|---|---|---|
| New tab | ⌘T | Close tab | ⌘W |
| Reopen closed tab | ⇧⌘T | Open location | ⌘L |
| Back / Forward | ⌘[ / ⌘] | Reload | ⌘R |
| Next / previous tab | ⇧⌘] / ⇧⌘[ or ⌃⇥ / ⌃⇧⇥ | Go to tab 1–9 | ⌘1 … ⌘9 |
| Pin / unpin tab | ⇧⌘P | Hide / show sidebar | ⌘S |
| Bookmark page | ⌘D | Find in page | ⌘F, ⌘G, ⇧⌘G |
| Zoom in / out / reset | ⌘= (⌘+) / ⌘- / ⌘0 | Print | ⌘P |

## Development

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the architecture, launch arguments, and the automated tests (a lifecycle self-test, a kill-and-relaunch restore suite, a readiness suite, and a real-mouse drag-and-drop test).

## License

[MIT](LICENSE). Icon design: created for this project.

Third-party data: `Feather/Resources/public_suffix_list.txt` is the [Public Suffix List](https://publicsuffix.org/) (Mozilla Public License 2.0, https://mozilla.org/MPL/2.0/), used to check which site names a page may claim.
