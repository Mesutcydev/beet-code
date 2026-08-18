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
                    .onSubmit {
                        let target = urlDraft.trimmingCharacters(in: .whitespaces)
                        if !target.isEmpty {
                            try? controller.open(target)
                        }
                    }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close browser panel")
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
                Spacer()
                Text("The agent can drive this page with browser_* tools")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
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
/// by BrowserController; this representable only (re)parents it, installing
/// the navigation delegate the first time.
private struct BrowserWebViewHost: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = BrowserController.shared.webView
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Reparent if a previous panel still owns it.
        if nsView.superview !== context.coordinator.container {
            nsView.removeFromSuperview()
            context.coordinator.container.addSubview(nsView)
            nsView.autoresizingMask = [.width, .height]
            nsView.frame = context.coordinator.container.bounds
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

        /// Keep navigation inside the panel; new-window requests become
        /// same-panel loads so popups don't escape the agent's view.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
