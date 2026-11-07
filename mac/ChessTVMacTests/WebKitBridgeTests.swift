import AppKit
import WebKit
import XCTest
import SwiftUI
@testable import ChessTV

@MainActor private final class UnhandledKeyRecorder: NSResponder {
  var keys: [UInt16] = []
  override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
}

@MainActor final class WebKitBridgeTests: XCTestCase {
  func testWebKeysDoNotReachSystemBeepAndStillAllowTyping() async throws {
    let browser = ChessBrowser()
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: BrowserView(browser: browser))
    let fallback = UnhandledKeyRecorder()
    let next = window.nextResponder
    window.nextResponder = fallback
    window.makeKeyAndOrderFront(nil)
    defer { window.nextResponder = next; window.orderOut(nil) }
    browser.webView.loadHTMLString("""
      <input id="entry"><script>
      window.keys = [];
      document.addEventListener('keydown', event => {
        keys.push(event.key);
        if (event.key === 'h') event.preventDefault();
      });
      </script>
      """, baseURL: URL(string: "https://lichess.org"))
    for _ in 0..<100 {
      if !browser.webView.isLoading { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    window.makeFirstResponder(browser.webView)
    func press(_ characters: String, code: UInt16) async throws {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
      browser.webView.keyDown(with: event)
      try await Task.sleep(for: .milliseconds(100))
    }
    for (characters, code) in [("\u{F702}", UInt16(123)), ("\u{F703}", 124), ("z", 6), ("h", 4)] {
      try await press(characters, code: code)
    }
    let keys = try await browser.webView.evaluateJavaScript("keys") as? [String]
    XCTAssertEqual(keys, ["ArrowLeft", "ArrowRight", "z", "h"])
    XCTAssertEqual(fallback.keys, [], "Unhandled web keys must not reach AppKit's alert-sound fallback")
    _ = try await browser.webView.evaluateJavaScript("document.querySelector('input').focus()")
    try await press("a", code: 0)
    try await press("b", code: 11)
    try await press("\u{F702}", code: 123)
    try await press("c", code: 8)
    let typed = try await browser.webView.evaluateJavaScript("document.querySelector('input').value") as? String
    XCTAssertEqual(typed, "acb")
  }

  func testMuteStopsExistingAndNewWebAudioAcrossNavigation() async throws {
    let saved = UserDefaults.standard.object(forKey: "webViewSoundsMuted")
    defer { UserDefaults.standard.set(saved, forKey: "webViewSoundsMuted") }
    let browser = ChessBrowser()
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = browser.webView
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    func load() async throws {
      browser.webView.loadHTMLString("<p>Audio fixture</p>", baseURL: URL(string: "https://lichess.org"))
      for _ in 0..<100 {
        if !browser.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    func start(_ name: String) async throws {
      _ = try await browser.webView.evaluateJavaScript("""
        window.\(name) = new AudioContext();
        var oscillator = \(name).createOscillator();
        var gain = \(name).createGain(); gain.gain.value = 0;
        oscillator.connect(gain).connect(\(name).destination); oscillator.start();
        \(name).resume(); void 0;
        """)
      try await Task.sleep(for: .milliseconds(200))
    }
    func state(_ name: String) async throws -> String? {
      try await browser.webView.evaluateJavaScript("\(name).state") as? String
    }
    try await load()
    if browser.soundsMuted { browser.toggleSoundsMuted() }
    try await start("existing")
    let playing = try await state("existing")
    XCTAssertEqual(playing, "running")
    browser.toggleSoundsMuted()
    try await Task.sleep(for: .milliseconds(200))
    let muted = try await state("existing")
    XCTAssertTrue(["suspended", "interrupted"].contains(muted ?? ""), "Existing Web Audio must stop when muted")
    try await start("later")
    let later = try await state("later")
    XCTAssertEqual(later, "suspended", "New Web Audio must stay muted")
    browser.toggleSoundsMuted()
    try await Task.sleep(for: .milliseconds(200))
    let existingResumed = try await state("existing")
    let laterResumed = try await state("later")
    XCTAssertEqual(existingResumed, "running")
    XCTAssertEqual(laterResumed, "running")
    browser.toggleSoundsMuted()
    try await load()
    try await start("navigated")
    let navigated = try await state("navigated")
    XCTAssertEqual(navigated, "suspended", "Mute must survive navigation")
    browser.toggleSoundsMuted()
    try await Task.sleep(for: .milliseconds(200))
    let resumed = try await state("navigated")
    XCTAssertEqual(resumed, "running", "Unmute must restore playback")
  }

  func testMuteBlocksMediaElementsCreatedWhileMuted() async throws {
    let saved = UserDefaults.standard.object(forKey: "webViewSoundsMuted")
    defer { UserDefaults.standard.set(saved, forKey: "webViewSoundsMuted") }
    let configuration = WKWebViewConfiguration()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    let browser = ChessBrowser(configuration: configuration)
    if !browser.soundsMuted { browser.toggleSoundsMuted() }
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = browser.webView
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    browser.webView.loadHTMLString("<p>Media fixture</p>", baseURL: URL(string: "https://lichess.org"))
    for _ in 0..<100 {
      if !browser.webView.isLoading { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    // A silent PCM WAV exercises real HTML media playback without making test noise.
    _ = try await browser.webView.evaluateJavaScript("""
      var bytes = new Uint8Array(44 + 8000 * 10);
      var header = new DataView(bytes.buffer);
      function text(at, value) { for (let i = 0; i < value.length; i++) bytes[at+i] = value.charCodeAt(i); }
      text(0, 'RIFF'); header.setUint32(4, bytes.length - 8, true); text(8, 'WAVE'); text(12, 'fmt ');
      header.setUint32(16, 16, true); header.setUint16(20, 1, true); header.setUint16(22, 1, true);
      header.setUint32(24, 8000, true); header.setUint32(28, 8000, true);
      header.setUint16(32, 1, true); header.setUint16(34, 8, true);
      text(36, 'data'); header.setUint32(40, bytes.length - 44, true); bytes.fill(128, 44);
      window.audio = new Audio(URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' })));
      audio.loop = true; document.body.append(audio); audio.play().catch(() => {}); void 0;
      """)
    try await Task.sleep(for: .milliseconds(300))
    let mutedTime = try await browser.webView.evaluateJavaScript("audio.currentTime") as? Double
    XCTAssertEqual(mutedTime, 0)
    browser.toggleSoundsMuted()
    try await Task.sleep(for: .milliseconds(200))
    _ = try await browser.webView.evaluateJavaScript("audio.play().catch(e => window.playError = e.message); void 0")
    try await Task.sleep(for: .milliseconds(300))
    let currentTime = try await browser.webView.evaluateJavaScript("audio.currentTime") as? Double
    let playingTime = try XCTUnwrap(currentTime)
    let playback = try await browser.webView.evaluateJavaScript("JSON.stringify({ready: audio.readyState, paused: audio.paused, error: audio.error?.message, playError: window.playError})")
    XCTAssertGreaterThan(playingTime, 0, "\(playback)")
    browser.toggleSoundsMuted()
    try await Task.sleep(for: .milliseconds(100))
    let stoppedTime = try await browser.webView.evaluateJavaScript("audio.currentTime") as? Double
    try await Task.sleep(for: .milliseconds(200))
    let stillStoppedTime = try await browser.webView.evaluateJavaScript("audio.currentTime") as? Double
    XCTAssertEqual(stoppedTime, stillStoppedTime)
  }

  func testBundledAdapterIsIsolatedAndObservesRealWebKitDOM() async throws {
    try await verifyMove(background: nil)
  }

  func testBundledAdapterMovesWhileWindowIsOrderedOut() async throws {
    try await verifyMove(background: "hidden")
  }

  func testBundledAdapterMovesWhileWindowIsMinimized() async throws {
    try await verifyMove(background: "minimized")
  }

  func testVoiceMovesWithoutTVWhileHidden() async throws {
    try await verifyMove(background: "hidden", voice: true)
  }

  func testVoiceMovesWithoutTVWhileMinimized() async throws {
    try await verifyMove(background: "minimized", voice: true)
  }

  private func verifyMove(background: String?, voice: Bool = false) async throws {
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
    if voice {
      let positionReply = try await browser.call(["kind": "voice-position"])
      let position = try XCTUnwrap(positionReply.voicePosition)
      XCTAssertEqual(positionReply.voiceCandidates?.count, 20)
      let resolution = try await browser.call(["kind": "voice-resolve", "text": "move garbled square",
        "alternatives": ["E4. Move pon E4."], "position": position])
      XCTAssertEqual(resolution.voiceResolution?.state, "resolved")
      let move = try XCTUnwrap(resolution.voiceResolution?.move)
      let result = try await browser.call(["kind": "voice-selected-move", "move": move,
        "position": position, "commandId": UUID().uuidString])
      XCTAssertTrue(result.messages.contains { if case .outcome(let value) = $0 {
        return value.outcome == .observedComplete
      }; return false })
      return
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
