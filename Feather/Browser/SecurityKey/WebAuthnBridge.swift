import Foundation
import WebKit

/// Receives WebAuthn calls from the page script and answers them. The caller's origin comes from WebKit's frame info.
@MainActor final class WebAuthnBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "featherWebAuthn"
    weak var controller: WebAuthnController?
    init(controller: WebAuthnController) { self.controller = controller }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let o = message.frameInfo.securityOrigin
        let origin = CallerOrigin(scheme: o.protocol.lowercased(), host: o.host.lowercased(), port: o.port)
        guard let body = message.body as? [String: Any], let controller else { replyHandler(["ok": false, "error": ["name": "NotAllowedError", "message": "unavailable"]], nil); return }
        let webView = message.webView, isMain = message.frameInfo.isMainFrame
        Task { replyHandler(await controller.handle(body, origin: origin, webView: webView, isMainFrame: isMain), nil) }
    }

    /// Runs before any page script, in every frame. Replaces navigator.credentials.get/create for publicKey requests only.
    static let script = #"""
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.featherWebAuthn;
      var creds = window.navigator && navigator.credentials;
      if (!handler || !creds || window.__featherWebAuthn) return;
      window.__featherWebAuthn = true;
      var proto = Object.getPrototypeOf(creds), origGet = proto.get, origCreate = proto.create;
      var counter = 0;

      function toBytes(x) {
        if (x instanceof ArrayBuffer) return new Uint8Array(x);
        if (ArrayBuffer.isView(x)) return new Uint8Array(x.buffer, x.byteOffset, x.byteLength);
        throw new TypeError("Value is not an ArrayBuffer or ArrayBufferView");
      }
      function enc(x) {
        var b = toBytes(x), s = "";
        for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
        return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
      }
      function dec(s) {
        s = s.replace(/-/g, "+").replace(/_/g, "/"); while (s.length % 4) s += "=";
        var raw = atob(s), out = new Uint8Array(raw.length);
        for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
        return out.buffer;
      }
      function descriptors(list) {
        return (list || []).map(function (c) { return { type: c.type, id: enc(c.id) }; });
      }
      function abortError(signal) {
        return (signal && signal.reason !== undefined) ? signal.reason : new DOMException("The operation was aborted.", "AbortError");
      }
      function define(obj, name, value) { Object.defineProperty(obj, name, { value: value, enumerable: true, configurable: true }); }

      function run(op, options, signal, build) {
        return new Promise(function (resolve, reject) {
          var id = String(++counter) + "-" + Math.random().toString(36).slice(2), done = false;
          function onAbort() { if (done) return; done = true; handler.postMessage({ op: "cancel", id: id }); reject(abortError(signal)); }
          if (signal) signal.addEventListener("abort", onAbort, { once: true });
          handler.postMessage({ op: op, id: id, options: options }).then(function (reply) {
            if (done) return;
            done = true;
            if (signal) signal.removeEventListener("abort", onAbort);
            if (reply && reply.ok) { try { resolve(build(reply.result)); } catch (e) { reject(e); } }
            else { var er = (reply && reply.error) || {}; reject(new DOMException(er.message || "Not allowed", er.name || "NotAllowedError")); }
          }, function () { if (!done) { done = true; reject(new DOMException("The request failed.", "NotAllowedError")); } });
        });
      }

      function credentialObject(r, response, extensions) {
        var c = Object.create(window.PublicKeyCredential ? PublicKeyCredential.prototype : Object.prototype);
        define(c, "id", r.id); define(c, "rawId", dec(r.rawId)); define(c, "type", "public-key");
        define(c, "authenticatorAttachment", "cross-platform"); define(c, "response", response);
        define(c, "getClientExtensionResults", function () { return extensions; });
        return c;
      }
      function buildAssertion(r) {
        var resp = Object.create(window.AuthenticatorAssertionResponse ? AuthenticatorAssertionResponse.prototype : Object.prototype);
        define(resp, "clientDataJSON", dec(r.clientDataJSON)); define(resp, "authenticatorData", dec(r.authenticatorData));
        define(resp, "signature", dec(r.signature)); define(resp, "userHandle", r.userHandle ? dec(r.userHandle) : null);
        var c = credentialObject(r, resp, r.appid ? { appid: true } : {});
        define(c, "toJSON", function () { return { id: r.id, rawId: r.rawId, type: "public-key", authenticatorAttachment: "cross-platform",
          response: { clientDataJSON: r.clientDataJSON, authenticatorData: r.authenticatorData, signature: r.signature, userHandle: r.userHandle || undefined },
          clientExtensionResults: r.appid ? { appid: true } : {} }; });
        return c;
      }
      function buildAttestation(r) {
        var resp = Object.create(window.AuthenticatorAttestationResponse ? AuthenticatorAttestationResponse.prototype : Object.prototype);
        define(resp, "clientDataJSON", dec(r.clientDataJSON)); define(resp, "attestationObject", dec(r.attestationObject));
        define(resp, "getTransports", function () { return ["usb"]; });
        define(resp, "getAuthenticatorData", function () { return dec(r.authenticatorData); });
        define(resp, "getPublicKey", function () { return r.publicKey ? dec(r.publicKey) : null; });
        define(resp, "getPublicKeyAlgorithm", function () { return r.publicKeyAlgorithm; });
        var c = credentialObject(r, resp, {});
        define(c, "toJSON", function () { return { id: r.id, rawId: r.rawId, type: "public-key", authenticatorAttachment: "cross-platform",
          response: { clientDataJSON: r.clientDataJSON, attestationObject: r.attestationObject, authenticatorData: r.authenticatorData,
            transports: ["usb"], publicKey: r.publicKey || undefined, publicKeyAlgorithm: r.publicKeyAlgorithm }, clientExtensionResults: {} }; });
        return c;
      }

      define(proto, "get", function get(options) {
        if (!options || !options.publicKey) return origGet.apply(this, arguments);
        var pk = options.publicKey, signal = options.signal;
        if (signal && signal.aborted) return Promise.reject(abortError(signal));
        // Conditional ("autofill") requests have no key-based flow here: leave them pending until the page aborts them.
        if (options.mediation === "conditional") return new Promise(function (_, reject) { if (signal) signal.addEventListener("abort", function () { reject(abortError(signal)); }, { once: true }); });
        var ext = pk.extensions || {};
        return run("get", { challenge: enc(pk.challenge), rpId: pk.rpId, timeout: pk.timeout, userVerification: pk.userVerification,
          allowCredentials: descriptors(pk.allowCredentials), extensions: { appid: typeof ext.appid === "string" ? ext.appid : undefined } }, signal, buildAssertion);
      });
      define(proto, "create", function create(options) {
        if (!options || !options.publicKey) return origCreate.apply(this, arguments);
        var pk = options.publicKey, signal = options.signal;
        if (signal && signal.aborted) return Promise.reject(abortError(signal));
        var user = pk.user || {};
        return run("create", { challenge: enc(pk.challenge), rp: pk.rp, user: { id: user.id ? enc(user.id) : undefined, name: user.name, displayName: user.displayName },
          pubKeyCredParams: pk.pubKeyCredParams, timeout: pk.timeout, excludeCredentials: descriptors(pk.excludeCredentials),
          authenticatorSelection: pk.authenticatorSelection, attestation: pk.attestation }, signal, buildAttestation);
      });
      if (window.PublicKeyCredential) {
        // Platform authenticators (Touch ID passkeys) and autofill are not available; say so honestly.
        PublicKeyCredential.isConditionalMediationAvailable = function () { return Promise.resolve(false); };
        PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function () { return Promise.resolve(false); };
      }
    })();
    """#
}
