import Foundation
import WebKit
import SwiftUI
import os

/// What the "security key" sheet is showing.
struct KeyPrompt: Equatable {
    struct Choice: Equatable, Identifiable { let id: Int; let name: String }
    enum Stage: Equatable {
        case insertKey, touch, notRegistered
        case pin(retries: Int?, wrong: Bool)
        case choose([Choice])
        case failed(String)
    }
    var site: String
    var creating: Bool
    var stage: Stage
}

/// Runs WebAuthn requests from pages against a USB security key (CTAP2 over HID), one at a time.
/// Every request is checked against the page's real origin (from WebKit, not from the page) before the key is touched.
@MainActor final class WebAuthnController: ObservableObject {
    @Published private(set) var prompt: KeyPrompt?
    private static let log = Logger(subsystem: "dev.feather", category: "webauthn")   // never logs PINs, tokens, challenges or client data

    private var client: CTAPClient?
    private let makeTransport: () -> KeyTransport
    private var active: Active?
    private var pinWaiter: ((String?) -> Void)?
    private var choiceWaiter: ((Int?) -> Void)?

    final class Active {
        let id: String, webView: WKWebView?
        var task: Task<[String: Any], Error>?
        var cancelledBy: Reason = .none
        init(id: String, webView: WKWebView?) { self.id = id; self.webView = webView }
        enum Reason { case none, user, timeout, replaced, navigation }
    }

    init(transport: @escaping () -> KeyTransport = { HIDTransport() }) { makeTransport = transport }

    /// True while a request from this web view is waiting (its tab must not be unloaded).
    func isBusy(_ webView: WKWebView) -> Bool { active?.webView === webView }

    // MARK: Entry points

    func handle(_ body: [String: Any], origin: CallerOrigin, webView: WKWebView?, isMainFrame: Bool) async -> [String: Any] {
        let op = body["op"] as? String ?? "", id = body["id"] as? String ?? ""
        if op == "cancel" { cancel(id: id, reason: .navigation); return ["ok": true] }
        do {
            guard PublicSuffix.shared.isLoaded else { throw WebAuthnError.notAllowed("Security keys are unavailable: the site-name list could not be loaded.") }
            guard origin.isSecureContext else { throw WebAuthnError.security("Security keys need a secure (https) page.") }
            if !isMainFrame {
                guard let top = webView?.url, let topOrigin = Self.origin(of: top), topOrigin == origin else { throw WebAuthnError.notAllowed("Security keys can't be used from a frame on another site.") }
            }
            guard let options = body["options"] as? [String: Any] else { throw WebAuthnError.invalid("missing options") }
            // Like other browsers, only the page the user is looking at may ask (this also stops a background tab from covering the screen or cancelling a sign-in).
            guard webView?.window?.isKeyWindow == true else { throw WebAuthnError.notAllowed("The page must be in front to use a security key.") }
            let task: Task<[String: Any], Error>, timeout: TimeInterval, rp: String
            switch op {
            case "get":
                let req = try GetRequest(options, origin: origin)
                guard origin.validate(rpId: req.rpId) else { throw WebAuthnError.security("The relying party ID is not a registrable domain suffix of, nor equal to, the current domain.") }
                timeout = req.timeout; rp = req.rpId
                cancelActive(.replaced)
                task = Task { try await self.performGet(req, origin: origin) }
            case "create":
                let req = try CreateRequest(options, origin: origin)
                guard origin.validate(rpId: req.rpId) else { throw WebAuthnError.security("The relying party ID is not a registrable domain suffix of, nor equal to, the current domain.") }
                timeout = req.timeout; rp = req.rpId
                cancelActive(.replaced)
                task = Task { try await self.performCreate(req, origin: origin) }
            default: throw WebAuthnError.invalid("unknown operation")
            }
            Self.log.info("\(op, privacy: .public) request for \(rp, privacy: .public) from \(origin.string, privacy: .public)")
            let a = Active(id: id, webView: webView)
            active = a
            a.task = task
            let timer = Task { try await Task.sleep(for: .seconds(timeout)); self.cancel(id: id, reason: .timeout) }
            defer { timer.cancel(); if active === a { active = nil; setPrompt(nil) } }
            do { let r = try await task.value; Self.log.info("\(op, privacy: .public) succeeded"); return ["ok": true, "result": r] }
            catch { let e = map(error, a); Self.log.error("\(op, privacy: .public) failed: \(e.name, privacy: .public) \(e.message, privacy: .public) [\(String(describing: error), privacy: .public)]"); throw e }
        } catch let e as WebAuthnError {
            return ["ok": false, "error": ["name": e.name, "message": e.message]]
        } catch {
            return ["ok": false, "error": ["name": "NotAllowedError", "message": "\(error)"]]
        }
    }

    static func origin(of url: URL) -> CallerOrigin? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return CallerOrigin(scheme: scheme, host: host.lowercased(), port: url.port ?? 0)
    }

    func cancel(id: String, reason: Active.Reason) { if active?.id == id { cancelActive(reason) } }
    /// Stops whatever is running for this web view (navigation away, tab closed).
    func cancel(webView: WKWebView) { if active?.webView === webView { cancelActive(.navigation) } }
    func userCancelled() { cancelActive(.user) }

    private func cancelActive(_ reason: Active.Reason) {
        guard let a = active else { return }
        a.cancelledBy = reason
        a.task?.cancel()
        client?.cancelAll()
        pinWaiter?(nil); pinWaiter = nil
        choiceWaiter?(nil); choiceWaiter = nil
    }

    private func map(_ error: Error, _ a: Active) -> WebAuthnError {
        if let e = error as? WebAuthnError { return e }
        if error is CancellationError || (error as? CTAPError) == .cancelled {
            switch a.cancelledBy {
            case .timeout: return .notAllowed("The security key request timed out.")
            case .user: return .notAllowed("The request was cancelled.")
            default: return .notAllowed("The request was cancelled.")
            }
        }
        if let c = error as? CTAPError {
            switch c {
            case .noDevice: return .notAllowed("The security key was removed.")
            case .status(let s):
                switch s {
                case CTAPError.credentialExcluded: return .init(name: "InvalidStateError", message: "This security key is already registered.")
                case CTAPError.unsupportedAlgorithm: return .notSupported("The security key does not support the requested algorithm.")
                case CTAPError.pinBlocked: return .notAllowed("The security key's PIN is blocked.")
                case CTAPError.pinAuthBlocked: return .notAllowed("Too many wrong PINs. Remove the key and plug it in again.")
                case CTAPError.userActionTimeout, CTAPError.operationDenied, CTAPError.noCredentials: return .notAllowed()
                default: return .notAllowed("The security key reported error 0x" + String(s, radix: 16) + ".")
                }
            case .transport(let m): return .notAllowed("Could not talk to the security key (\(m)).")
            default: return .notAllowed()
            }
        }
        return .notAllowed("\(error)")
    }

    // MARK: Sheet plumbing

    private func setPrompt(_ p: KeyPrompt?) { withAnimation(Theme.spring) { prompt = p } }
    private func setStage(_ s: KeyPrompt.Stage) { if var p = prompt { p.stage = s; setPrompt(p) } }

    private func session() -> CTAPClient {
        if let client { return client }
        let c = CTAPClient(transport: makeTransport())
        c.onDevicesChanged = { [weak self] in
            guard let self, let p = self.prompt else { return }
            if p.stage == .insertKey, !c.devices.isEmpty { self.setStage(.touch) }
            else if p.stage == .touch, c.devices.isEmpty { self.setStage(.insertKey) }
        }
        client = c
        return c
    }

    private func open(site: String, creating: Bool) async throws -> CTAPDevice {
        let c = session()
        setPrompt(KeyPrompt(site: site, creating: creating, stage: c.devices.isEmpty ? .insertKey : .touch))
        let device = try await c.waitForDevice()
        let dev = try await CTAPDevice.open(c, device)
        dev.onTouchNeeded = { [weak self] in if self?.prompt?.stage != .touch { self?.setStage(.touch) } }
        return dev
    }

    func submitPIN(_ pin: String) { pinWaiter?(pin); pinWaiter = nil }
    func choose(_ index: Int) { choiceWaiter?(index); choiceWaiter = nil }

    private func askPIN(retries: Int?, wrong: Bool) async throws -> String {
        setStage(.pin(retries: retries, wrong: wrong))
        let pin: String? = await withCheckedContinuation { c in pinWaiter = { c.resume(returning: $0) } }
        try Task.checkCancellation()
        guard let pin, !pin.isEmpty else { throw CTAPError.cancelled }
        setStage(.touch)
        return pin
    }

    /// Gets a PIN token. A wrong PIN is reported to the user with the retries left; it is never retried automatically.
    private func pinToken(_ dev: CTAPDevice) async throws -> Data {
        guard dev.info.pinIsSet else { throw WebAuthnError.notAllowed("This site needs a PIN, but the security key has none set. Set one in Yubico Authenticator first.") }
        guard dev.info.pinProtocols.contains(1) else { throw WebAuthnError.notSupported("This security key's PIN protocol is not supported yet.") }
        var wrong = false
        while true {
            let retries = try await PinProtocolV1.retries(dev)
            if retries == 0 { throw CTAPError.status(CTAPError.pinBlocked) }
            let pin = try await askPIN(retries: retries, wrong: wrong)
            do { return try await PinProtocolV1.token(dev, pin: pin) }
            catch CTAPError.status(let s) where s == CTAPError.pinInvalid { wrong = true }
        }
    }

    // MARK: Signing in

    private func performGet(_ req: GetRequest, origin: CallerOrigin) async throws -> [String: Any] {
        let cd = ClientData(type: "webauthn.get", challenge: req.challenge, origin: origin.string)
        var dev = try await open(site: origin.host, creating: false)
        var rpCandidates = [req.rpId]
        var appIDUsed = false
        if let app = req.appID, origin.validate(appID: app) { rpCandidates.append(app) }

        var chosenRP = req.rpId, ids: [Data] = []
        if !req.allow.isEmpty {
            search: while true {
                try Task.checkCancellation()
                var fallback: (String, [Data])?
                for rp in rpCandidates {
                    for chunk in dev.usable(req.allow).chunked(dev.listLimit) {
                        switch try await dev.probe(rpId: rp, clientDataHash: cd.hash, allow: chunk) {
                        case .some(.some(let found)): chosenRP = rp; ids = [found]; break search
                        case .some(.none): if fallback == nil { fallback = (rp, chunk) }
                        case .none: chosenRP = rp; ids = chunk; break search          // the key won't say without a touch: try for real
                        }
                    }
                }
                // The no-touch check can't see credentials that need the PIN (credProtect). With the PIN required, ask for real before giving up.
                if req.userVerification == "required", dev.info.pinIsSet, let (rp, chunk) = fallback { chosenRP = rp; ids = chunk; break search }
                // This key has none of the credentials. Wait for another key to be plugged in instead of failing.
                setStage(.notRegistered)
                try await session().waitForChange()
                let c = session()
                _ = try await c.waitForDevice()
                dev = try await open(site: origin.host, creating: false)
            }
            appIDUsed = chosenRP != req.rpId
        }

        let wantsPIN = req.userVerification == "required" || (req.allow.isEmpty && req.userVerification != "discouraged" && dev.info.pinIsSet)
        let token = wantsPIN ? try await pinToken(dev) : nil
        setStage(.touch)
        let assertions: [Assertion]
        do { assertions = try await dev.getAssertion(rpId: chosenRP, clientDataHash: cd.hash, allow: ids, pinToken: token) }
        catch CTAPError.status(let s) where s == CTAPError.noCredentials && req.userVerification == "required" {
            Self.log.info("key has no matching credential")
            throw WebAuthnError.notAllowed("This security key has no credential for this site.")
        }
        var pick = assertions[0]
        if assertions.count > 1 {
            setStage(.choose(assertions.enumerated().map { .init(id: $0.offset, name: $0.element.userName ?? "Account \($0.offset + 1)") }))
            let index: Int? = await withCheckedContinuation { c in choiceWaiter = { c.resume(returning: $0) } }
            try Task.checkCancellation()
            guard let index, assertions.indices.contains(index) else { throw CTAPError.cancelled }
            pick = assertions[index]
        }
        return [
            "id": Base64URL.encode(pick.credentialID), "rawId": Base64URL.encode(pick.credentialID),
            "clientDataJSON": Base64URL.encode(cd.json), "authenticatorData": Base64URL.encode(pick.authData),
            "signature": Base64URL.encode(pick.signature), "userHandle": pick.userHandle.map(Base64URL.encode) as Any,
            "appid": appIDUsed,
        ]
    }

    // MARK: Registering

    private func performCreate(_ req: CreateRequest, origin: CallerOrigin) async throws -> [String: Any] {
        let cd = ClientData(type: "webauthn.create", challenge: req.challenge, origin: origin.string)
        let dev = try await open(site: origin.host, creating: true)
        // Is the key already registered? Asked without a touch, so the answer can be given straight away.
        var exclude: [Data] = []
        for chunk in dev.usable(req.exclude).chunked(dev.listLimit) {
            switch try await dev.probe(rpId: req.rpId, clientDataHash: cd.hash, allow: chunk) {
            case .some(.some): throw CTAPError.status(CTAPError.credentialExcluded)
            case .some(.none): continue
            case .none: exclude = chunk
            }
        }
        let needsPIN = req.userVerification == "required" || (req.residentKey && dev.info.pinIsSet)
        let token = needsPIN ? try await pinToken(dev) : nil
        setStage(.touch)
        let reg = try await dev.makeCredential(clientDataHash: cd.hash, rpId: req.rpId, rpName: req.rpName, userID: req.userID, userName: req.userName,
                                               userDisplayName: req.userDisplayName, algorithms: req.algorithms, exclude: exclude,
                                               residentKey: req.residentKey, pinToken: token)
        let attestation = CBOR.map([(.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(reg.authData))]).encoded()
        return [
            "id": Base64URL.encode(reg.credentialID), "rawId": Base64URL.encode(reg.credentialID),
            "clientDataJSON": Base64URL.encode(cd.json), "attestationObject": Base64URL.encode(attestation),
            "authenticatorData": Base64URL.encode(reg.authData),
            "publicKey": COSE.spki(reg.publicKey).map(Base64URL.encode) as Any,
            "publicKeyAlgorithm": reg.publicKey?[3]?.intValue as Any,
        ]
    }
}

extension Array {
    func chunked(_ n: Int) -> [[Element]] { stride(from: 0, to: count, by: Swift.max(1, n)).map { Array(self[$0..<Swift.min($0 + Swift.max(1, n), count)]) } }
}
