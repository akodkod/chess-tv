import AppKit
import Observation
import WebKit

@MainActor @Observable final class ChessBrowser: NSObject, GamePage, WKNavigationDelegate, WKUIDelegate {
  let webView: WKWebView
  private let world = WKContentWorld.world(name: "ChessTV.Adapter")
  private(set) var documentID = UUID()
  var onInvalidate: (() -> Void)?
  var loadError: String?
  var loading = true

  override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    // Keep the adapter callable when the app is hidden or its window is minimized.
    // WebKit may still throttle page animations; moves require observed DOM confirmation.
    configuration.preferences.inactiveSchedulingPolicy = .none
    configuration.userContentController.addUserScript(WKUserScript(
      source: Self.backgroundAnimationScript, injectionTime: .atDocumentStart,
      forMainFrameOnly: true, in: .page))
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    // Keep embedded page media silent, including across navigation.
    webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    do {
      guard let url = Bundle.main.url(forResource: "adapter", withExtension: "js") else {
        throw ProtocolFailure("The bundled game adapter is missing. Rebuild the app.")
      }
      let script = try String(contentsOf: url, encoding: .utf8)
      configuration.userContentController.addUserScript(WKUserScript(source: script,
        injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
    } catch { loadError = error.localizedDescription }
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
  }

  // Chess.com commits some piece/capture DOM changes from animation callbacks.
  // WebKit suspends rAF in hidden pages even with inactiveSchedulingPolicy = .none.
  // Preserve callbacks/cancellation using timers only while hidden, without lying
  // about document visibility or exposing the isolated adapter to the page world.
  private static let backgroundAnimationScript = """
    (() => {
      if (location.origin !== 'https://www.chess.com') return;
      const request = window.requestAnimationFrame.bind(window);
      const cancel = window.cancelAnimationFrame.bind(window);
      const pending = new Map();
      let nextID = 0;
      function clear(entry) {
        if (entry.frame !== null) cancel(entry.frame);
        if (entry.timer !== null) clearTimeout(entry.timer);
        entry.frame = entry.timer = null;
      }
      function schedule(id, entry) {
        const run = timestamp => {
          if (!pending.has(id)) return;
          clear(entry);
          pending.delete(id);
          entry.callback(timestamp);
        };
        entry.frame = request(run);
        if (document.hidden) entry.timer = setTimeout(() => run(performance.now()), 16);
      }
      window.requestAnimationFrame = callback => {
        if (typeof callback !== 'function') throw new TypeError('Callback must be a function');
        const id = ++nextID;
        const entry = { callback, frame: null, timer: null };
        pending.set(id, entry);
        schedule(id, entry);
        return id;
      };
      window.cancelAnimationFrame = id => {
        const entry = pending.get(id);
        if (entry) { clear(entry); pending.delete(id); }
      };
      document.addEventListener('visibilitychange', () => {
        for (const [id, entry] of pending) { clear(entry); schedule(id, entry); }
      });
    })();
    """

  var usable: Bool {
    return !loading && loadError == nil && webView.window != nil
  }
  func home() { webView.load(URLRequest(url: URL(string: "https://www.chess.com")!)) }
  func invalidate() {
    documentID = UUID()
    onInvalidate?()
  }
  func call(_ action: [String: Any]) async throws -> AdapterReply {
    guard !loading, webView.url?.scheme == "https", webView.url?.host == "www.chess.com" else {
      throw ProtocolFailure("Open a supported Chess.com game.")
    }
    let document = documentID
    let result = try await webView.callAsyncJavaScript(
      "if (!globalThis.chessTV) throw new Error('Game adapter unavailable'); return JSON.stringify(await globalThis.chessTV.handle(action));",
      arguments: ["action": action], in: nil, contentWorld: world)
    guard document == documentID, let text = result as? String else {
      throw ProtocolFailure("The game page changed.")
    }
    guard text.utf8.count <= 262_144 else { throw ProtocolFailure("Invalid adapter response.") }
    return try JSONDecoder().decode(AdapterReply.self, from: Data(text.utf8))
  }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    loading = true
    loadError = nil
    invalidate()
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    loading = false
    loadError = error.localizedDescription
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    loading = false
    if (error as NSError).code != NSURLErrorCancelled { loadError = error.localizedDescription }
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    loading = true
    invalidate()
    loadError = "The page stopped responding. Reload to continue."
  }
  static func isChessURL(_ url: URL) -> Bool {
    url.scheme == "https" && (url.host == "chess.com" || url.host?.hasSuffix(".chess.com") == true)
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard action.targetFrame?.isMainFrame != false, let url = action.request.url else {
      decisionHandler(.allow)
      return
    }
    if Self.isChessURL(url) { decisionHandler(.allow) }
    else {
      decisionHandler(.cancel)
      if ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
    }
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = action.request.url, Self.isChessURL(url) { webView.load(action.request) }
    return nil
  }
  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    alert.runModal()
    completionHandler()
  }
  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    completionHandler(alert.runModal() == .alertFirstButtonReturn)
  }
}
