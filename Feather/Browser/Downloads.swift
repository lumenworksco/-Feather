import SwiftUI
import WebKit

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
    private var items: [ObjectIdentifier: DownloadItem] = [:]

    func dismiss() { latest = nil }

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
        latest = item
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
