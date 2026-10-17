import Foundation
import os

/// Small JSON files in the profile folder (bookmarks, history). The session has its own, stricter store (SessionStore).
enum Storage {
    /// `--fresh` (benchmarks, self-test) uses a throwaway directory so real data is never touched.
    static let isFresh = CommandLine.arguments.contains("--fresh") || CommandLine.arguments.contains("--selftest")

    /// `--profile=NAME` keeps a named throwaway profile across launches (used to test crash/relaunch restore
    /// without touching real data). `--fresh` is the same idea but different on every launch.
    static let profile = CommandLine.arguments.first { $0.hasPrefix("--profile=") }.map { String($0.dropFirst(10)) }

    static let directory: URL = {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let base: URL
        if let profile { base = tmp.appendingPathComponent("FeatherProfile-\(profile)", isDirectory: true) }
        else if isFresh { base = tmp.appendingPathComponent("FeatherFresh-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true) }
        else { base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Feather", isDirectory: true) }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// True when another Feather already owns this profile: this instance must not write anything to it.
    static var readOnly = false

    private static let writer = DispatchQueue(label: "dev.feather.storage", qos: .utility)
    private static var lastWritten: [String: Data] = [:]      // touched only on `writer`
    private static let log = Logger(subsystem: "dev.feather", category: "storage")

    // MARK: Reading

    /// Reads `name`, falling back to its `.prev` copy if the file is missing or damaged.
    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        for candidate in [name, previousName(name)] {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(candidate)), let value = try? JSONDecoder().decode(T.self, from: data) {
                if candidate != name { log.error("\(name) was unreadable; loaded \(candidate)") }
                return value
            }
        }
        return nil
    }

    private static func previousName(_ name: String) -> String { name.replacingOccurrences(of: ".json", with: ".prev.json") }

    // MARK: Writing

    enum Durability { case standard, full }

    /// Encodes now, writes on a background queue. A save is only remembered as "done" after it has really been
    /// committed to disk, so a failed write is retried by the next identical save instead of being skipped as unchanged.
    static func save<T: Encodable>(_ value: T, as name: String, durability: Durability = .standard, keepPrevious: Bool = false) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]          // identical content must give identical bytes (unchanged saves are skipped)
        guard !readOnly, let data = try? encoder.encode(value) else { return }
        let url = directory.appendingPathComponent(name)
        let prev = directory.appendingPathComponent(previousName(name))
        writer.async {
            guard lastWritten[name] != data else { return }
            do {
                // Rotate the old file to .prev only if it is itself a valid JSON document: never replace a good .prev with junk.
                if keepPrevious, let existing = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: existing)) != nil {
                    try DurableFile.write(existing, to: prev, full: false)
                }
                try DurableFile.write(data, to: url, full: durability == .full)
                lastWritten[name] = data
            } catch {
                log.error("saving \(name) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Blocks until queued writes are on disk (used at quit).
    static func drain() { writer.sync {} }

    // MARK: One Feather per profile

    private static var lockDescriptor: Int32 = -1

    /// Takes an exclusive lock on the profile folder for the life of the process (the system releases it if the process
    /// dies, so there are no stale locks). Returns false if another Feather holds it.
    static func acquireProfileLock() -> Bool {
        let fd = open(directory.appendingPathComponent("profile.lock").path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return true }                    // cannot even create the lock file: don't block the user
        // After an update the previous Feather may still be finishing its last save: wait for it (up to 10 s) instead of
        // starting read-only, which would stop this copy from saving anything.
        let patience = CommandLine.arguments.contains("--after-update") ? 40 : 1
        for attempt in 0..<patience {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { lockDescriptor = fd; return true }
            if attempt < patience - 1 { Thread.sleep(forTimeInterval: 0.25) }
        }
        close(fd)
        return false
    }
}
