import Foundation
import WebKit

/// Tells the tab whether a page is playing sound, and mutes it on request. WebKit has no public API for either on a web view,
/// so a small script (run in an isolated content world, which the page cannot see or fake) watches `<audio>`/`<video>`
/// elements in every frame and reports to this handler. Limits: media created without being added to the page, media inside
/// shadow DOM, and Web Audio (games, some players) are invisible to it, so such tabs show no speaker and cannot be muted.
@MainActor final class MediaBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "featherMedia"
    weak var store: TabStore?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let token = body["t"] as? String,
              let wv = message.webView, let tab = store?.tabs.first(where: { $0.webView === wv }) else { replyHandler(false, nil); return }
        if body["hello"] as? Bool == true {
            tab.noteFrame(token, message.frameInfo)
            replyHandler(tab.isMuted, nil)               // a new document asks whether its tab is muted, so muting survives navigation
        } else {
            tab.mediaReport(token: token, frame: message.frameInfo, playing: body["playing"] as? Bool ?? false)
            replyHandler(false, nil)
        }
    }

    static let script = #"""
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.featherMedia;
      if (!handler || window.__featherMedia) return;
      window.__featherMedia = true;
      var token = Math.random().toString(36).slice(2), muted = false, last = false;
      function media() { return document.querySelectorAll("audio,video"); }
      // Sound the user would hear: playing, not ended, not silenced by the page itself (our own muting does not count).
      function audible() {
        var m = media();
        for (var i = 0; i < m.length; i++) {
          var e = m[i];
          if (!e.paused && !e.ended && e.readyState > 2 && e.volume > 0 && (!e.muted || e.__fm)) return true;
        }
        return false;
      }
      function report() {
        var p = audible();
        if (p !== last) { last = p; handler.postMessage({ t: token, playing: p }); }
      }
      function mute(e) { if (!e.muted) { e.__fm = true; e.muted = true; } }
      function onMedia(ev) {
        var t = ev.target;
        if (!t || !t.tagName || !/^(AUDIO|VIDEO)$/.test(t.tagName)) return;
        if (muted) mute(t);                 // new media and pages that unmute themselves stay muted
        report();
      }
      ["play", "playing", "pause", "ended", "emptied", "volumechange", "loadeddata"].forEach(function (n) { document.addEventListener(n, onMedia, true); });
      window.__featherSetMuted = function (v) {
        muted = !!v;
        var m = media();
        for (var i = 0; i < m.length; i++) {
          if (muted) mute(m[i]); else if (m[i].__fm) { m[i].muted = false; m[i].__fm = false; }
        }
        report();
      };
      addEventListener("pagehide", function () { if (last) { last = false; handler.postMessage({ t: token, playing: false }); } });
      handler.postMessage({ t: token, hello: true }).then(function (isMuted) { if (isMuted) window.__featherSetMuted(true); }, function () {});
    })();
    """#

    /// Picture in picture for the biggest video on the page (the one playing, if several).
    static let pictureInPicture = #"""
    (function () {
      var list = [].slice.call(document.querySelectorAll("video")).filter(function (v) { return v.readyState > 0; });
      list.sort(function (a, b) { return ((!b.paused) - (!a.paused)) || (b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight); });
      var v = list[0];
      if (!v) return false;
      try {
        if (v.webkitSetPresentationMode) { v.webkitSetPresentationMode(v.webkitPresentationMode === "picture-in-picture" ? "inline" : "picture-in-picture"); return true; }
        if (v.requestPictureInPicture) { v.requestPictureInPicture(); return true; }
      } catch (e) {}
      return false;
    })();
    """#
}

extension Tab {
    /// A frame told us it exists (and so can be muted), without saying anything about sound yet.
    func noteFrame(_ token: String, _ frame: WKFrameInfo) {
        if mediaFrames[token] == nil { mediaFrames[token] = (frame, false) }
    }

    /// One frame's sound state changed. The tab is "playing" while any frame is.
    func mediaReport(token: String, frame: WKFrameInfo, playing: Bool) {
        mediaFrames[token] = (frame, playing)
        let any = mediaFrames.values.contains { $0.playing }
        if any != isPlayingAudio { isPlayingAudio = any; store?.scheduleGroupFold() }
    }

    /// New page in the main frame: what the old page's frames said no longer applies.
    func resetMedia() {
        mediaFrames = [:]
        if isPlayingAudio { isPlayingAudio = false }
    }

    func toggleMute() { setMuted(!isMuted) }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        guard let wv = webView else { return }
        let js = "window.__featherSetMuted && window.__featherSetMuted(\(muted))"
        wv.evaluateJavaScript(js, in: nil, in: .defaultClient) { _ in }                         // the main frame, even if it has said nothing yet
        for (frame, _) in mediaFrames.values where !frame.isMainFrame { wv.evaluateJavaScript(js, in: frame, in: .defaultClient) { _ in } }
    }

    func pictureInPicture() {
        guard let wv = webView else { return }
        wv.evaluateJavaScript(MediaBridge.pictureInPicture, in: nil, in: .defaultClient) { _ in }
        for (frame, _) in mediaFrames.values where !frame.isMainFrame { wv.evaluateJavaScript(MediaBridge.pictureInPicture, in: frame, in: .defaultClient) { _ in } }
    }
}
