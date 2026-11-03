import Foundation
import WebKit
import CryptoKit
import os

/// Blocks requests to well-known advertising and tracking companies, using WebKit's own content rules (the rules run inside WebKit,
/// so Feather never sees the pages' traffic). Conservative by design: only requests a page makes to *another* site are blocked
/// (a site's own resources are never touched), and tag managers and social-login scripts are left alone so sign-in keeps working.
/// This is a short built-in list, not a full filter list: it will miss ads that are served from a site's own domain (YouTube's, for example).
@MainActor final class ContentBlocker {
    private static let log = Logger(subsystem: "dev.feather", category: "blocking")

    /// Registrable domains; each blocks the domain and all of its subdomains when requested by a page on another site.
    nonisolated static let domains: [String] = [
        // Advertising networks and exchanges
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com", "2mdn.net", "adnxs.com", "adsrvr.org",
        "advertising.com", "amazon-adsystem.com", "criteo.com", "criteo.net", "pubmatic.com", "rubiconproject.com", "openx.net",
        "casalemedia.com", "taboola.com", "outbrain.com", "moatads.com", "adform.net", "smartadserver.com", "media.net", "yieldmo.com",
        "sharethrough.com", "33across.com", "bidswitch.net", "contextweb.com", "lijit.com", "indexww.com", "teads.tv", "adsafeprotected.com",
        "serving-sys.com", "zedo.com", "revcontent.com", "mgid.com", "adcolony.com", "ads-twitter.com",
        // Tracking and analytics companies
        "google-analytics.com", "scorecardresearch.com", "quantserve.com", "hotjar.com", "mouseflow.com", "crazyegg.com", "fullstory.com",
        "chartbeat.com", "chartbeat.net", "omtrdc.net", "demdex.net", "krxd.net", "bluekai.com", "exelator.com", "rlcdn.com", "tapad.com",
        "agkn.com", "adsymptotic.com", "mixpanel.com", "branch.io", "appsflyer.com", "adjust.com",
    ]

    /// The rules as WebKit's JSON: one block rule per domain (WebKit's patterns have no alternation), then, last, one rule per
    /// excepted site that cancels everything before it. `ignore-previous-rules` only reaches back inside the same list, so both
    /// parts must be compiled together.
    nonisolated static func rulesJSON(domains: [String] = ContentBlocker.domains, exceptions: [String]) -> String {
        func escaped(_ d: String) -> String { d.replacingOccurrences(of: ".", with: "\\\\.") }
        var rules = domains.map {
            #"{"trigger":{"url-filter":"^https?://([^/]*\\.)?\#(escaped($0))[:/]","load-type":["third-party"]},"action":{"type":"block"}}"#
        }
        let sites = exceptions.filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } }
        for site in sites {
            rules.append(#"{"trigger":{"url-filter":".*","if-domain":["*\#(site)"]},"action":{"type":"ignore-previous-rules"}}"#)
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    private let controller: WKUserContentController
    private(set) var installed: WKContentRuleList?
    private var generation = 0

    init(controller: WKUserContentController) { self.controller = controller }

    /// Replaces the installed rules with the right ones for the current settings. Web views that already exist pick the change up
    /// for the requests they make from then on. Safe to call often; only the newest call has any effect.
    func update(enabled: Bool, exceptions: [String]) async {
        generation += 1
        let mine = generation
        guard enabled else { remove(); return }
        await install(json: Self.rulesJSON(exceptions: exceptions), mine: mine)
    }

    /// Installs rules as given (the built-in list goes through here too; tests use it with their own).
    func install(json: String, mine: Int? = nil) async {
        let mine = mine ?? { generation += 1; return generation }()
        let id = "feather-" + SHA256.hash(data: Data(json.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        guard let store = WKContentRuleListStore.default() else { return }
        do {
            // Compiled lists are cached by identifier (a hash of the rules), so after the first launch this is a lookup.
            var list = await Self.lookUp(store, id)
            if list == nil { list = try await Self.compile(store, id, json) }
            guard mine == generation, let list else { return }                // a newer update superseded this one
            remove()
            controller.add(list)
            installed = list
            Self.log.info("blocking on: \(Self.domains.count) domains")
        } catch {
            Self.log.error("blocking rules could not be installed: \(String(describing: error), privacy: .public)")
        }
        // Old compiled lists (earlier exception sets, earlier versions) are not kept around.
        for old in await Self.identifiers(store) where old.hasPrefix("feather-") && old != id { await Self.forget(store, old) }
    }

    private static func lookUp(_ store: WKContentRuleListStore, _ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { c in store.lookUpContentRuleList(forIdentifier: id) { list, _ in c.resume(returning: list) } }
    }
    private static func compile(_ store: WKContentRuleListStore, _ id: String, _ json: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { c in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: list) }
            }
        }
    }
    private static func identifiers(_ store: WKContentRuleListStore) async -> [String] {
        await withCheckedContinuation { c in store.getAvailableContentRuleListIdentifiers { c.resume(returning: $0 ?? []) } }
    }
    private static func forget(_ store: WKContentRuleListStore, _ id: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in store.removeContentRuleList(forIdentifier: id) { _ in c.resume() } }
    }

    func remove() {
        if let list = installed { controller.remove(list) }
        installed = nil
    }
}

/// Lets exactly one of two racing tasks resume a continuation.
private final class Gate { var done = false }

/// Waits for `op`, but never longer than `seconds` (the work carries on in the background if it is slower).
@MainActor func waitAtMost(_ seconds: Double, _ op: @escaping @MainActor () async -> Void) async {
    let gate = Gate()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        Task { @MainActor in await op(); if !gate.done { gate.done = true; c.resume() } }
        Task { @MainActor in try? await Task.sleep(for: .seconds(seconds)); if !gate.done { gate.done = true; c.resume() } }
    }
}
