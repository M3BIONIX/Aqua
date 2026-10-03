import SwiftUI
import WebKit
import AquaCore

/// Shows Epic's own login page. After sign-in Epic displays a small JSON document
/// containing `authorizationCode`; Aqua reads it and hands it to legendary.
/// If the embedded page doesn't work (e.g. a social login refuses embedded browsers),
/// the user can sign in in their own browser and paste that JSON page here.
struct EpicLoginView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var manualCode = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StoreLogo(store: .epic, size: 18).foregroundStyle(Theme.text)
                Text("Sign in to Epic Games").font(.geist(15, .semibold))
                Spacer()
                Button("Use my browser") { NSWorkspace.shared.open(EpicStore.loginURL) }.buttonStyle(SecondaryButtonStyle(height: 32))
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle(height: 32))
            }
            .padding(14)
            Rectangle().fill(Theme.border).frame(height: 1)
            EpicWebView(log: model.service.paths.logs.appendingPathComponent("epic-login.log")) { code in
                model.completeEpicLogin(code: code)
                dismiss()
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("Signed in with your browser? Epic then shows a short page containing \"authorizationCode\". Paste that page, or just the code, here.")
                    .font(.geist(13)).foregroundStyle(Theme.mutedText)
                HStack(spacing: 8) {
                    TextField("", text: $manualCode, prompt: Text("Authorization code").foregroundStyle(Theme.faintText))
                        .textFieldStyle(.plain)
                        .font(.mono(13))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                        .onSubmit(useManualCode)
                    Button("Sign in", action: useManualCode)
                        .buttonStyle(PrimaryButtonStyle(height: 34))
                        .disabled(manualCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
        .frame(width: 560, height: 760)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
    }

    private func useManualCode() {
        model.completeEpicLogin(code: manualCode)
        dismiss()
    }
}

struct EpicWebView: NSViewRepresentable {
    let log: URL
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(log: log, onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        // Non-persistent store: Epic cookies stay out of Safari and out of later sessions.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: .zero, configuration: config)
        // Some identity providers refuse WebKit's default embedded user agent.
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.record("start", EpicStore.loginURL)
        view.load(URLRequest(url: EpicStore.loginURL))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let log: URL
        let onCode: (String) -> Void
        private var delivered = false
        private var popups: [WKWebView] = []

        init(log: URL, onCode: @escaping (String) -> Void) {
            self.log = log
            self.onCode = onCode
        }

        /// Records which pages the sign-in visits (host and path only, never query strings,
        /// which can carry codes) so a failed sign-in can be diagnosed.
        func record(_ event: String, _ url: URL?) {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(event) \(url?.host ?? "-")\(url?.path ?? "")\n"
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: log) {
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
            } else {
                try? line.write(to: log, atomically: true, encoding: .utf8)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            record("loaded", webView.url)
            checkForCode(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            record("failed(\((error as NSError).code))", webView.url)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            record("failed(\((error as NSError).code))", webView.url)
        }

        /// The code page is plain JSON; check every page rather than one expected URL.
        private func checkForCode(in webView: WKWebView) {
            guard !delivered else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                guard let self, !self.delivered, let text = result as? String, text.contains("authorizationCode"),
                      let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                guard let code = json["authorizationCode"] as? String, !code.isEmpty else {
                    // Epic shows `"authorizationCode": null` when the session isn't signed in.
                    self.record("code-missing", webView.url)
                    return
                }
                self.delivered = true
                self.record("code-received", webView.url)
                self.onCode(code)
            }
        }

        /// "Sign in with Google/Apple/…" opens a popup; show it in a child web view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            record("popup", navigationAction.request.url)
            let popup = WKWebView(frame: webView.bounds, configuration: configuration)
            popup.customUserAgent = webView.customUserAgent
            popup.autoresizingMask = [.width, .height]
            popup.navigationDelegate = self
            popup.uiDelegate = self
            webView.addSubview(popup)
            popups.append(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            record("popup-closed", webView.url)
            webView.removeFromSuperview()
            popups.removeAll { $0 === webView }
        }
    }
}
