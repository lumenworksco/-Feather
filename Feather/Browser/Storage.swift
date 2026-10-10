import Foundation

/// Tiny JSON persistence in Application Support/Feather. Writes happen off the main thread.
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

    private static let writer = DispatchQueue(label: "dev.feather.storage", qos: .utility)

    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static var lastWritten: [String: Data] = [:]      // main thread only

    static func save<T: Encodable>(_ value: T, as name: String) {
        guard let data = try? JSONEncoder().encode(value), lastWritten[name] != data else { return }   // unchanged: no disk write
        lastWritten[name] = data
        let url = directory.appendingPathComponent(name)
        writer.async { try? data.write(to: url, options: .atomic) }
    }

    /// Blocks until queued writes are on disk (used at quit).
    static func drain() { writer.sync {} }
}
