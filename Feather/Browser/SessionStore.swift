import Foundation
import os

// MARK: - What is saved

/// Everything needed to put the user's tabs back. `state` is WKWebView.interactionState (back/forward list + scroll
/// position). Text typed into web forms and a page's JavaScript state are NOT saved.
struct SessionTab: Codable { var url: URL?; var title: String; var state: Data?; var pinned: Bool? }
struct SavedClosed: Codable { var url: URL; var title: String; var pinned: Bool? }

struct Session: Codable {
    /// Bumped when the format changes. Files from before versioning have no field and are read as version 1.
    static let currentVersion = 2
    var version: Int? = Session.currentVersion
    var tabs: [SessionTab]
    var selected: Int
    var closed: [SavedClosed]?

    /// What a user would call "the same session": addresses, pins, order and selection, ignoring titles and state blobs.
    /// Used so identical sessions don't produce duplicate backups.
    var signature: String {
        tabs.map { ($0.url?.absoluteString ?? "-") + ($0.pinned == true ? "*" : "") }.joined(separator: "|") + "#\(selected)"
    }
    var pinnedCount: Int { tabs.filter { $0.pinned == true }.count }
}

// MARK: - Reading (as forgiving as possible)

struct ParsedSession {
    var session: Session
    var version: Int
    var droppedTabs: Int          // tab entries that could not be understood at all (no usable address)
    var droppedFields: Int        // damaged optional parts (title, state, flags) of tabs that were kept
    var isPartial: Bool { droppedTabs > 0 || droppedFields > 0 }
}

/// Reads a session file field by field. One damaged entry never costs more than itself: a bad `state` blob drops only
/// the state, a bad title only the title, and a tab with no usable address is the only thing that is dropped whole.
enum SessionParser {
    static func parse(_ data: Data) -> ParsedSession? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawTabs = root["tabs"] as? [Any], !rawTabs.isEmpty else { return nil }
        var tabs: [SessionTab] = []
        var droppedTabs = 0, droppedFields = 0

        for raw in rawTabs {
            guard let d = raw as? [String: Any] else { droppedTabs += 1; continue }
            var url: URL?
            switch d["url"] {
            case nil, is NSNull: url = nil                                           // a blank tab: legitimate
            case let s as String:
                guard let parsed = URL(string: s) else { droppedTabs += 1; continue }
                url = parsed
            default: droppedTabs += 1; continue                                      // wrong type: nothing to restore
            }
            var title = ""
            if let t = d["title"] as? String { title = t } else if d["title"] != nil, !(d["title"] is NSNull) { droppedFields += 1 }
            var state: Data?
            if let s = d["state"] as? String {
                if let decoded = Data(base64Encoded: s) { state = decoded } else { droppedFields += 1 }
            } else if d["state"] != nil, !(d["state"] is NSNull) { droppedFields += 1 }
            tabs.append(SessionTab(url: url, title: title, state: state, pinned: d["pinned"] as? Bool))
        }
        guard !tabs.isEmpty else { return nil }

        var closed: [SavedClosed] = []
        for raw in (root["closed"] as? [Any]) ?? [] {
            guard let d = raw as? [String: Any], let s = d["url"] as? String, let url = URL(string: s) else { droppedFields += 1; continue }
            closed.append(SavedClosed(url: url, title: (d["title"] as? String) ?? "", pinned: d["pinned"] as? Bool))
        }
        let selected = min(max((root["selected"] as? Int) ?? 0, 0), tabs.count - 1)
        let version = (root["version"] as? Int) ?? 1
        return ParsedSession(session: Session(version: version, tabs: tabs, selected: selected, closed: closed),
                             version: version, droppedTabs: droppedTabs, droppedFields: droppedFields)
    }
}

// MARK: - Backups

struct BackupEntry: Identifiable, Equatable {
    let url: URL
    let date: Date
    let tabs: Int
    let pinned: Int
    var id: URL { url }

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }

    /// `session-20261010T213000Z-t12-p5.json`: the time and tab counts live in the name, so listing backups never
    /// has to open them.
    static func fileName(date: Date, tabs: Int, pinned: Int) -> String { "session-\(formatter().string(from: date))-t\(tabs)-p\(pinned).json" }

    init(url: URL, date: Date, tabs: Int, pinned: Int) { self.url = url; self.date = date; self.tabs = tabs; self.pinned = pinned }

    init?(url: URL) {
        let name = url.lastPathComponent
        guard name.hasPrefix("session-"), name.hasSuffix(".json") else { return nil }
        let parts = name.dropFirst(8).dropLast(5).split(separator: "-")
        guard parts.count == 3, let date = Self.formatter().date(from: String(parts[0])),
              parts[1].hasPrefix("t"), let t = Int(parts[1].dropFirst()), parts[2].hasPrefix("p"), let p = Int(parts[2].dropFirst()) else { return nil }
        self.init(url: url, date: date, tabs: t, pinned: p)
    }

    /// "Today 21:30 · 12 tabs", "Yesterday 09:05 · 4 tabs", "Mon 6 Oct 18:20 · 9 tabs"
    var menuTitle: String {
        let cal = Calendar.current
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        let day: String
        if cal.isDateInToday(date) { day = "Today" } else if cal.isDateInYesterday(date) { day = "Yesterday" }
        else { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; day = f.string(from: date) }
        return "\(day) \(time.string(from: date)) · \(tabs) tab\(tabs == 1 ? "" : "s")" + (pinned > 0 ? " (\(pinned) pinned)" : "")
    }
}

/// Which backups to keep: everything from the last 2 hours; one per hour for a day; per day for two weeks the one with
/// the most tabs (plus the newest of the day); nothing older; and always the newest three.
/// The "most tabs" rule means a bug (or a mistake) that saves a nearly empty session can't push out the good ones.
enum BackupRetention {
    static func expired(_ entries: [BackupEntry], now: Date) -> [BackupEntry] {
        let sorted = entries.sorted { $0.date > $1.date }
        var keep = Set<URL>(sorted.prefix(3).map(\.url))
        var hourSeen = Set<Int>(), daySeen = Set<Int>()
        var dayBest: [Int: BackupEntry] = [:]
        for e in sorted {
            let age = now.timeIntervalSince(e.date)
            if age < 2 * 3600 {
                keep.insert(e.url)
            } else if age < 24 * 3600 {
                if hourSeen.insert(Int(age / 3600)).inserted { keep.insert(e.url) }
            } else if age < 14 * 86400 {
                let d = Int(age / 86400)
                if daySeen.insert(d).inserted { keep.insert(e.url) }
                if dayBest[d] == nil || e.tabs > dayBest[d]!.tabs { dayBest[d] = e }
            }
        }
        for e in dayBest.values { keep.insert(e.url) }
        return sorted.filter { !keep.contains($0.url) }
    }
}

// MARK: - Writing to disk so that it survives

/// Writes a file so that a crash, a kill or a power cut leaves either the complete old file or the complete new one:
/// write a temporary file, force it to the physical disk, read it back and compare, rename it over the target
/// (atomic), then flush the directory entry.
enum DurableFile {
    enum Failure: LocalizedError {
        case posix(String, Int32)
        case verification
        var errorDescription: String? {
            switch self {
            case .posix(let what, let code): return "\(what) failed: \(String(cString: strerror(code)))"
            case .verification: return "the file read back differently from what was written"
            }
        }
    }

    /// `full` forces the data through the drive's cache too (F_FULLFSYNC). It is slower, so it is used for the
    /// primary session file; secondary copies use the cheaper fsync.
    static func write(_ data: Data, to url: URL, full: Bool) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw Failure.posix("creating \(url.lastPathComponent)", errno) }
        do {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 { if errno == EINTR { continue }; throw Failure.posix("writing \(url.lastPathComponent)", errno) }
                    offset += n
                }
            }
            sync(fd, full: full)
            close(fd)
            guard (try? Data(contentsOf: tmp)) == data else { throw Failure.verification }
            guard rename(tmp.path, url.path) == 0 else { throw Failure.posix("replacing \(url.lastPathComponent)", errno) }
        } catch {
            close(fd)                                  // harmless if already closed
            unlink(tmp.path)
            throw error
        }
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 { sync(dfd, full: full); close(dfd) }
    }

    private static func sync(_ fd: Int32, full: Bool) {
        if full, fcntl(fd, F_FULLFSYNC) == 0 { return }
        fsync(fd)
    }
}

// MARK: - The session store

enum SessionEvent {
    case saved(tabs: Int)
    case failed(String)
    case backupsChanged([BackupEntry])
}

/// Owns the session files. Layout inside the profile folder:
///   session.json           the current session
///   session.prev.json      the save before it (written from memory, so a bad primary never poisons it)
///   SessionBackups/        rolling snapshots (see BackupRetention)
///   SessionQuarantine/     copies of any file that could not be read, kept so nothing is ever destroyed
final class SessionStore: @unchecked Sendable {
    enum LoadSource: Equatable { case primary, previous, backup(Date) }
    enum Outcome {
        case fresh                                                                       // first run: no session files at all
        case loaded(Session, source: LoadSource, partial: Bool, quarantined: Int, newerVersion: Bool)
        case unreadable(quarantined: Int)                                                // files exist but none could be read
    }

    let directory: URL
    let backupsDirectory: URL
    let quarantineDirectory: URL
    private let primaryURL: URL
    private let prevURL: URL
    private let queue = DispatchQueue(label: "dev.feather.session", qos: .utility)
    private let log = Logger(subsystem: "dev.feather", category: "session")

    // Confined to `queue` (and to init/load, which run before the first commit):
    private var lastGood: Data?
    private var lastGoodTabs = 0, lastGoodPinned = 0
    private var lastGoodSignature: String?
    private var lastGoodDate = Date()
    private var lastSnapshotSignature: String?
    private var lastSnapshotDate: Date?
    /// The fullest session of the last two minutes: what a sudden mass-close is compared against (see `commit`).
    private struct Peak { var data: Data; var signature: String; var tabs: Int; var pinned: Int; var date: Date }
    private var peak: Peak?

    var snapshotInterval: TimeInterval = 600
    /// False when another Feather owns this profile: this instance must not write anything.
    var enabled = true
    var onEvent: (@Sendable (SessionEvent) -> Void)?

    init(directory: URL) {
        self.directory = directory
        backupsDirectory = directory.appendingPathComponent("SessionBackups", isDirectory: true)
        quarantineDirectory = directory.appendingPathComponent("SessionQuarantine", isDirectory: true)
        primaryURL = directory.appendingPathComponent("session.json")
        prevURL = directory.appendingPathComponent("session.prev.json")
        for d in [backupsDirectory, quarantineDirectory] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    // MARK: Loading

    /// Tries, in order: the current file, the previous save, then backups from newest to oldest. Any file that exists
    /// but cannot be read is copied to quarantine first, so it can never be destroyed by the next save.
    func load() -> Outcome {
        var candidates: [(LoadSource, URL)] = [(.primary, primaryURL), (.previous, prevURL)]
        let backups = listBackups()
        candidates += backups.map { (LoadSource.backup($0.date), $0.url) }
        if let newest = backups.first, let data = try? Data(contentsOf: newest.url), let parsed = SessionParser.parse(data) {
            lastSnapshotSignature = parsed.session.signature
            lastSnapshotDate = newest.date
        }

        var anyFileExisted = false, quarantined = 0
        for (source, url) in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            anyFileExisted = true
            guard let data = try? Data(contentsOf: url), let parsed = SessionParser.parse(data) else {
                quarantined += quarantine(url, reason: "damaged")
                continue
            }
            let newer = parsed.version > Session.currentVersion
            if parsed.isPartial { quarantined += quarantine(url, reason: "partial") }
            if newer { quarantined += quarantine(url, reason: "newer-version") }
            // The restored session is snapshotted before this run writes anything, so a mistake made later in this run
            // (or a bug) can always be undone from here.
            snapshot(data: data, session: parsed.session, date: Date(), force: true)
            return .loaded(parsed.session, source: source, partial: parsed.isPartial, quarantined: quarantined, newerVersion: newer)
        }
        return anyFileExisted ? .unreadable(quarantined: quarantined) : .fresh
    }

    @discardableResult
    private func quarantine(_ url: URL, reason: String) -> Int {
        let stamp = BackupEntry.fileName(date: Date(), tabs: 0, pinned: 0).dropFirst(8).prefix(16)
        let dest = quarantineDirectory.appendingPathComponent("\(stamp)-\(reason)-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { log.error("could not quarantine \(url.lastPathComponent): \(error.localizedDescription)") }
        // Keep the newest few only; this folder must not grow without bound.
        let files = ((try? FileManager.default.contentsOfDirectory(at: quarantineDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in files.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
        return 1
    }

    // MARK: Saving

    func commitAsync(_ session: Session) {
        guard enabled else { return }
        queue.async { self.commit(session, atQuit: false) }
    }

    /// Blocks until the session is on disk (quit, sleep, power off).
    func commitSync(_ session: Session) {
        guard enabled else { return }
        queue.sync { self.commit(session, atQuit: true) }
    }

    private func commit(_ session: Session, atQuit: Bool) {
        do {
            // Sorted keys: the same session must always produce the same bytes, or "unchanged" could never be detected.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(session)
            if data == lastGood {                                             // nothing changed: no disk write at all
                if atQuit { snapshotAtQuit() }
                post(.saved(tabs: session.tabs.count)); return
            }
            // Validate BEFORE writing: never replace a good file with one we could not read back ourselves.
            guard let check = SessionParser.parse(data), check.session.tabs.count == session.tabs.count, !check.isPartial else {
                throw NSError(domain: "Feather.Session", code: 1, userInfo: [NSLocalizedDescriptionKey: "the session could not be encoded safely"])
            }
            let now = Date()
            // A sharp drop in tab count is the signature of a mistake or a bug. Compare with the fullest session of the last
            // two minutes (not just the previous save: closing tabs one after another loses only a few per save), and keep
            // that session as a backup before the smaller one replaces it.
            if let p = peak, now.timeIntervalSince(p.date) <= 120, Self.shrinks(from: p.tabs, to: session.tabs.count) {
                snapshot(data: p.data, signature: p.signature, tabs: p.tabs, pinned: p.pinned, date: p.date, force: false)
            }
            // Order matters: previous copy first (from memory), then the new file renamed into place atomically.
            // At every instant at least one complete session file exists.
            if let previous = lastGood { try DurableFile.write(previous, to: prevURL, full: false) }
            try DurableFile.write(data, to: primaryURL, full: true)
            lastGood = data; lastGoodTabs = session.tabs.count; lastGoodPinned = session.pinnedCount
            lastGoodSignature = session.signature; lastGoodDate = now
            if peak == nil || now.timeIntervalSince(peak!.date) > 120 || session.tabs.count >= peak!.tabs {
                peak = Peak(data: data, signature: session.signature, tabs: session.tabs.count, pinned: session.pinnedCount, date: now)
            }

            if lastSnapshotDate == nil || now.timeIntervalSince(lastSnapshotDate!) >= snapshotInterval {
                snapshot(data: data, session: session, date: now, force: false)
            }
            if atQuit { snapshotAtQuit() }
            post(.saved(tabs: session.tabs.count))
        } catch {
            log.error("session save failed: \(error.localizedDescription)")
            post(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    /// "Sharply": three or more tabs gone at once, or half of them.
    static func shrinks(from before: Int, to after: Int) -> Bool { before - after >= 3 || (before >= 2 && after * 2 <= before) }

    private func snapshotAtQuit() {
        guard let data = lastGood, let signature = lastGoodSignature, signature != lastSnapshotSignature,
              Date().timeIntervalSince(lastSnapshotDate ?? .distantPast) >= 120 else { return }
        snapshot(data: data, signature: signature, tabs: lastGoodTabs, pinned: lastGoodPinned, date: lastGoodDate, force: false)
    }

    private func snapshot(data: Data, session: Session, date: Date, force: Bool) {
        snapshot(data: data, signature: session.signature, tabs: session.tabs.count, pinned: session.pinnedCount, date: date, force: force)
    }

    private func snapshot(data: Data, signature: String, tabs: Int, pinned: Int, date: Date, force: Bool) {
        guard enabled, signature != lastSnapshotSignature else { return }
        let url = backupsDirectory.appendingPathComponent(BackupEntry.fileName(date: date, tabs: tabs, pinned: pinned))
        do {
            try DurableFile.write(data, to: url, full: false)
            lastSnapshotSignature = signature
            lastSnapshotDate = Date()
            let all = listBackups()
            for old in BackupRetention.expired(all, now: Date()) { try? FileManager.default.removeItem(at: old.url) }
            post(.backupsChanged(listBackups()))
        } catch {
            log.error("backup failed: \(error.localizedDescription)")
        }
    }

    func listBackups() -> [BackupEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { BackupEntry(url: $0) }.sorted { $0.date > $1.date }
    }

    private func post(_ event: SessionEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
