import SwiftUI
import WebKit
import UniformTypeIdentifiers

final class DownloadItem: ObservableObject, Identifiable {
    enum State { case running, finished, failed(String) }
    let id = UUID()
    @Published var name: String
    @Published var fraction = 0.0
    @Published var state = State.running
    var fileURL: URL?
    var download: WKDownload?                          // keeps the transfer alive
    var observation: NSKeyValueObservation?
    init(name: String) { self.name = name }
}

/// Saves downloads to ~/Downloads and exposes the most recent one for a small progress badge.
@MainActor
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var latest: DownloadItem?
    /// This session's downloads, newest first (not kept across restarts; the files themselves are in ~/Downloads).
    @Published private(set) var all: [DownloadItem] = []
    @Published var listVisible = false
    private var items: [ObjectIdentifier: DownloadItem] = [:]

    func dismiss() { latest = nil }

    var runningCount: Int { all.filter { if case .running = $0.state { return true } else { return false } }.count }

    /// Puts a new download at the top of the list.
    func register(_ item: DownloadItem) {
        all.insert(item, at: 0)
        if all.count > 50 { all.removeLast(all.count - 50) }
        latest = item
    }

    func cancel(_ item: DownloadItem) {
        guard case .running = item.state else { return }
        if let d = item.download { items.removeValue(forKey: ObjectIdentifier(d)); d.cancel { _ in } }
        item.state = .failed("Cancelled")
        item.observation = nil
        item.download = nil
        try? FileManager.default.removeItem(at: item.fileURL ?? URL(fileURLWithPath: "/dev/null/none"))      // the partial file
    }

    /// Takes the entry off the list (the file stays where it is).
    func remove(_ item: DownloadItem) {
        cancel(item)
        all.removeAll { $0 === item }
        if latest === item { latest = nil }
    }

    func clearFinished() {
        all.removeAll { if case .running = $0.state { return false } else { return true } }
        latest = nil
    }

    func open(_ item: DownloadItem) { if case .finished = item.state, let url = item.fileURL { NSWorkspace.shared.open(url) } }
    func reveal(_ item: DownloadItem) { if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Never trust a server-suggested name to be a plain file name.
        let clean = suggestedFilename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var dest = dir.appendingPathComponent(clean.isEmpty ? "download" : clean)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        let item = DownloadItem(name: dest.lastPathComponent)
        item.fileURL = dest
        item.download = download
        item.observation = download.progress.observe(\.fractionCompleted) { [weak item] progress, _ in
            DispatchQueue.main.async { item?.fraction = progress.fractionCompleted }
        }
        items[ObjectIdentifier(download)] = item
        register(item)
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.fraction = 1
        item.state = .finished
        item.observation = nil
        item.download = nil
        if TabStore.bench { print("DOWNLOAD_FINISHED \(item.fileURL?.path ?? "-")"); fflush(stdout) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = items.removeValue(forKey: ObjectIdentifier(download)) else { return }
        item.state = .failed(error.localizedDescription)
        item.observation = nil
        item.download = nil
    }
}

/// The toolbar button for the downloads list (a ring fills while something downloads).
struct DownloadsButton: View {
    @ObservedObject var downloads: Downloads
    @State private var hovering = false

    var body: some View {
        Button { downloads.listVisible.toggle() } label: {
            ZStack {
                Image(systemName: "arrow.down.circle").font(.system(size: 14))
                if downloads.runningCount > 0, let item = downloads.all.first(where: { if case .running = $0.state { return true } else { return false } }) {
                    RunningRing(item: item)
                }
            }
            .frame(width: 26, height: 26).hoverFill(radius: 7, strength: 0.10)
        }
        .buttonStyle(PressStyle()).foregroundStyle(.secondary)
        .help("Downloads (⌥⌘L)")
        .popover(isPresented: $downloads.listVisible, arrowEdge: .top) { DownloadsList(downloads: downloads) }
    }

    private struct RunningRing: View {
        @ObservedObject var item: DownloadItem
        var body: some View {
            Circle().trim(from: 0, to: max(0.03, item.fraction)).stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 20, height: 20)
        }
    }
}

struct DownloadsList: View {
    @ObservedObject var downloads: Downloads

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") { downloads.clearFinished() }.buttonStyle(.link).font(.caption)
                    .disabled(downloads.all.allSatisfy { if case .running = $0.state { return true } else { return false } })
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if downloads.all.isEmpty {
                Text("Nothing downloaded in this session yet.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollView {
                    VStack(spacing: 0) { ForEach(downloads.all) { item in ItemRow(item: item, downloads: downloads) } }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 340)
    }

    private struct ItemRow: View {
        @ObservedObject var item: DownloadItem
        let downloads: Downloads
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    switch item.state {
                    case .running: ProgressView(value: item.fraction).progressViewStyle(.linear)
                    case .finished: Text(missing ? "File moved or deleted" : "Downloaded").font(.caption).foregroundStyle(.secondary)
                    case .failed(let why): Text(why).font(.caption).foregroundStyle(.red).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if case .running = item.state {
                    iconButton("xmark.circle", "Cancel") { downloads.cancel(item) }
                } else {
                    if case .finished = item.state, !missing { iconButton("magnifyingglass.circle", "Show in Finder") { downloads.reveal(item) } }
                    iconButton("trash.circle", "Remove from list (keeps the file)") { downloads.remove(item) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.primary.opacity(hovering ? 0.06 : 0))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { downloads.open(item) }
            .help(item.fileURL?.path ?? item.name)
        }

        private var missing: Bool { item.fileURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true }

        private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
            Button(action: action) { Image(systemName: symbol).font(.system(size: 16)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(help)
        }
    }
}

struct DownloadBadge: View {
    @ObservedObject var downloads: Downloads
    var body: some View {
        ZStack {
            if let item = downloads.latest {
                Row(item: item, downloads: downloads).transition(.move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
            }
        }
        .motion(Theme.spring, value: downloads.latest?.id)
    }

    private struct Row: View {
        @ObservedObject var item: DownloadItem
        let downloads: Downloads
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.secondary).contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    switch item.state {
                    case .running: ProgressView(value: item.fraction).progressViewStyle(.linear).frame(width: 160)
                    case .finished: Text("Downloaded").font(.caption).foregroundStyle(.secondary)
                    case .failed(let why): Text(why).font(.caption).foregroundStyle(.red).lineLimit(1)
                    }
                }
                if case .finished = item.state, let url = item.fileURL {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link).font(.caption)
                }
                if case .running = item.state {} else {
                    Button { downloads.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .frame(maxWidth: 320)
        }
        private var icon: String {
            switch item.state { case .running: "arrow.down.circle"; case .finished: "checkmark.circle"; case .failed: "exclamationmark.circle" }
        }
    }
}
