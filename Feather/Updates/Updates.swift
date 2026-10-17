import Foundation
import AppKit
import CryptoKit
import os

/// Finds, downloads and installs new versions of Feather.
///
/// The app only *prepares* an update: it finds the newest release, checks the owner's signature on it, downloads the zip and
/// checks its size and SHA-256. Installing (replacing the app and relaunching) is done by the separate helper in
/// Contents/Library, because a sandboxed app cannot replace itself without macOS treating the result as a fresh download.
/// Nothing is ever installed without a click, and the helper repeats every check on its own.
@MainActor
final class Updates: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading(UpdateManifest, Double)
        case ready(UpdateManifest)
        case installing(UpdateManifest)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The outcome of the last install, shown once at the next launch.
    @Published private(set) var notice: UpdateStatus?
    @Published private(set) var lastChecked: Date?

    weak var store: TabStore?
    static let releasesPage = URL(string: "https://github.com/lumenworksco/Feather/releases/latest")!
    /// The numeric id survives a rename of the repository.
    static let defaultFeed = URL(string: "https://api.github.com/repositories/1413668976/releases/latest")!

    private static let log = Logger(subsystem: "dev.feather", category: "updates")
    private let feed: URL
    private let current: (version: String, build: Int)
    private let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
    private var exchange: URL { UpdateTrust.exchangeDirectory(home: home) }
    private var pending: (manifest: UpdateManifest, zipURL: URL, manifestData: Data, signature: Data)?
    private var autoTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var lastAttempt = Date.distantPast
    private var dismissedVersion: String?

    init(store: TabStore?) {
        self.store = store
        let info = Bundle.main.infoDictionary
        current = (info?["CFBundleShortVersionString"] as? String ?? "0", Int(info?["CFBundleVersion"] as? String ?? "") ?? 0)
        // `--update-feed=URL` (tests): another place to look for releases. Releases are checked against the build's signing key
        // either way, so a different feed cannot make Feather install anything the owner did not sign.
        let override = CommandLine.arguments.first { $0.hasPrefix("--update-feed=") }.flatMap { URL(string: String($0.dropFirst(14))) }
        feed = override.flatMap { Self.isAcceptable($0, allowLocal: true) ? $0 : nil } ?? Self.defaultFeed
        loadNotice()
    }

    /// Only https; plain http is accepted for this machine only (tests).
    static func isAcceptable(_ url: URL, allowLocal: Bool) -> Bool {
        if url.scheme == "https" { return true }
        return allowLocal && url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")
    }

    var currentVersion: String { current.version }
    var canVerify: Bool { UpdateTrust.configuredKey() != nil }

    // MARK: Automatic checks

    /// Looks shortly after launch, whenever you come back to Feather, and about once a day. Never installs anything by itself.
    /// Timers alone are not enough: macOS slows an app's timers right down while it is in the background, so the check also
    /// runs when the app becomes active.
    func startAutomaticChecks() {
        let isTest = Storage.isFresh || Storage.profile != nil
        let hasTestFeed = CommandLine.arguments.contains { $0.hasPrefix("--update-feed=") }
        guard !isTest || hasTestFeed else { return }
        autoTask?.cancel()
        let first = hasTestFeed ? 3.0 : 20.0
        Self.log.notice("automatic update checks on: first in \(Int(first)) s, then when Feather is brought to the front and about daily")
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(first))
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkIfDue(reason: "timer")
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue(reason: "app became active") }
        }
    }

    /// Asks only if the setting is on, the last successful check is old enough, and no attempt was made in the last 10 minutes
    /// (so being offline, or switching apps often, never turns into a stream of requests).
    private func checkIfDue(reason: String) async {
        let hasTestFeed = CommandLine.arguments.contains { $0.hasPrefix("--update-feed=") }
        guard store?.settings.autoUpdateCheck ?? true else { Self.log.notice("check skipped (\(reason, privacy: .public)): switched off in Settings"); return }
        let sinceSuccess = Date().timeIntervalSince(store?.settings.lastUpdateCheck ?? .distantPast)
        guard hasTestFeed || sinceSuccess > 20 * 3600 else { Self.log.notice("check skipped (\(reason, privacy: .public)): last successful check was \(Int(sinceSuccess / 60)) min ago"); return }
        guard Date().timeIntervalSince(lastAttempt) > (hasTestFeed ? 0 : 600) else { return }
        lastAttempt = Date()
        Self.log.notice("automatic check (\(reason, privacy: .public))")
        await check(userInitiated: false)
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        switch state { case .checking, .downloading, .installing: return; default: break }
        guard let key = UpdateTrust.configuredKey() else {
            if userInitiated { state = .failed("This build of Feather has no update key, so it cannot check for updates.") }
            return
        }
        state = .checking
        Self.log.notice("checking \(self.feed.absoluteString, privacy: .public) (installed \(self.current.version, privacy: .public) build \(self.current.build))")
        do {
            var request = URLRequest(url: feed, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Feather/\(current.version)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { throw URLError(.badServerResponse) }
            let allowLocal = feed.host == "127.0.0.1" || feed.host == "localhost"
            var assets: [String: URL] = [:]
            for case let a as [String: Any] in (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["assets"] as? [Any] ?? [] {
                if let name = a["name"] as? String, let s = a["browser_download_url"] as? String, let u = URL(string: s), Self.isAcceptable(u, allowLocal: allowLocal) { assets[name] = u }
            }
            lastChecked = Date(); store?.settings.lastUpdateCheck = lastChecked
            // A release without a signed manifest (such as every release before the updater existed) simply offers nothing.
            guard let mURL = assets["update.json"], let sURL = assets["update.json.sig"] else { state = .upToDate; return }
            let manifestData = try await fetch(mURL, limit: 65_536), signature = try await fetch(sURL, limit: 1_024)
            guard let manifest = UpdateTrust.verify(manifest: manifestData, signatureText: signature, key: key) else {
                Self.log.error("latest release has an invalid signature or manifest; ignored")
                state = userInitiated ? .failed("The newest release isn't signed correctly, so Feather ignored it.") : .upToDate
                return
            }
            guard UpdateTrust.isNewer(manifest, thanVersion: current.version, build: current.build) else {
                Self.log.notice("latest release \(manifest.version, privacy: .public) build \(manifest.build) is signed and not newer than the installed one")
                state = .upToDate
                return
            }
            guard let zipURL = assets[manifest.asset] else { throw URLError(.fileDoesNotExist) }
            Self.log.notice("release \(manifest.version, privacy: .public) build \(manifest.build) is signed and newer")
            pending = (manifest, zipURL, manifestData, signature)
            if dismissedVersion == manifest.version && !userInitiated { state = .idle } else { state = .available(manifest) }
            // Test hook: install without clicking, but only from a feed on this machine (the signature is still checked).
            if allowLocal, CommandLine.arguments.contains("--update-auto-install"), case .available = state {
                Task { await download(); install(confirm: false) }
            }
        } catch {
            Self.log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            state = userInitiated ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
        }
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Feather/\(current.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= limit else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: Downloading

    func download() async {
        guard case .available(let m) = state, let p = pending, p.manifest == m else { return }
        state = .downloading(m, 0)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: exchange, withIntermediateDirectories: true)
            cleanExchange()
            let dest = exchange.appendingPathComponent(m.asset)
            var request = URLRequest(url: p.zipURL, timeoutInterval: 60)
            request.setValue("Feather/\(current.version)", forHTTPHeaderField: "User-Agent")
            let downloader = FileDownloader(destination: dest, limit: Int64(m.size)) { [weak self] written in
                let f = min(1, Double(written) / Double(m.size))
                DispatchQueue.main.async { if case .downloading = self?.state { self?.state = .downloading(m, f) } }
            }
            try await downloader.run(request)
            let total = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -1
            let digest = try UpdateTrust.sha256Hex(of: dest)
            guard total == m.size, digest == m.sha256 else {
                Self.log.error("download rejected: size \(total) / checksum does not match the signed manifest")
                try? fm.removeItem(at: dest)
                throw UpdateError("The download was damaged (it doesn't match the signed checksum).")
            }
            try p.manifestData.write(to: exchange.appendingPathComponent("update.json"))
            try p.signature.write(to: exchange.appendingPathComponent("update.json.sig"))
            state = .ready(m)
        } catch {
            Self.log.error("update download failed: \(error.localizedDescription, privacy: .public)")
            cleanExchange()
            state = .failed((error as? UpdateError)?.message ?? "The download failed: \(error.localizedDescription)")
        }
    }

    // MARK: Installing

    /// Why an install must wait, if it must.
    func blocker() -> String? {
        guard let store else { return nil }
        if store.webauthn.prompt != nil { return "Finish the security-key request first." }
        if case .running? = store.downloads.latest?.state { return "A download is still running." }
        if store.tabs.contains(where: { ($0.webView?.cameraCaptureState ?? .none) != .none || ($0.webView?.microphoneCaptureState ?? .none) != .none }) { return "A tab is using your camera or microphone." }
        return nil
    }

    /// Asks, then hands over to the helper and quits. Returns false if the user said no or something stands in the way.
    @discardableResult
    func install(confirm: Bool = true) -> Bool {
        guard case .ready(let m) = state else { return false }
        if let why = blocker() { state = .failed(why + " Then try again."); return false }
        if confirm {
            let alert = NSAlert()
            alert.messageText = "Install Feather \(m.version) and restart?"
            alert.informativeText = "Feather will quit, update itself and reopen with your tabs. Text you have typed into a web page but not sent is not kept."
            alert.addButton(withTitle: "Install and Restart"); alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/FeatherUpdater.app")
        guard FileManager.default.fileExists(atPath: helper.path) else { state = .failed("The installer is missing from this copy of Feather."); return false }
        // A test copy must come back as a test copy, not as your real profile.
        let args = CommandLine.arguments.filter { UpdateRequest.allowedArgumentPrefixes.contains(where: $0.hasPrefix) }
        let request = UpdateRequest(manifest: "update.json", signature: "update.json.sig", zip: m.asset, target: Bundle.main.bundleURL.path,
                                    pid: ProcessInfo.processInfo.processIdentifier, relaunchArguments: args)
        do { try JSONEncoder().encode(request).write(to: exchange.appendingPathComponent("update-request.json")) }
        catch { state = .failed("Couldn't prepare the update: \(error.localizedDescription)"); return false }
        state = .installing(m)
        Self.log.notice("handing over to the installer; quitting")
        store?.flushAll()                                     // your tabs are on disk before anything else happens
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        var handedOver = false
        func quit() { guard !handedOver else { return }; handedOver = true; NSApp.terminate(nil) }       // the helper waits for this process to end, then swaps the app
        NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { handedOver = true; self?.state = .failed("Couldn't start the installer: \(error.localizedDescription)"); return }
                quit()
            }
        }
        // Safety net: if Launch Services is slow to report, quit anyway once the helper is visibly running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.feather.Feather.Updater").isEmpty { quit() }
        }
        return true
    }

    /// For the menu command: say so when there is nothing new (a new version shows in the banner instead).
    func reportCheckResultInAlert() {
        let alert = NSAlert()
        switch state {
        case .upToDate: alert.messageText = "Feather is up to date"; alert.informativeText = "You have the newest version (\(current.version))."
        case .failed(let message): alert.messageText = "Couldn't check for updates"; alert.informativeText = message; resetFailure()
        default: return
        }
        alert.addButton(withTitle: "OK"); alert.runModal()
    }

    func dismiss() {
        if case .available(let m) = state { dismissedVersion = m.version }
        if case .failed = state { state = .idle } else if case .available = state { state = .idle }
    }
    func dismissNotice() { notice = nil }
    func resetFailure() { if case .failed = state { state = .idle } }

    // MARK: Housekeeping

    private func cleanExchange() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: exchange.path)) ?? [] where name != "updater.log" {
            try? fm.removeItem(at: exchange.appendingPathComponent(name))
        }
    }

    /// The helper leaves its verdict in a file; show it once, then forget it.
    private func loadNotice() {
        let url = exchange.appendingPathComponent("update-status.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let status = try? decoder.decode(UpdateStatus.self, from: data), abs(status.time.timeIntervalSinceNow) < 3600 { notice = status }
        try? FileManager.default.removeItem(at: url)
    }
}

struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

/// Downloads one file to a destination with progress, never holding more than a chunk in memory, and stops if it grows past `limit`.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL, limit: Int64, progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?

    init(destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination; self.limit = limit; self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
            session = s
            s.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit { downloadTask.cancel(); finish(.failure(URLError(.dataLengthExceedsMaximum))); return }
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { finish(.failure(error)) } }

    private func finish(_ result: Result<Void, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        session?.finishTasksAndInvalidate()
        c.resume(with: result)
    }
}
