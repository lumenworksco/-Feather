import Foundation
import AppKit

// Feather's installer helper. It runs outside the app's sandbox (the app cannot replace itself: everything a sandboxed app
// writes is marked "downloaded", and macOS would ask "Open Anyway" after every update). It trusts nothing it is handed:
// the signature, size, hash, version and bundle identity are all checked again here before anything is touched.

let fm = FileManager.default
let home = NSHomeDirectory()
let exchange = UpdateTrust.exchangeDirectory(home: home)
let logURL = exchange.appendingPathComponent("updater.log")

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: logURL, atomically: false, encoding: .utf8) }
}

struct Failure: Error { let message: String; init(_ m: String) { message = m } }

func writeStatus(ok: Bool, from: String, to: String, message: String) {
    let status = UpdateStatus(ok: ok, from: from, to: to, message: message, time: Date())
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    if let d = try? enc.encode(status) { try? d.write(to: exchange.appendingPathComponent("update-status.json"), options: .atomic) }
    log(ok ? "OK: \(message)" : "FAILED: \(message)")
}

func run(_ tool: String, _ args: [String]) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let err = Pipe(); p.standardError = err
    try p.run(); p.waitUntilExit()
    if p.terminationStatus != 0 {
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw Failure("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(p.terminationStatus)) \(text.prefix(200))")
    }
}

func plist(_ app: URL) -> [String: Any]? {
    (try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
}
func versionAndBuild(_ app: URL) -> (String, Int)? {
    guard let p = plist(app), let v = p["CFBundleShortVersionString"] as? String, let b = Int(p["CFBundleVersion"] as? String ?? "") else { return nil }
    return (v, b)
}

/// A file name that stays inside the exchange folder.
func inExchange(_ name: String) throws -> URL {
    guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { throw Failure("unsafe file name in the request") }
    return exchange.appendingPathComponent(name)
}

func launch(_ app: URL, arguments: [String]) -> Bool {
    let c = NSWorkspace.OpenConfiguration(); c.arguments = arguments; c.activates = true; c.createsNewApplicationInstance = true
    let done = DispatchSemaphore(value: 0); var ok = false
    NSWorkspace.shared.openApplication(at: app, configuration: c) { running, error in ok = (running != nil && error == nil); done.signal() }
    _ = done.wait(timeout: .now() + 15)
    return ok
}

var fromVersion = "?", toVersion = "?"
var stage: URL?
var targetPath = "/Applications/Feather.app"
var restoreArguments: [String] = []
var shouldRestoreApp = false          // only when this update is what made the running app quit

/// All the work. Runs on a background thread once the app has checked in with Launch Services.
func performUpdate() {
    do {
        try? fm.createDirectory(at: exchange, withIntermediateDirectories: true)
        log("helper started (pid \(getpid()))")
        guard let data = fm.contents(atPath: exchange.appendingPathComponent("update-request.json").path),
              let request = try? JSONDecoder().decode(UpdateRequest.self, from: data) else { throw Failure("no update request") }
        try? fm.removeItem(at: exchange.appendingPathComponent("update-request.json"))
        targetPath = request.target
        restoreArguments = request.relaunchArguments
        shouldRestoreApp = request.pid > 0

        // 1. The release must be exactly what the owner signed.
        guard let manifestData = fm.contents(atPath: try inExchange(request.manifest).path), let sigData = fm.contents(atPath: try inExchange(request.signature).path),
              let manifest = UpdateTrust.verify(manifest: manifestData, signatureText: sigData, key: UpdateTrust.configuredKey()) else { throw Failure("the update's signature is not valid") }
        toVersion = manifest.version
        let zip = try inExchange(request.zip)
        guard zip.lastPathComponent == manifest.asset else { throw Failure("the zip is not the one the manifest describes") }
        guard (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int) == manifest.size, try UpdateTrust.sha256Hex(of: zip) == manifest.sha256 else { throw Failure("the download is damaged (size or checksum differs)") }

        // 2. What is being replaced must be Feather, older than the update, and in a folder this user can change.
        let target = URL(fileURLWithPath: request.target).resolvingSymlinksInPath()
        guard target.pathExtension == "app", let current = versionAndBuild(target), plist(target)?["CFBundleIdentifier"] as? String == UpdateTrust.expectedBundleID else { throw Failure("the app to replace is not Feather") }
        fromVersion = current.0
        guard UpdateTrust.isNewer(manifest, thanVersion: current.0, build: current.1) else { throw Failure("the update is not newer than the installed version") }
        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw Failure("Feather's folder (\(parent.path)) is not writable by you") }
        for name in request.relaunchArguments where !UpdateRequest.allowedArgumentPrefixes.contains(where: name.hasPrefix) { throw Failure("unexpected launch argument") }

        // 3. Wait for the running app to quit (it has already saved your tabs).
        var waited = 0.0
        while request.pid > 0, kill(request.pid, 0) == 0, waited < 30 { Thread.sleep(forTimeInterval: 0.2); waited += 0.2 }
        log("old Feather (pid \(request.pid)) gone after \(String(format: "%.1f", waited)) s")
        if request.pid > 0, kill(request.pid, 0) == 0 { throw Failure("Feather did not quit in time") }

        // 4. Unpack into a private folder and check what came out.
        let work = exchange.appendingPathComponent("stage-\(UUID().uuidString)"); stage = work
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        log("unpacking")
        try run("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip.path, work.path])
        let contents = try fm.contentsOfDirectory(atPath: work.path)
        guard contents == ["Feather.app"] else { throw Failure("the zip does not contain exactly Feather.app") }
        let staged = work.appendingPathComponent("Feather.app")
        guard let new = versionAndBuild(staged), new.0 == manifest.version, new.1 == manifest.build, plist(staged)?["CFBundleIdentifier"] as? String == manifest.bundleID else { throw Failure("the app in the zip is not the one the manifest describes") }
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", staged.path])

        // 5. Put it next to the old one, swap, and start it. If it does not start, put the old one back.
        let id = UUID().uuidString.prefix(8)
        let sibling = parent.appendingPathComponent(".Feather-update-\(id).app"), old = parent.appendingPathComponent(".Feather-old-\(id).app")
        log("checked; installing next to the old version")
        try run("/usr/bin/ditto", ["--noqtn", staged.path, sibling.path])
        try fm.moveItem(at: target, to: old)
        do { try fm.moveItem(at: sibling, to: target) } catch { try? fm.moveItem(at: old, to: target); throw error }
        log("swapped \(fromVersion) -> \(toVersion); starting the new version")
        // The verdict is written first so the new version can show it from its very first moment; a failed start overwrites it.
        writeStatus(ok: true, from: fromVersion, to: toVersion, message: "Updated Feather from \(fromVersion) to \(toVersion).")
        if !launch(target, arguments: ["--after-update"] + request.relaunchArguments) {
            try? fm.removeItem(at: target)
            try fm.moveItem(at: old, to: target)
            _ = launch(target, arguments: ["--after-update"] + request.relaunchArguments)
            throw Failure("the new version did not start, so \(fromVersion) was put back")
        }
        try? fm.trashItem(at: old, resultingItemURL: nil)          // recoverable from the Trash if something is wrong with the new version
        for name in [request.manifest, request.signature, request.zip] { try? fm.removeItem(at: exchange.appendingPathComponent(name)) }
    } catch {
        let message = (error as? Failure)?.message ?? error.localizedDescription
        writeStatus(ok: false, from: fromVersion, to: toVersion, message: message)
        // Nothing was replaced (or it was put back): make sure the user still has a running Feather.
        if shouldRestoreApp, NSRunningApplication.runningApplications(withBundleIdentifier: UpdateTrust.expectedBundleID).isEmpty {
            _ = launch(URL(fileURLWithPath: targetPath), arguments: ["--after-update"] + restoreArguments)
        }
    }
    if let stage { try? fm.removeItem(at: stage) }
}

// The helper must be a real running app: Launch Services reports a launch as complete only when the app checks in, and the
// Feather that started us waits for that before it quits.
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async { performUpdate(); exit(0) }
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = Delegate()
application.delegate = delegate
application.run()
