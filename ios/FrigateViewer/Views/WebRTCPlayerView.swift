import SwiftUI
import WebKit

/// Live view over WebRTC, negotiated with go2rtc through Frigate's
/// `/live/webrtc/api/ws` websocket (the same path Frigate's web UI uses).
///
/// WebKit's WebRTC stack does the heavy lifting, so no third-party SDK is
/// needed. The page is loaded with the Frigate origin as its base URL so the
/// websocket is same-origin and carries the session cookie.
struct WebRTCPlayerView: UIViewRepresentable {
    enum Status: Equatable {
        case connecting, playing, failed(String)
    }

    let client: FrigateClient
    let stream: String
    let muted: Bool
    @Binding var status: Status

    func makeCoordinator() -> Coordinator { Coordinator(status: $status) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakScriptHandler(context.coordinator), name: "status")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        #if DEBUG
        if #available(iOS 16.4, *) { view.isInspectable = true }
        #endif
        context.coordinator.allowSelfSigned = client.settings.allowSelfSigned
        context.coordinator.load(in: view, client: client, stream: stream, muted: muted)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        if c.loadedStream != stream {
            c.load(in: view, client: client, stream: stream, muted: muted)
        } else if c.muted != muted {
            c.muted = muted
            view.evaluateJavaScript("window.setMuted(\(muted ? "true" : "false"))")
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.stopStream && window.stopStream()")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "status")
        coordinator.timeout?.cancel()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var status: Binding<Status>
        var loadedStream: String?
        var muted = true
        var allowSelfSigned = false
        var timeout: Task<Void, Never>?

        init(status: Binding<Status>) { self.status = status }

        func load(in view: WKWebView, client: FrigateClient, stream: String, muted: Bool) {
            loadedStream = stream
            self.muted = muted
            set(.connecting)
            let html = Self.page(socketURL: client.webRTCSocketURL(stream: stream), muted: muted)
            let base = client.baseURL
            let start = { view.loadHTMLString(html, baseURL: base) }
            if let cookie = client.authCookie {
                view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie, completionHandler: start)
            } else {
                start()
            }
            timeout?.cancel()
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled, self.status.wrappedValue == .connecting else { return }
                self.set(.failed("Timed out. Check that WebRTC port 8555 is reachable and go2rtc has the server's LAN IP as a WebRTC candidate."))
            }
        }

        private func set(_ s: Status) {
            DispatchQueue.main.async { self.status.wrappedValue = s }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String else { return }
            if text == "playing" {
                timeout?.cancel()
                set(.playing)
            } else if text.hasPrefix("error:") {
                set(.failed(String(text.dropFirst(6))))
            } else if text == "reconnecting" {
                set(.connecting)
            }
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if allowSelfSigned, let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        static func page(socketURL: URL, muted: Bool) -> String {
            """
            <!doctype html>
            <html><head>
            <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
            <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
            video{width:100%;height:100%;object-fit:contain;background:#000}</style>
            </head><body>
            <video id="v" autoplay playsinline \(muted ? "muted" : "")></video>
            <script>
            const WS_URL = \(jsString(socketURL.absoluteString));
            const v = document.getElementById('v');
            let pc = null, ws = null, retries = 0, stopped = false, timer = null;
            function post(m) { try { webkit.messageHandlers.status.postMessage(m); } catch (e) {} }
            function cleanup() {
              try { ws && ws.close(); } catch (e) {}
              try { pc && pc.close(); } catch (e) {}
              ws = null; pc = null;
            }
            function scheduleRetry(reason) {
              cleanup();
              if (stopped) return;
              retries += 1;
              if (retries > 5) { post('error:' + reason); return; }
              post('reconnecting');
              clearTimeout(timer);
              timer = setTimeout(start, Math.min(8000, 1000 * retries));
            }
            function start() {
              pc = new RTCPeerConnection({ bundlePolicy: 'max-bundle' });
              const tracks = ['video', 'audio'].map(k => pc.addTransceiver(k, { direction: 'recvonly' }).receiver.track);
              v.srcObject = new MediaStream(tracks);
              pc.onconnectionstatechange = () => {
                if (!pc) return;
                if (pc.connectionState === 'failed') scheduleRetry('WebRTC connection failed');
              };
              ws = new WebSocket(WS_URL);
              ws.onopen = async () => {
                pc.onicecandidate = ev => {
                  if (ev.candidate && ws && ws.readyState === 1)
                    ws.send(JSON.stringify({ type: 'webrtc/candidate', value: ev.candidate.candidate }));
                };
                const offer = await pc.createOffer();
                await pc.setLocalDescription(offer);
                ws.send(JSON.stringify({ type: 'webrtc/offer', value: pc.localDescription.sdp }));
              };
              ws.onmessage = ev => {
                const msg = JSON.parse(ev.data);
                if (!pc) return;
                if (msg.type === 'webrtc/answer') pc.setRemoteDescription({ type: 'answer', sdp: msg.value });
                else if (msg.type === 'webrtc/candidate') pc.addIceCandidate({ candidate: msg.value, sdpMid: '0' });
                else if (msg.type === 'error') post('error:' + msg.value);
              };
              ws.onerror = () => scheduleRetry('Could not open the signalling websocket (check sign-in and address)');
            }
            v.onplaying = () => { retries = 0; post('playing'); };
            window.setMuted = m => { v.muted = m; if (!m) v.play(); };
            window.stopStream = () => { stopped = true; cleanup(); };
            start();
            </script>
            </body></html>
            """
        }

        private static func jsString(_ s: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [s])
            let arr = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
            return String(arr.dropFirst().dropLast())
        }
    }
}

/// Breaks the retain cycle between WKUserContentController and its handler.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
