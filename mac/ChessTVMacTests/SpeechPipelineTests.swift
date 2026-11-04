import XCTest
import AVFoundation
@testable import ChessTV

final class SpeechPipelineTests: XCTestCase {
  let candidates = [VoiceCandidate(id: "g2g4", description: "pawn g2 to g4"), VoiceCandidate(id: "e2e4", description: "pawn e2 to e4")]
  func response(_ choice: String, probability: Double) throws -> Data {
    var probabilities = Dictionary(uniqueKeysWithValues: (candidates.map(\.id) + JevMoveInterpreter.abstentions).map { ($0, 0.0) })
    probabilities[choice] = probability
    probabilities[choice == "unclear" ? "not_a_command" : "unclear"] = 1 - probability
    return try JSONSerialization.data(withJSONObject: ["answers": ["move": ["type": "choice", "choice": choice, "probabilities": probabilities]]])
  }
  func testJevThresholdAndAbstentions() throws {
    XCTAssertEqual(try JevMoveInterpreter.selectedMove(from: response("g2g4", probability: 0.98), candidates: candidates), "g2g4")
    XCTAssertThrowsError(try JevMoveInterpreter.selectedMove(from: response("g2g4", probability: 0.979), candidates: candidates))
    XCTAssertThrowsError(try JevMoveInterpreter.selectedMove(from: response("g2g5", probability: 1), candidates: candidates))
    XCTAssertThrowsError(try JevMoveInterpreter.selectedMove(from: response("unclear", probability: 1), candidates: candidates))
    XCTAssertThrowsError(try JevMoveInterpreter.selectedMove(from: response("illegal_requested_move", probability: 1), candidates: candidates))
    XCTAssertNil(try JevMoveInterpreter.selectedMove(from: response("not_a_command", probability: 1), candidates: candidates))
    XCTAssertThrowsError(try JevMoveInterpreter.selectedMove(from: Data("{}".utf8), candidates: candidates))
  }
  func testSegmentationEndsOnceAndResets() {
    var gate = SpeechSegmenter()
    XCTAssertEqual(gate.accept(probability: 0, samples: 512), .idle)
    XCTAssertEqual(gate.accept(probability: 0.9, samples: 512), .begin)
    for _ in 0..<18 { XCTAssertEqual(gate.accept(probability: 0, samples: 512), .append) }
    XCTAssertEqual(gate.accept(probability: 0, samples: 512), .finish)
    XCTAssertEqual(gate.accept(probability: 0, samples: 512), .idle)
    XCTAssertEqual(gate.accept(probability: 0.9, samples: 512), .begin)
  }
  func testOverlongSpeechIsDiscardedUntilSilence() {
    var gate = SpeechSegmenter()
    XCTAssertEqual(gate.accept(probability: 0.9, samples: 512), .begin)
    var rejections = 0
    for _ in 0..<400 { if gate.accept(probability: 0.9, samples: 512) == .reject { rejections += 1 } }
    XCTAssertEqual(rejections, 1)
    for _ in 0..<20 { XCTAssertEqual(gate.accept(probability: 0, samples: 512), .idle) }
    XCTAssertEqual(gate.accept(probability: 0.9, samples: 512), .begin)
  }
  func testModelIntegrity() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let asset = SpeechModelAsset(repository: "test", revision: "test", filename: "test", bytes: 3,
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    try Data("abc".utf8).write(to: file)
    XCTAssertNoThrow(try SpeechModelStore.verify(file, asset: asset))
    try Data("abd".utf8).write(to: file)
    XCTAssertThrowsError(try SpeechModelStore.verify(file, asset: asset))
    try Data("ab".utf8).write(to: file)
    XCTAssertThrowsError(try SpeechModelStore.verify(file, asset: asset))
  }
  func testInstalledParakeetStreamingWithSyntheticChessAudio() async throws {
    guard ProcessInfo.processInfo.environment["CHESS_VOICE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Opt-in test requires downloaded models and synthetic WAV fixtures.")
    }
    let decoder = try ParakeetDecoder()
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    for (name, square) in [("pawn", "g"), ("knight", "f")] {
      let file = try AVAudioFile(forReading: root.appendingPathComponent(".build/voice-fixtures/\(name).wav"))
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
      try file.read(into: buffer)
      let channel = try XCTUnwrap(buffer.floatChannelData?[0])
      let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))) + Array(repeating: Float(0), count: 16000)
      var finals: [SpeechCommand] = []
      let started = Date()
      for offset in stride(from: 0, to: samples.count, by: 512) {
        let events = try await decoder.consume(Array(samples[offset..<min(offset + 512, samples.count)]), began: started)
        finals += events.filter { $0.isFinal && $0.rejection == nil }
      }
      XCTAssertEqual(finals.count, 1)
      let text = try XCTUnwrap(finals.first?.text).lowercased()
      XCTAssertTrue(text.contains(name) || (name == "knight" && text.contains("night")), text)
      XCTAssertTrue(text.contains(square), text)
      print("Synthetic \(name): \(text); processing \(Date().timeIntervalSince(started)) seconds")
    }
  }
  func testLiveJevTerseKingCommand() async throws {
    guard ProcessInfo.processInfo.environment["CHESS_VOICE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Opt-in test uses the saved key and a synthetic board candidate list.")
    }
    let legal = [
      VoiceCandidate(id: "c1e3", description: "bishop from c1 to e3; Be3"),
      VoiceCandidate(id: "d1d4", description: "queen from d1 to d4; Qd4"),
      VoiceCandidate(id: "f1f2", description: "rook from f1 to f2; Rf2"),
      VoiceCandidate(id: "g1g2", description: "king from g1 to g2; Kg2"),
      VoiceCandidate(id: "g1h1", description: "king from g1 to h1; Kh1")]
    let key = try XCTUnwrap(JevKeyStore().load())
    let result = try await JevMoveInterpreter().interpret("King h1", candidates: legal, key: key)
    XCTAssertEqual(result, "g1h1")
  }
  func testLiveJevWithSavedKey() async throws {
    guard ProcessInfo.processInfo.environment["CHESS_VOICE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Opt-in test uses the locally saved key and a synthetic command.")
    }
    let key = try XCTUnwrap(JevKeyStore().load())
    let result = try await JevMoveInterpreter().interpret("Pawn G4", candidates: candidates, key: key)
    XCTAssertEqual(result, "g2g4")
  }

}

private final class JevURLProtocol: URLProtocol, @unchecked Sendable {
  static var handler: ((URLRequest) throws -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler!(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

extension SpeechPipelineTests {
  func testJevHTTPFailuresNeverRetryOrSelectAMove() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [JevURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel(); JevURLProtocol.handler = nil }
    for status in [401, 402, 403, 429, 500] {
      var calls = 0
      JevURLProtocol.handler = { request in
        calls += 1
        XCTAssertEqual(request.url?.host, "api.typesafe.ai")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 5)
        return (status, Data())
      }
      do {
        _ = try await JevMoveInterpreter().interpret("Pawn G4", candidates: candidates, key: "test-only", session: session)
        XCTFail("HTTP error must not select a move")
      } catch {}
      XCTAssertEqual(calls, 1)
    }
    JevURLProtocol.handler = { _ in throw URLError(.timedOut) }
    do {
      _ = try await JevMoveInterpreter().interpret("Pawn G4", candidates: candidates, key: "test-only", session: session)
      XCTFail()
    } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    JevURLProtocol.handler = { _ in throw URLError(.cancelled) }
    do {
      _ = try await JevMoveInterpreter().interpret("Pawn G4", candidates: candidates, key: "test-only", session: session)
      XCTFail()
    } catch { XCTAssertTrue(error is CancellationError) }
  }
}


extension SpeechPipelineTests {
  @MainActor func testDiagnosticsCaptureRejectedResponseWithoutKeyAndKeepTrace() async throws {
    let log = VoiceDiagnostics.shared
    log.clear()
    defer { log.clear(); JevURLProtocol.handler = nil }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [JevURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let data = try response("g2g4", probability: 0.97)
    JevURLProtocol.handler = { _ in (200, data) }
    let trace = UUID()
    do {
      _ = try await VoiceTrace.$id.withValue(trace) {
        try await JevMoveInterpreter().interpret("Pwn G4", candidates: candidates, key: "secret-test-key", session: session)
      }
      XCTFail("Low confidence must still reject")
    } catch { XCTAssertTrue(error.localizedDescription.contains("97.0%")) }
    XCTAssertTrue(log.events.allSatisfy { $0.trace == trace })
    XCTAssertTrue(log.export.contains("Pwn G4"))
    XCTAssertTrue(log.export.contains("probabilities"))
    XCTAssertTrue(log.export.contains("Jev rejected or failed"))
    XCTAssertFalse(log.export.contains("secret-test-key"))
    for _ in 0..<305 { log.record("test", "bounded") }
    XCTAssertEqual(log.events.count, 300)
    log.clear()
    XCTAssertTrue(log.export.isEmpty)
  }
}
