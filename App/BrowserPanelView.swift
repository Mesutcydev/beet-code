import AppKit
import SwiftUI
import WebKit

/// Docked panel hosting the agent-controlled browser. The WKWebView lives on
/// `BrowserController.shared` (a single instance the agent tools drive); this
/// view hosts it via NSViewRepresentable and provides the URL bar chrome.
struct BrowserPanelView: View {
    var onClose: () -> Void

    @ObservedObject private var controller = BrowserController.shared
    @State private var urlDraft = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Chrome row: back/forward/reload + URL field + close.
            HStack(spacing: 6) {
                Button { controller.back() } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                .disabled(!controller.webView.canGoBack)

                Button { controller.forward() } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Forward")
                .disabled(!controller.webView.canGoForward)

                Button { controller.reload() } label: {
                    if controller.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Reload")

                TextField("Enter a URL or let the agent open one…", text: $urlDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .focused($urlFocused)
                    .layoutPriority(1)
                    .onSubmit {
                        let target = urlDraft.trimmingCharacters(in: .whitespaces)
                        if !target.isEmpty {
                            do {
                                _ = try controller.open(target)
                                urlFocused = false
                            } catch {
                                controller.lastError = error.localizedDescription
                            }
                        }
                    }

                PanelCloseButton(action: onClose)
            }
            .padding(10)

            Divider()

            // The hosted web view.
            BrowserWebViewHost()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status strip.
            HStack(spacing: 6) {
                if let error = controller.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                } else if controller.isLoading {
                    ProgressView().controlSize(.mini)
                    Text("Loading \(controller.currentURL?.host ?? "")…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(controller.title.isEmpty
                         ? (controller.currentURL?.absoluteString ?? "No page loaded")
                         : controller.title)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("browser_* tools")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .lfGlass()
        .onAppear {
            if let current = controller.currentURL {
                urlDraft = current.absoluteString
            }
        }
        .onChange(of: controller.currentURL) { _, newValue in
            if !urlFocused, let newValue {
                urlDraft = newValue.absoluteString
            }
        }
    }
}

/// Hosts the shared WKWebView inside SwiftUI. The web view instance is owned
/// by BrowserController; this representable wraps it in a container view.
/// (Returning the web view itself from makeNSView made updateNSView yank it
/// OUT of SwiftUI's hierarchy into an offscreen container — a blank panel.)
private struct BrowserWebViewHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = context.coordinator.container
        let webView = BrowserController.shared.webView
        webView.navigationDelegate = context.coordinator
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Reparent if a previous panel still owns the shared web view.
        let webView = BrowserController.shared.webView
        if webView.superview !== nsView {
            webView.removeFromSuperview()
            webView.frame = nsView.bounds
            webView.autoresizingMask = [.width, .height]
            nsView.addSubview(webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let container = NSView()

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            BrowserController.shared.markStarted(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.title") { [weak webView] result, _ in
                let title = (result as? String) ?? ""
                Task { @MainActor in
                    BrowserController.shared.markFinished(webView?.url, title: title)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            BrowserController.shared.markFailed(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            BrowserController.shared.markFailed(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            do {
                _ = try BrowserURLValidator.validatedURL(
                    url.absoluteString,
                    filePolicy: BrowserController.shared.navigationFilePolicy)
                decisionHandler(.allow)
            } catch {
                BrowserController.shared.markFailed(error.localizedDescription)
                decisionHandler(.cancel)
            }
        }

        /// Keep navigation inside the panel; new-window requests become
        /// same-panel loads so popups don't escape the agent's view.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                do {
                    _ = try BrowserURLValidator.validatedURL(
                        url.absoluteString,
                        filePolicy: BrowserController.shared.navigationFilePolicy)
                    webView.load(URLRequest(url: url))
                } catch {
                    BrowserController.shared.markFailed(error.localizedDescription)
                }
            }
            return nil
        }
    }
}
