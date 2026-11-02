import AVFoundation
import SwiftUI
import XCTest

@testable import ChessTV

final class MemoryCredentials: CredentialStoring {
  var value: DeviceCredential? = .init(
    pairingId: "pair", credential: String(repeating: "a", count: 64))
  var failSave = false
  var failRemove = false
  func load() throws -> DeviceCredential? { value }
  func save(_ value: DeviceCredential) throws {
    if failSave { throw ProtocolFailure("Keychain unavailable") }
    self.value = value
  }
  func remove() throws {
    if failRemove { throw ProtocolFailure("Keychain unavailable") }
    value = nil
  }
}
@MainActor final class FakeSocket: RelayConnecting {
  var onMessage: ((Message) -> Void)?
  var onClose: ((Int, String) -> Void)?
  var sent: [Message] = []
  var connects = 0
  var failSend = false
  func connect(url: URL, credential: String) { connects += 1 }
  func send(_ message: Message) async throws {
    if failSend { throw ProtocolFailure("Offline") }
    sent.append(message)
  }
  func disconnect() {}
}
@MainActor final class FakeBoardSounds: BoardSoundPlaying {
  var played: [BoardSound] = []
  var stops = 0
  func play(_ sound: BoardSound) { played.append(sound) }
  func stop() { stops += 1 }
}
@MainActor final class SessionTests: XCTestCase {
  var socket: FakeSocket!
  var sounds: FakeBoardSounds!
  var session: TVSession!
  var time = 100.0
  override func setUp() async throws {
    time = 100
    socket = FakeSocket()
    sounds = FakeBoardSounds()
    session = TVSession(
      configuration: try RelayConfiguration("https://example.com"), store: MemoryCredentials(),
      socket: socket, sounds: sounds, uptime: { [unowned self] in self.time })
    session.setActive(true)
    var auth = Message(type: "authenticated")
    auth.role = "tv"
    auth.pairingId = "pair"
    session.receive(auth)
  }
  override func tearDown() async throws {
    session.setActive(false)
    session = nil
    socket = nil
  }
  func state(generation: String = "generation-1", game: String? = "game-1") {
    var message = Message(type: "session")
    message.generation = generation
    message.gameId = game
    message.peerConnected = true
    session.receive(message)
  }
  func available(generation: String = "generation-1") {
    var message = Message(type: "status")
    message.generation = generation
    message.gameId = "game-1"
    message.available = true
    session.receive(message)
  }
  func ready() throws {
    state()
    session.receive(try ProtocolTests.fixture())
    available()
  }
  func testMoveReviewKeepsLiveUpdatesAndPreventsSubmission() throws {
    state()
    let initial = try soundPosition()
    session.receive(initial)
    available()
    XCTAssertFalse(session.canGoBack)
    let next = pawnMove(initial)
    session.receive(next)
    session.receive(next)
    session.previousMove()
    XCTAssertEqual(session.displayedSnapshot?.board, initial.board)
    XCTAssertFalse(session.canGoBack)
    XCTAssertFalse(session.canMove)
    session.submit(from: 52, to: 36)
    XCTAssertNil(session.pending)
    var reply = next
    reply.revision! += 1
    reply.board![4] = nil
    reply.board![3] = "k"
    reply.turn = .white
    session.receive(reply)
    XCTAssertEqual(session.displayedSnapshot?.board, initial.board)
    XCTAssertEqual(session.snapshot?.board, reply.board)
    session.nextMove()
    XCTAssertEqual(session.displayedSnapshot?.board, next.board)
    XCTAssertTrue(session.isReviewing)
    session.nextMove()
    XCTAssertEqual(session.displayedSnapshot?.board, reply.board)
    XCTAssertFalse(session.isReviewing)
    XCTAssertFalse(session.canGoForward)
    XCTAssertTrue(session.canMove)
    XCTAssertEqual(sounds.played, [.move])
  }
  func testOpponentMoveHighlightFollowsHistoryAndClearsOnReplyAndReconnect() throws {
    state()
    let initial = try soundPosition()
    session.receive(initial)
    XCTAssertNil(session.displayedOpponentMove)
    let ownMove = pawnMove(initial)
    session.receive(ownMove)
    XCTAssertNil(session.displayedOpponentMove)
    var opponent = ownMove
    opponent.revision! += 1
    opponent.board![4] = nil
    opponent.board![3] = "k"
    opponent.turn = .white
    session.receive(opponent)
    XCTAssertEqual(session.displayedOpponentMove?.from, 4)
    XCTAssertEqual(session.displayedOpponentMove?.to, 3)
    session.receive(opponent)
    XCTAssertEqual(session.displayedOpponentMove?.to, 3)
    var reply = opponent
    reply.revision! += 1
    reply.board![36] = nil
    reply.board![28] = "P"
    reply.turn = .black
    session.receive(reply)
    XCTAssertNil(session.displayedOpponentMove)
    session.previousMove()
    XCTAssertEqual(session.displayedOpponentMove?.to, 3)
    session.previousMove()
    XCTAssertNil(session.displayedOpponentMove)
    session.nextMove()
    XCTAssertEqual(session.displayedOpponentMove?.to, 3)
    state()
    XCTAssertNil(session.displayedOpponentMove)
    session.receive(opponent)
    XCTAssertNil(session.displayedOpponentMove)
  }
  func testOpponentHighlightsSpecialMovesAndBothOrientations() throws {
    let cases: [(PieceColor, [Int: String], [Int: String], Int, Int)] = [
      (.white, [4: "k", 7: "r"], [6: "k", 5: "r"], 4, 6),
      (.black, [60: "K", 56: "R"], [58: "K", 59: "R"], 60, 58),
      (.white, [48: "p"], [56: "q"], 48, 56),
      (.black, [28: "P", 27: "p"], [19: "P"], 28, 19),
      (.white, [27: "p", 36: "N"], [36: "p"], 27, 36),
    ]
    for (player, before, after, from, to) in cases {
      state()
      var initial = try soundPosition()
      initial.playerColor = player
      initial.turn = player == .white ? .black : .white
      initial.board = Array(repeating: nil, count: 64)
      for (square, piece) in before { initial.board![square] = piece }
      session.receive(initial)
      var next = initial
      next.revision! += 1
      next.turn = player
      next.board = Array(repeating: nil, count: 64)
      for (square, piece) in after { next.board![square] = piece }
      session.receive(next)
      XCTAssertEqual(session.displayedOpponentMove?.from, from)
      XCTAssertEqual(session.displayedOpponentMove?.to, to)
      var gap = next
      gap.revision! += 1
      gap.board = Array(repeating: nil, count: 64)
      session.receive(gap)
      XCTAssertNil(session.displayedOpponentMove)
    }
  }
  func testReviewResetsOnResynchronizationAndPositionGaps() throws {
    state()
    let initial = try soundPosition()
    session.receive(initial)
    session.receive(pawnMove(initial))
    session.previousMove()
    state(generation: "new")
    var baseline = initial
    baseline.generation = "new"
    session.receive(baseline)
    XCTAssertFalse(session.isReviewing)
    XCTAssertFalse(session.canGoBack)
    session.receive(pawnMove(baseline))
    var skipped = baseline
    skipped.revision = 10
    skipped.board![52] = nil
    skipped.board![28] = "P"
    session.receive(skipped)
    XCTAssertFalse(session.canGoBack)
    XCTAssertEqual(session.displayedSnapshot?.board, skipped.board)
  }
  func testFinalPositionAndResultArriveBeforeUnavailableStatus() throws {
    try ready()
    var final = try ProtocolTests.fixture()
    final.revision = (final.revision ?? 0) + 1
    final.board?[12] = "Q"
    final.board?[26] = nil
    final.result = .whiteWon
    final.resultReason = .checkmate
    final.legalMoves = []
    session.receive(final)
    var status = Message(type: "status")
    status.gameId = final.gameId
    status.generation = final.generation
    status.available = false
    status.reason = "Game finished"
    session.receive(status)
    XCTAssertEqual(session.snapshot, final)
    XCTAssertFalse(session.canMove)
    XCTAssertNil(session.gameplayWarning)
  }

  func outcome(_ result: String, command: String? = nil) {
    var message = Message(type: "outcome")
    message.generation = "generation-1"
    message.gameId = "game-1"
    message.commandId = command ?? session.pending?.commandId
    message.outcome = result
    session.receive(message)
  }
  private func soundPosition() throws -> Message {
    var position = try ProtocolTests.fixture()
    position.board = Array(repeating: nil, count: 64)
    position.board![60] = "K"
    position.board![4] = "k"
    position.board![52] = "P"
    position.turn = .white
    position.result = nil
    return position
  }
  private func pawnMove(_ initial: Message) -> Message {
    var next = initial
    next.revision! += 1
    next.board![52] = nil
    next.board![36] = "P"
    next.turn = .black
    return next
  }
  func testSoundsOnlyForObservedMovesAndNotDuplicateSnapshots() throws {
    state()
    let initial = try soundPosition()
    session.receive(initial)
    XCTAssertTrue(sounds.played.isEmpty)
    let next = pawnMove(initial)
    session.receive(next)
    session.receive(next)
    var clockUpdate = next
    clockUpdate.clocks?.white.remainingMs = 12_000
    session.receive(clockUpdate)
    XCTAssertEqual(sounds.played, [.move])
  }
  func testCheckSoundOverridesMoveAndCaptureAndHonorsMute() throws {
    for capture in [false, true] {
      state()
      var initial = try soundPosition()
      initial.board![52] = nil
      initial.board![4] = nil
      initial.board![0] = "k"
      initial.board![57] = "R"
      if capture { initial.board![1] = "n" }
      session.receive(initial)
      let count = sounds.played.count
      var checked = initial
      checked.revision! += 1
      checked.board![57] = nil
      checked.board![1] = "R"
      checked.turn = .black
      checked.checkSquare = "a8"
      session.receive(checked)
      session.receive(checked)
      XCTAssertEqual(Array(sounds.played.dropFirst(count)), [.check])
      state()
      session.receive(checked)
      XCTAssertEqual(sounds.played.count, count + 1)
      session.setSoundsEnabled(false)
      state()
      session.receive(initial)
      session.receive(checked)
      XCTAssertEqual(sounds.played.count, count + 1)
      session.setSoundsEnabled(true)
    }
  }
  func testResultSoundsForBothColorsWithoutBoardMoveAndOnlyOnce() throws {
    for player in [PieceColor.white, .black] {
      for result in [GameResult.whiteWon, .blackWon] {
        state()
        var initial = try soundPosition()
        initial.playerColor = player
        session.receive(initial)
        let count = sounds.played.count
        var ended = initial
        ended.revision! += 1
        ended.result = result
        ended.resultReason = .timeout
        session.receive(ended)
        session.receive(ended)
        let expected: BoardSound = (result == .whiteWon) == (player == .white) ? .win : .lose
        XCTAssertEqual(Array(sounds.played.dropFirst(count)), [expected])
        state()
        session.receive(ended)
        XCTAssertEqual(sounds.played.count, count + 1)
      }
    }
  }
  func testResultSoundOverridesCheckAndHonorsMuteAndReview() throws {
    for mode in ["live", "muted", "review"] {
      state()
      let initial = try soundPosition()
      session.receive(initial)
      let moved = pawnMove(initial)
      session.receive(moved)
      if mode == "muted" { session.setSoundsEnabled(false) }
      if mode == "review" { session.previousMove() }
      let count = sounds.played.count
      var ended = moved
      ended.revision! += 1
      ended.board![4] = nil
      ended.board![12] = "k"
      ended.turn = .white
      ended.checkSquare = "e1"
      ended.result = .blackWon
      ended.resultReason = .checkmate
      session.receive(ended)
      let expected: [BoardSound] = mode == "live" ? [.lose] : []
      XCTAssertEqual(Array(sounds.played.dropFirst(count)), expected)
      session.setSoundsEnabled(true)
    }
  }
  func testDrawDoesNotPlayWinOrLossSound() throws {
    state()
    let initial = try soundPosition()
    session.receive(initial)
    var ended = initial
    ended.revision! += 1
    ended.result = .draw
    session.receive(ended)
    XCTAssertTrue(sounds.played.isEmpty)
  }
  func testAllSoundAssetsDecode() throws {
    for sound in BoardSound.allCases {
      let url = try XCTUnwrap(Bundle.main.url(
        forResource: sound.rawValue, withExtension: sound.fileExtension))
      let player = try AVAudioPlayer(contentsOf: url)
      XCTAssertGreaterThan(player.duration, 0)
    }
  }
  func testGameplayHidesRoutineStatusButPreservesWarnings() throws {
    try ready()
    XCTAssertNil(session.gameplayWarning)
    session.submit(from: 60, to: 59)
    XCTAssertNotNil(session.pending)
    XCTAssertFalse(session.canMove)
    XCTAssertNil(session.gameplayWarning)
    time += 6
    session.tick()
    XCTAssertTrue(session.gameplayWarning?.contains("Checking move") == true)
    outcome("rejected")
    XCTAssertEqual(session.moveNotice, "Move rejected.")
    session.closed(code: 4001, reason: "Replaced")
    XCTAssertTrue(session.gameplayWarning?.contains("replaced") == true)
  }
  func testRejectsMetadataChangeWithoutRevision() throws {
    try ready()
    var changed = try ProtocolTests.fixture()
    changed.checkSquare = "e1"
    session.receive(changed)
    XCTAssertTrue(session.needsReconnect)
  }
  func testCaptureSoundAndMute() throws {
    state()
    var initial = try soundPosition()
    initial.board![43] = "p"
    session.receive(initial)
    var next = initial
    next.revision! += 1
    next.board![52] = nil
    next.board![43] = "P"
    next.turn = .black
    session.receive(next)
    XCTAssertEqual(sounds.played, [.capture])
    session.setSoundsEnabled(false)
    let stops = sounds.stops
    state()
    session.receive(initial)
    session.receive(pawnMove(initial))
    XCTAssertEqual(sounds.played, [.capture])
    XCTAssertGreaterThan(stops, 0)
  }
  func testSoundBaselineResetsAfterSessionButLongThinkStillPlays() throws {
    state()
    let initial = try soundPosition()
    session.receive(initial)
    state()
    session.receive(pawnMove(initial))
    XCTAssertTrue(sounds.played.isEmpty)
    state()
    session.receive(initial)
    time += 6
    session.receive(pawnMove(initial))
    XCTAssertEqual(sounds.played, [.move])
  }
  func testPresentationEpochChangesOnSynchronizationButNotSnapshots() throws {
    let before = session.presentationEpoch
    state()
    XCTAssertGreaterThan(session.presentationEpoch, before)
    let waiting = session.presentationEpoch
    let initial = try soundPosition()
    session.receive(initial)
    XCTAssertGreaterThan(session.presentationEpoch, waiting)
    let synchronized = session.presentationEpoch
    session.receive(pawnMove(initial))
    XCTAssertEqual(session.presentationEpoch, synchronized)
    session.reconnect()
    XCTAssertGreaterThan(session.presentationEpoch, synchronized)
  }
  func testBundledChessThemeAndAudioDecode() throws {
    let bundle = Bundle(for: TVSession.self)
    for color in ["w", "b"] {
      for piece in ["p", "n", "b", "r", "q", "k"] {
        let name = "chess-\(color)\(piece)"
        let image = try XCTUnwrap(UIImage(named: name, in: bundle, compatibleWith: nil), name)
        XCTAssertGreaterThan(image.size.width, 0, name)
        XCTAssertGreaterThan(image.size.height, 0, name)
      }
    }
    XCTAssertNotNil(UIImage(named: "chess-walnut", in: bundle, compatibleWith: nil))
    for name in ["move-self", "capture", "move-check"] {
      let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "mp3"), name)
      let player = try AVAudioPlayer(contentsOf: url)
      XCTAssertGreaterThan(player.duration, 0, name)
      XCTAssertTrue(player.prepareToPlay(), name)
    }
  }
  func testAmbiguousMoveJumpAndOutcomesAreSilent() throws {
    state()
    var initial = try soundPosition()
    initial.board![12] = "p"
    session.receive(initial)
    var skipped = pawnMove(initial)
    skipped.board![12] = nil
    skipped.board![28] = "p"
    skipped.turn = .white
    skipped.revision! += 1
    session.receive(skipped)
    outcome("observed-complete", command: "unrelated")
    XCTAssertTrue(sounds.played.isEmpty)
  }
  func testWhiteBoardFocusAndSnapshotStability() async throws {
    try await checkBoardFocus(color: .white)
  }
  func testBlackBoardFocusAndSnapshotStability() async throws {
    try await checkBoardFocus(color: .black)
  }
  private func checkBoardFocus(color: PieceColor) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousWindow = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    let host = BoardFocusHostingController(rootView: ContentView(session: session))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previousWindow?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(300))
    let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
    let connection = try XCTUnwrap(system.focusedItem)
    XCTAssertFalse(host.isBoardSquare(connection))
    state()
    var snapshot = try ProtocolTests.fixture()
    snapshot.playerColor = color
    snapshot.turn = color
    session.receive(snapshot)
    available()
    try await Task.sleep(for: .milliseconds(500))
    let square = try XCTUnwrap(system.focusedItem)
    XCTAssertTrue(host.isBoardSquare(square), "Board focus must select silent feedback")
    XCTAssertFalse(square === connection, "The arriving board must take focus from Connection")
    var candidates: [ObjectIdentifier: any UIFocusItem] = [:]
    var visited: Set<ObjectIdentifier> = []
    func collectFocusItems(_ environment: any UIFocusEnvironment) {
      guard visited.insert(ObjectIdentifier(environment)).inserted else { return }
      if let item = environment as? any UIFocusItem, item.canBecomeFocused {
        candidates[ObjectIdentifier(item)] = item
      }
      environment.preferredFocusEnvironments.forEach(collectFocusItems)
      if let container = environment.focusItemContainer {
        for item in container.focusItems(
          in: CGRect(x: -10000, y: -10000, width: 20000, height: 20000))
        {
          collectFocusItems(item)
        }
      }
      if let view = environment as? UIView { view.subviews.forEach(collectFocusItems) }
    }
    collectFocusItems(window)
    XCTAssertEqual(
      candidates.count, 66, "Connection, Settings and all 64 squares must be focusable")
    XCTAssertNotNil(candidates[ObjectIdentifier(square)])
    snapshot.revision! += 1
    session.receive(snapshot)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(system.focusedItem === square, "Snapshots must preserve the focused square")
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "Board focus - \(color.rawValue)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testBoardRenderingForVisualInspection() throws {
    guard ProcessInfo.processInfo.environment["CHESS_TV_RENDER"] == "1" else {
      throw XCTSkip(
        "Enable CHESS_TV_RENDER=1 for static board renders; remote focus requires a live view.")
    }
    try ready()
    var position = try ProtocolTests.fixture()
    position.revision = 2
    position.board =
      Array("rnbqkbnrpppppppp").map(String.init) + Array(repeating: nil, count: 32)
      + Array("PPPPPPPPRNBQKBNR").map(String.init)
    session.receive(position)
    for color in [PieceColor.white, .black] {
      position.playerColor = color
      position.turn = color
      position.checkSquare = color == .white ? "e1" : "e8"
      position.revision! += 1
      session.receive(position)
      available()
      let view = ContentView(session: session)
        .padding(60).frame(width: 1920, height: 1080)
        .background(Color.black).environment(\.colorScheme, .dark)
      let renderer = ImageRenderer(content: view)
      let image = try XCTUnwrap(renderer.uiImage)
      let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      let url = directory.appendingPathComponent("Board-\(color.rawValue).png")
      try XCTUnwrap(image.pngData()).write(to: url)
      print("Board rendering: \(url.path)")
    }
    let markers = HStack(spacing: 0) {
      ForEach([false, true], id: \.self) { capture in
        ZStack {
          Color(red: 0.65, green: 0.45, blue: 0.28)
          LegalMoveMarker(size: 160, capture: capture)
          if capture { Image("chess-bn").resizable().scaledToFit() }
        }.frame(width: 160, height: 160)
      }
    }
    let renderer = ImageRenderer(content: markers)
    let image = try XCTUnwrap(renderer.uiImage)
    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let url = directory.appendingPathComponent("Move-markers.png")
    try XCTUnwrap(image.pngData()).write(to: url)
    print("Move markers rendering: \(url.path)")
  }
  func testFailedSubmissionIsNotReplayedOnReconnect() async throws {
    try ready()
    socket.failSend = true
    session.submit(from: 60, to: 52)
    await Task.yield()
    await Task.yield()
    XCTAssertNotNil(session.pending)
    XCTAssertFalse(session.canMove)
    socket.failSend = false
    session.reconnect()
    XCTAssertNotNil(session.pending)
    XCTAssertEqual(socket.sent.filter { $0.type == "move" }.count, 0)
  }
  func testFreshSnapshotAndStatusRequiredInEitherOrder() throws {
    state()
    available()
    XCTAssertFalse(session.canMove)
    session.receive(try ProtocolTests.fixture())
    XCTAssertTrue(session.canMove)
    state(generation: "new")
    XCTAssertFalse(session.canMove)
    session.receive(try ProtocolTests.fixture())
    available()
    XCTAssertFalse(session.canMove)
    var fresh = try ProtocolTests.fixture()
    fresh.generation = "new"
    session.receive(fresh)
    XCTAssertFalse(session.canMove)
    available(generation: "new")
    XCTAssertTrue(session.canMove)
  }
  func testOnePendingMoveTimeoutAndDefinitiveOutcome() async throws {
    try ready()
    session.submit(from: 60, to: 52)
    let id = session.pending?.commandId
    session.submit(from: 60, to: 51)
    XCTAssertEqual(session.pending?.commandId, id)
    time += 5
    session.tick()
    XCTAssertTrue(session.checkingMove)
    outcome("uncertain")
    XCTAssertNotNil(session.pending)
    outcome("observed-complete", command: "other")
    XCTAssertNotNil(session.pending)
    var changed = try ProtocolTests.fixture()
    changed.revision = 2
    changed.board?[60] = nil
    changed.board?[52] = "K"
    session.receive(changed)
    XCTAssertNotNil(session.pending)
    outcome("observed-complete")
    XCTAssertNil(session.pending)
    XCTAssertFalse(session.canMove)
    available()
    XCTAssertTrue(session.canMove)
    await Task.yield()
    XCTAssertEqual(socket.sent.filter { $0.type == "move" }.count, 1)
    XCTAssertGreaterThanOrEqual(socket.sent.filter { $0.type == "snapshot-request" }.count, 2)
  }
  func testInterruptedMoveNeedsDetachAndFreshAvailableSession() throws {
    try ready()
    session.submit(from: 60, to: 52)
    state(generation: "new")
    var fresh = try ProtocolTests.fixture()
    fresh.generation = "new"
    session.receive(fresh)
    available(generation: "new")
    XCTAssertNotNil(session.pending)
    XCTAssertFalse(session.canMove)
    state(generation: "detached", game: nil)
    state(generation: "reattached")
    fresh.generation = "reattached"
    session.receive(fresh)
    available(generation: "reattached")
    XCTAssertNil(session.pending)
    XCTAssertTrue(session.canMove)
  }
  func testStalenessSuspensionAndReplacementDisableMoves() throws {
    try ready()
    time += 6
    session.tick()
    XCTAssertFalse(session.canMove)
    XCTAssertTrue(session.clocksStale)
    session.receive(try ProtocolTests.fixture())
    available()
    XCTAssertTrue(session.canMove)
    session.setActive(false)
    XCTAssertFalse(session.canMove)
    XCTAssertTrue(session.clocksStale)
    session.setActive(true)
    XCTAssertFalse(session.canMove)
    session.closed(code: 4001, reason: "Replaced")
    XCTAssertTrue(session.needsReconnect)
    let before = socket.connects
    session.reconnect()
    XCTAssertEqual(socket.connects, before + 1)
  }
  func testRoutingErrorDoesNotRetryIntoAnErrorLoop() async throws {
    try ready()
    await Task.yield()
    let count = socket.sent.count
    var error = Message(type: "error")
    error.code = "peer_unavailable"
    error.message = "Extension offline"
    session.receive(error)
    await Task.yield()
    XCTAssertEqual(socket.sent.count, count)
    XCTAssertFalse(session.canMove)
    XCTAssertTrue(session.clocksStale)
  }
  func testOldRevisionAndWrongGameIgnored() throws {
    try ready()
    var message = try ProtocolTests.fixture()
    message.revision = 0
    message.board?[60] = nil
    session.receive(message)
    XCTAssertEqual(session.snapshot?.revision, 1)
    message.revision = 9
    message.gameId = "other"
    session.receive(message)
    XCTAssertEqual(session.snapshot?.revision, 1)
  }
  func testMovePreviewIsImmediateAndRejectionRestoresConfirmedBoard() throws {
    try ready()
    let original = session.snapshot?.board
    session.submit(from: 60, to: 52)
    XCTAssertEqual(session.snapshot?.board, original)
    XCTAssertNil(session.displayedSnapshot?.board?[60])
    XCTAssertEqual(session.displayedSnapshot?.board?[52], "K")
    XCTAssertFalse(session.canMove)
    XCTAssertFalse(session.canGoBack, "Preview must not enter confirmed history")
    XCTAssertTrue(sounds.played.isEmpty)
    outcome("rejected")
    XCTAssertEqual(session.displayedSnapshot?.board, original)
    XCTAssertNil(session.pending)
    XCTAssertNotNil(session.moveNotice)
    var ended = try ProtocolTests.fixture()
    ended.revision = 2
    ended.result = .draw
    session.receive(ended)
    available()
    XCTAssertFalse(session.canMove)
  }
  func testConfirmationPreservesPreviewWithoutReplayingTransition() throws {
    try ready()
    let original = try XCTUnwrap(session.snapshot)
    session.submit(from: 60, to: 52)
    let preview = try XCTUnwrap(session.displayedSnapshot)
    XCTAssertNotNil(BoardTransition.between(original, preview))
    session.receive(original)
    XCTAssertEqual(session.displayedSnapshot, preview, "Clock refresh must not roll back the move")
    outcome("observed-complete")
    XCTAssertEqual(session.displayedSnapshot, preview, "Outcome precedes the confirming snapshot")
    session.receive(preview)
    XCTAssertEqual(session.displayedSnapshot, preview)
    XCTAssertNil(BoardTransition.presentationBetween(preview, session.displayedSnapshot!))
    XCTAssertTrue(session.canGoBack)
    XCTAssertEqual(sounds.played, [.move])
    session.previousMove()
    XCTAssertEqual(session.displayedSnapshot?.board, original.board)
  }
  func testPreviewAcceptsFastOpponentReplyAndDifferentAuthoritativePosition() throws {
    for fastReply in [false, true] {
      try ready()
      let original = try XCTUnwrap(session.snapshot)
      session.submit(from: 60, to: 52)
      var confirmed = fastReply ? try XCTUnwrap(session.displayedSnapshot) : original
      confirmed.revision = 3
      if fastReply {
        confirmed.board?[0] = nil
        confirmed.board?[8] = "r"
        confirmed.turn = .white
      }
      session.receive(confirmed)
      XCTAssertEqual(session.displayedSnapshot, confirmed)
      outcome("observed-complete")
      XCTAssertEqual(session.displayedSnapshot, confirmed)
    }
  }
  private func assertPreviewClears(_ interrupt: () -> Void) throws {
    try ready()
    let original = session.snapshot
    session.submit(from: 60, to: 52)
    XCTAssertNotEqual(session.displayedSnapshot?.board, original?.board)
    interrupt()
    XCTAssertEqual(session.displayedSnapshot, original)
    XCTAssertFalse(session.canMove)
  }
  func testPreviewClearsOnUncertainty() throws {
    try assertPreviewClears { outcome("uncertain") }
  }
  func testPreviewClearsOnTimeout() throws {
    try assertPreviewClears { time += 5; session.tick() }
  }
  func testPreviewClearsOnDisconnect() throws {
    try assertPreviewClears { session.closed(code: 1006, reason: "Offline") }
  }
  func testPreviewClearsOnSessionChange() throws {
    try assertPreviewClears { state(generation: "new-generation") }
  }
  func testPromotionsRequireExplicitChoice() throws {
    try ready()
    var board = try ProtocolTests.fixture()
    board.revision = 2
    board.board?[8] = "P"
    session.receive(board)
    session.submit(from: 8, to: 0)
    XCTAssertNil(session.pending)
    session.submit(from: 8, to: 0, promotion: "n")
    XCTAssertEqual(session.pending?.promotion, "n")
  }
  func testObsoleteConnectionCallbackCannotMutateState() throws {
    try ready()
    let oldCallback = socket.onMessage
    session.reconnect()
    var auth = Message(type: "authenticated")
    auth.role = "tv"
    auth.pairingId = "pair"
    oldCallback?(auth)
    XCTAssertFalse(session.authenticated)
  }
  func testTransientDisconnectsAutomaticallyReconnectWithFreshState() throws {
    for (code, reason) in [
      (1006, "Offline"), (1001, "Server shutdown"),
      (1008, "Heartbeat timeout"), (1008, "Authentication timeout"),
    ] {
      try ready()
      let before = socket.connects
      session.closed(code: code, reason: reason)
      XCTAssertFalse(session.needsReconnect)
      XCTAssertFalse(session.canMove)
      XCTAssertTrue(session.statusText.contains("Reconnecting"))
      time += 2
      session.tick()
      XCTAssertEqual(socket.connects, before + 1)
      var auth = Message(type: "authenticated")
      auth.role = "tv"
      auth.pairingId = "pair"
      socket.onMessage?(auth)
      XCTAssertFalse(session.canMove)
      try ready()
      XCTAssertTrue(session.canMove)
    }
  }
  func testAuthenticationTimeoutAndRepeatedFailuresKeepRetrying() {
    session.reconnect()
    for _ in 0..<8 {
      let before = socket.connects
      time += 8
      session.tick()
      XCTAssertFalse(session.needsReconnect)
      XCTAssertEqual(socket.connects, before)
      time += 30
      session.tick()
      XCTAssertEqual(socket.connects, before + 1)
    }
  }
  func testPauseCancelsRetryAndResumeConnectsImmediately() {
    session.closed(code: 1006, reason: "Offline")
    let before = socket.connects
    session.setActive(false)
    time += 60
    session.tick()
    XCTAssertEqual(socket.connects, before)
    session.setActive(true)
    XCTAssertEqual(socket.connects, before + 1)
  }
  func testTerminalDisconnectsDoNotAutomaticallyTakeOverOrRePair() {
    for code in [4001, 4003, 1002, 1007, 1009, 1008] {
      session.reconnect()
      session.closed(code: code, reason: "Invalid credential")
      let before = socket.connects
      time += 60
      session.tick()
      XCTAssertTrue(session.needsReconnect)
      XCTAssertEqual(socket.connects, before)
    }
  }
  func testExtensionReconnectResynchronizesWithoutReconnectingTV() throws {
    try ready()
    let before = socket.connects
    var offline = Message(type: "session")
    offline.generation = "offline"
    offline.peerConnected = false
    session.receive(offline)
    XCTAssertFalse(session.canMove)
    XCTAssertTrue(session.statusText.contains("extension to reconnect"))
    state(generation: "recovered")
    var snapshot = try ProtocolTests.fixture()
    snapshot.generation = "recovered"
    session.receive(snapshot)
    available(generation: "recovered")
    XCTAssertTrue(session.canMove)
    XCTAssertEqual(socket.connects, before)
  }
  func testAutomaticReconnectNeverReplaysAnInterruptedMove() async throws {
    try ready()
    session.submit(from: 60, to: 52)
    await Task.yield()
    let moves = socket.sent.filter { $0.type == "move" }.count
    let command = session.pending?.commandId
    session.closed(code: 1006, reason: "Offline")
    time += 2
    session.tick()
    var auth = Message(type: "authenticated")
    auth.role = "tv"
    auth.pairingId = "pair"
    socket.onMessage?(auth)
    try ready()
    await Task.yield()
    XCTAssertEqual(session.pending?.commandId, command)
    XCTAssertFalse(session.canMove)
    XCTAssertEqual(socket.sent.filter { $0.type == "move" }.count, moves)
  }
}
