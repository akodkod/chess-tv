import Foundation
import Observation

// Task-local IDs keep asynchronous responses attached to their original utterance.
enum VoiceTrace {
  @TaskLocal static var id: UUID?
}

@MainActor @Observable final class VoiceDiagnostics {
  struct Event: Identifiable {
    let id = UUID()
    let date = Date()
    let trace: UUID?
    let stage: String
    let detail: String
    var formatted: String {
      "\(date.formatted(date: .omitted, time: .standard)) [\(trace.map { String($0.uuidString.prefix(8)) } ?? "session")] \(stage)\n\(detail)"
    }
  }
  static let shared = VoiceDiagnostics()
  private(set) var events: [Event] = []
  func record(_ stage: String, _ detail: String) {
    events.append(Event(trace: VoiceTrace.id, stage: stage, detail: String(detail.prefix(65536))))
    if events.count > 300 { events.removeFirst(events.count - 300) }
  }
  func clear() { events.removeAll() }
  var export: String { events.map(\.formatted).joined(separator: "\n\n") }
  nonisolated static func json(_ data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: pretty, encoding: .utf8) else {
      return String(data: data, encoding: .utf8) ?? "Non-UTF8 response (\(data.count) bytes)"
    }
    return text
  }
}
