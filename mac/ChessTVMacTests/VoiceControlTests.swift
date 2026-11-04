import XCTest
@testable import ChessTV

@MainActor final class FakeSpeech: SpeechListening {
  var command: ((SpeechCommand) -> Void)?
  var status: ((String) -> Void)?
  var wait: CheckedContinuation<Void, Error>?
  var stops = 0
  func run(status: @escaping (String) -> Void, command: @escaping (SpeechCommand) -> Void) async throws {
    self.status = status
    self.command = command
    status("Downloading English voice recognition…")
    try await withCheckedThrowingContinuation { wait = $0 }
  }
  func stop() { stops += 1; wait?.resume(); wait = nil }
  func emit(_ text: String, start: Date = Date(), end: Date = Date().addingTimeInterval(1)) {
    command?(SpeechCommand(text: text, start: start, end: end))
  }
}

@MainActor final class FakeVoiceGame: VoiceGameControlling {
  var voicePosition: VoicePosition? = VoicePosition(token: "position", document: UUID(), since: .distantPast)
  var enabled = false
  var moves: [String] = []
  var alternatives: [[String]] = []
  var warnings: [String] = []
  func reportVoiceWarning(_ message: String) { warnings.append(message) }
  var failure: Error?
  func setVoiceEnabled(_ enabled: Bool) { self.enabled = enabled }
  func submitVoice(_ text: String, alternatives: [String], position: VoicePosition) async throws {
    if let failure { throw failure }
    moves.append(text)
    self.alternatives.append(alternatives)
  }
}

@MainActor final class VoiceControlTests: XCTestCase {
  func settle() async { for _ in 0..<20 { await Task.yield() } }
  func testTogglePreparationDuplicateAndSilentSuccess() async {
    let game = FakeVoiceGame(), speech = FakeSpeech()
    var sounds = 0
    let voice = VoiceControl(game: game, makeListener: { _ in speech }, errorSound: { sounds += 1 })
    XCTAssertFalse(voice.enabled)
    voice.start()
    await settle()
    XCTAssertTrue(game.enabled)
    XCTAssertTrue(voice.status?.contains("Downloading") == true)
    let end = Date().addingTimeInterval(1)
    speech.emit("move e4", end: end)
    await settle()
    speech.emit("move e4", end: end)
    await settle()
    XCTAssertEqual(game.moves, ["move e4"])
    XCTAssertEqual(sounds, 0)
    voice.stop()
    speech.emit("move d4", end: end.addingTimeInterval(1))
    await settle()
    XCTAssertFalse(game.enabled)
    XCTAssertEqual(game.moves.count, 1)
    XCTAssertNil(voice.status)
  }
  func testUnrelatedSpeechStalePositionAndCommandError() async {
    let game = FakeVoiceGame(), speech = FakeSpeech()
    var sounds = 0
    let voice = VoiceControl(game: game, makeListener: { _ in speech }, errorSound: { sounds += 1 })
    voice.start()
    await settle()
    speech.emit("hello there", end: Date())
    XCTAssertEqual(sounds, 0)
    game.voicePosition = VoicePosition(token: "new", document: UUID(), since: Date())
    speech.emit("move e4", start: .distantPast)
    XCTAssertEqual(sounds, 0)
    XCTAssertTrue(game.moves.isEmpty)
    game.failure = ProtocolFailure("That move is not legal.")
    speech.emit("move e5", end: Date().addingTimeInterval(2))
    await settle()
    XCTAssertEqual(sounds, 0)
    XCTAssertEqual(voice.error, "That move is not legal.")
    XCTAssertEqual(game.warnings.last, "That move is not legal.")
    voice.stop()
  }
  func testRecognitionFailureStopsAndCanRetry() async {
    let game = FakeVoiceGame(), first = FakeSpeech(), second = FakeSpeech()
    var count = 0, sounds = 0
    let voice = VoiceControl(game: game, makeListener: { _ in
      count += 1; return count == 1 ? first : second
    }, errorSound: { sounds += 1 })
    voice.start()
    await settle()
    first.wait?.resume(throwing: ProtocolFailure("Microphone access denied.")); first.wait = nil
    await settle()
    XCTAssertFalse(voice.enabled)
    XCTAssertFalse(game.enabled)
    XCTAssertEqual(sounds, 1)
    XCTAssertEqual(voice.error, "Microphone access denied.")
    voice.start()
    await settle()
    XCTAssertTrue(voice.enabled)
    XCTAssertNil(voice.error)
    voice.stop()
  }
  func testUnsupportedPlatformDoesNotStart() {
    let game = FakeVoiceGame()
    let voice = VoiceControl(game: game, unavailableReason: "Requires macOS 26",
      makeListener: { _ in XCTFail("Should not create listener"); return FakeSpeech() })
    voice.start()
    XCTAssertFalse(voice.enabled)
    XCTAssertFalse(game.enabled)
  }
  func testAccuracyChangeRestartsListeningAndForwardsAlternatives() async {
    let game = FakeVoiceGame(), first = FakeSpeech(), second = FakeSpeech()
    var modes: [Bool] = []
    let voice = VoiceControl(game: game, makeListener: { accuracy in
      modes.append(accuracy)
      return modes.count == 1 ? first : second
    })
    voice.start()
    await settle()
    voice.setPreferAccuracy(false)
    await settle()
    XCTAssertEqual(modes, [true, false])
    XCTAssertEqual(first.stops, 1)
    first.emit("move e4")
    XCTAssertTrue(game.moves.isEmpty)
    second.command?(SpeechCommand(text: "move pawn gee four", start: Date(),
      end: Date().addingTimeInterval(2), alternatives: ["move pawn g4"]))
    await settle()
    XCTAssertEqual(voice.lastHeard, "move pawn gee four")
    XCTAssertEqual(game.alternatives, [["move pawn g4"]])
    voice.setPreferAccuracy(false)
    XCTAssertEqual(modes.count, 2)
    voice.stop()
    XCTAssertNil(voice.lastHeard)
  }
  func testHeardTextIsVisibleForIgnoredSpeechAndRejections() async {
    let game = FakeVoiceGame(), speech = FakeSpeech()
    let voice = VoiceControl(game: game, makeListener: { _ in speech }, errorSound: {})
    voice.start()
    await settle()
    speech.emit("hello", end: Date())
    XCTAssertEqual(voice.lastHeard, "hello")
    game.failure = ProtocolFailure("That move is not legal.")
    speech.emit("move e5", end: Date().addingTimeInterval(2))
    await settle()
    XCTAssertEqual(voice.lastHeard, "move e5")
    XCTAssertEqual(voice.error, "That move is not legal.")
    XCTAssertEqual(game.warnings.last, "That move is not legal.")
    voice.stop()
  }

  func testRepeatedSquareFragmentReachesBoardResolver() async {
    let game = FakeVoiceGame(), speech = FakeSpeech()
    let voice = VoiceControl(game: game, makeListener: { _ in speech }, errorSound: {})
    voice.start()
    await settle()
    speech.emit("G4. Move pawn G4.")
    await settle()
    XCTAssertEqual(game.moves, ["G4. Move pawn G4."])
    XCTAssertEqual(voice.lastHeard, "G4. Move pawn G4.")
    voice.stop()
  }

  func testRejectedCommandNoticeExpires() async throws {
    let game = FakeVoiceGame(), speech = FakeSpeech()
    game.voicePosition = nil
    let voice = VoiceControl(game: game, makeListener: { _ in speech }, errorSound: {}, allowsAI: { true })
    voice.start(); await settle()
    speech.emit("I believe")
    XCTAssertEqual(voice.commandNotice, "Command not found: \"I believe\"")
    XCTAssertTrue(voice.error?.contains("stable board") == true)
    try await Task.sleep(for: .milliseconds(4200))
    XCTAssertNil(voice.commandNotice)
    XCTAssertNil(voice.error)
    XCTAssertNil(voice.lastHeard)
    XCTAssertTrue(voice.enabled)
    voice.stop()
  }

  func testBareSquaresAreRejectedWithAndWithoutJev() async {
    for useAI in [false, true] {
      let game = FakeVoiceGame(), speech = FakeSpeech()
      let voice = VoiceControl(game: game, makeListener: { _ in speech }, errorSound: {}, allowsAI: { useAI })
      voice.start(); await settle()
      for (index, text) in ["d4", "D4.", "dee four"].enumerated() {
        speech.emit(text, end: Date().addingTimeInterval(Double(index + 1)))
        await settle()
      }
      XCTAssertTrue(game.moves.isEmpty)
      XCTAssertEqual(game.warnings.count, 3)
      XCTAssertTrue(voice.error?.contains("Name the piece") == true)
      voice.stop()
    }
  }

  func testPartialTranscriptNeverSubmitsAndFinalIsDeduplicated() async {
    let game = FakeVoiceGame(), speech = FakeSpeech()
    let voice = VoiceControl(game: game, makeListener: { _ in speech }, errorSound: {})
    voice.start(); await settle()
    let start = Date(), end = Date().addingTimeInterval(1)
    speech.command?(SpeechCommand(text: "move g4", start: start, end: end, isFinal: false))
    await settle()
    XCTAssertEqual(voice.lastHeard, "move g4")
    XCTAssertTrue(game.moves.isEmpty)
    speech.emit("move g4", start: start, end: end)
    await settle()
    speech.emit("move g4", start: start, end: end)
    await settle()
    XCTAssertEqual(game.moves, ["move g4"])
    voice.stop()
  }

  func testPieceFirstCommandsReachResolverWithoutAI() async {
    let game = FakeVoiceGame(), speech = FakeSpeech()
    let voice = VoiceControl(game: game, makeListener: { _ in speech }, errorSound: {})
    voice.start(); await settle()
    let commands = ["Rook D4", "Knight F3", "night to f three", "Pawn D4", "Rook from B1 to B4"]
    for (index, text) in commands.enumerated() {
      speech.emit(text, end: Date().addingTimeInterval(Double(index + 1)))
      await settle()
    }
    XCTAssertEqual(game.moves, commands)
    XCTAssertTrue(game.warnings.isEmpty)
    voice.stop()
  }

}
