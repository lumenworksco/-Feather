import SwiftUI

/// "Feather 0.1.3 is available", download progress, and the outcome of the last install. Appears only when there is something to say.
struct UpdateBannerView: View {
    @ObservedObject var updates: Updates

    var body: some View {
        VStack(spacing: 8) {
            if let notice = updates.notice {
                row(icon: notice.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", warning: !notice.ok, text: notice.ok ? notice.message : "The update didn't install: \(notice.message)") {
                    Button("OK") { updates.dismissNotice() }.buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Brand.accent)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            switch updates.state {
            case .available(let m):
                row(icon: "arrow.down.circle.fill", warning: false, text: "Feather \(m.version) is available. You have \(updates.currentVersion).") {
                    Button("Update") { Task { await updates.download(); updates.install() } }.buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Brand.accent)
                    Button { updates.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(PressStyle(scale: 0.88)).foregroundStyle(.secondary)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            case .downloading(let m, let fraction):
                row(icon: "arrow.down.circle", warning: false, text: "Downloading Feather \(m.version)… \(Int(fraction * 100))%") { ProgressView(value: fraction).frame(width: 90) }
                    .transition(.opacity)
            case .ready(let m):
                row(icon: "checkmark.circle.fill", warning: false, text: "Feather \(m.version) is downloaded and verified.") {
                    Button("Install and Restart") { updates.install() }.buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Brand.accent)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            case .installing(let m):
                row(icon: "arrow.triangle.2.circlepath", warning: false, text: "Installing Feather \(m.version). It will reopen in a moment with your tabs.") { ProgressView().controlSize(.small) }
                    .transition(.opacity)
            case .failed(let message):
                row(icon: "exclamationmark.triangle.fill", warning: true, text: message) {
                    Button("Download Manually") { NSWorkspace.shared.open(Updates.releasesPage) }.buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Brand.accent)
                    Button { updates.resetFailure() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(PressStyle(scale: 0.88)).foregroundStyle(.secondary)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            default:
                EmptyView()
            }
        }
        .motion(Theme.spring, value: updates.state)
        .motion(Theme.spring, value: updates.notice?.time)
    }

    private func row<Trailing: View>(icon: String, warning: Bool, text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).foregroundStyle(warning ? Color.orange : Brand.accent).font(.system(size: 14))
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((warning ? Color.orange : Color.primary).opacity(warning ? 0.45 : 0.10)))
    }
}
