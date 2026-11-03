import AppKit
import WebKit
import XCTest
@testable import ChessTV

@MainActor final class WebKitBridgeTests: XCTestCase {
  func testBundledAdapterIsIsolatedAndObservesRealWebKitDOM() async throws {
    try await verifyMove(background: nil)
  }

  func testBundledAdapterMovesWhileWindowIsOrderedOut() async throws {
    try await verifyMove(background: "hidden")
  }

  func testBundledAdapterMovesWhileWindowIsMinimized() async throws {
    try await verifyMove(background: "minimized")
  }

  private func verifyMove(background: String?) async throws {
    let browser = ChessBrowser()
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 900),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.contentView = browser.webView
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    var pieces = ""
    for (rank, color, codes) in [(8, "b", "rnbqkbnr"), (7, "b", "pppppppp"),
      (2, "w", "pppppppp"), (1, "w", "rnbqkbnr")] {
      for (file, piece) in codes.enumerated() {
        pieces += "<div class='piece \(color)\(piece) square-\(file+1)\(rank)' style='left:\(file*80)px;top:\((8-rank)*80)px'></div>"
      }
    }
    let html = """
      <style>body{margin:0}wc-chess-board{display:block;position:relative;width:640px;height:640px}
      .piece{position:absolute;width:80px;height:80px}</style>
      <wc-chess-board id="board-play-computer">\(pieces)</wc-chess-board>
      <wc-simple-move-list board-id="board-play-computer"></wc-simple-move-list>
      <a data-user-activity-key="profile" href="https://www.chess.com/member/human">Human</a>
      <div class="player-row-component player-row-top"><div data-test-element="user-tagline-username">Bot</div></div>
      <div class="player-row-component"><div data-test-element="user-tagline-username">Human</div></div>
      <script>
      document.querySelector('wc-chess-board').addEventListener('click', event => {
        if (event.clientX === 360 && event.clientY === 360) {
          requestAnimationFrame(() => {
          const pawn = document.querySelector('.square-52');
          pawn.classList.replace('square-52','square-54'); pawn.style.top = '320px';
          document.querySelector('wc-simple-move-list').innerHTML = '<div class="main-line-row" data-whole-move-number="1"><div class="main-line-ply white-move" data-node="0-0"><span class="node-highlight-content selected">e4</span></div></div>';
          });
        }
      });
      </script>
      """
    browser.webView.loadHTMLString(html, baseURL: URL(string: "https://www.chess.com/play/computer"))
    for _ in 0..<100 {
      if !browser.loading { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertFalse(browser.loading)
    let isolated = try await browser.webView.evaluateJavaScript("typeof globalThis.chessTV") as? String
    XCTAssertEqual(isolated, "undefined")
    if let background {
      if background == "minimized" { window.miniaturize(nil) }
      else { window.orderOut(nil) }
      for _ in 0..<50 {
        if (try await browser.webView.evaluateJavaScript("document.hidden") as? Bool) == true { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      let hidden = try await browser.webView.evaluateJavaScript("document.hidden") as? Bool
      XCTAssertEqual(hidden, true)
      XCTAssertTrue(browser.usable)
    }
    let reply = try await browser.call(["kind": "sync", "generation": "web-test", "enabled": true])
    XCTAssertNil(reply.error)
    let snapshot = try XCTUnwrap(reply.messages.compactMap { message -> Snapshot? in
      if case .snapshot(let value) = message { return value }; return nil
    }.first)
    XCTAssertEqual(snapshot.board.compactMap { $0 }.count, 32)
    XCTAssertEqual(snapshot.playerColor, .white)
    let move = MoveRequest(context: snapshot.context, revision: snapshot.revision,
      commandId: "webkit-move", from: "e2", to: "e4")
    let action: [String: Any] = ["kind": "move",
      "move": try JSONSerialization.jsonObject(with: Message.move(move).encoded())]
    let moved = try await browser.call(action)
    let outcome = try XCTUnwrap(moved.messages.compactMap { message -> CommandOutcome? in
      if case .outcome(let value) = message { return value }; return nil
    }.first)
    XCTAssertEqual(outcome.outcome, .observedComplete, outcome.reason ?? "")
    let repeated = try await browser.call(action)
    XCTAssertTrue(repeated.messages.contains(.outcome(outcome)))
  }
}
