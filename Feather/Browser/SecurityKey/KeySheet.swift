import SwiftUI

/// "Touch your security key" and its siblings. Always names the site that is asking.
struct KeySheet: View {
    @ObservedObject var controller: WebAuthnController
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    var body: some View {
        ZStack {
            if let p = controller.prompt {
                Color.black.opacity(0.22).ignoresSafeArea().transition(.opacity)
                card(p).transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .motion(Theme.spring, value: controller.prompt)
    }

    private func card(_ p: KeyPrompt) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon(p.stage)).font(.system(size: 34, weight: .light)).foregroundStyle(Brand.accent)
                .symbolEffect(.pulse, isActive: p.stage == .touch)
            Text(title(p)).font(.headline).multilineTextAlignment(.center)
            Text(subtitle(p)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            switch p.stage {
            case .pin(let retries, let wrong):
                SecureField("PIN", text: $pin).textFieldStyle(.roundedBorder).focused($pinFocused).frame(width: 220)
                    .onSubmit(submit).onAppear { pin = ""; pinFocused = true }
                if wrong { Text("That PIN was wrong.").font(.callout).foregroundStyle(.red) }
                if let retries { Text("\(retries) \(retries == 1 ? "attempt" : "attempts") left before the key locks.").font(.caption).foregroundStyle(retries <= 2 ? .red : .secondary) }
                HStack { cancelButton; Button("Continue", action: submit).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!validPIN) }
            case .choose(let choices):
                VStack(spacing: 6) { ForEach(choices) { c in Button(c.name) { controller.choose(c.id) }.frame(maxWidth: .infinity) } }.frame(width: 240)
                cancelButton
            default:
                cancelButton
            }
        }
        .padding(24).frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }

    private var cancelButton: some View { Button("Cancel") { controller.userCancelled() }.keyboardShortcut(.cancelAction) }
    /// The key accepts 4 to 63 bytes; anything else would only waste a retry (or be refused), so it never reaches the key.
    private var validPIN: Bool { pin.count >= 4 && pin.utf8.count <= 63 }
    private func submit() { guard validPIN else { return }; let p = pin; pin = ""; controller.submitPIN(p) }

    private func icon(_ s: KeyPrompt.Stage) -> String {
        switch s { case .pin: "lock.fill"; case .notRegistered, .failed: "exclamationmark.triangle"; case .choose: "person.crop.circle"; default: "key.horizontal.fill" }
    }
    private func title(_ p: KeyPrompt) -> String {
        switch p.stage {
        case .insertKey: "Insert your security key"
        case .touch: "Touch your security key"
        case .notRegistered: "This key isn't registered here"
        case .pin: "Enter your security key PIN"
        case .choose: "Choose an account"
        case .failed(let m): m
        }
    }
    private func subtitle(_ p: KeyPrompt) -> String {
        switch p.stage {
        case .notRegistered: "\(p.site) doesn't know this key. Plug in a different one, or cancel."
        case .pin: "\(p.site) needs your PIN to \(p.creating ? "register" : "sign in with") this key."
        default: p.creating ? "to register it with \(p.site)" : "to sign in to \(p.site)"
        }
    }
}
