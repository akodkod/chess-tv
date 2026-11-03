import Foundation

struct AdapterReply: Decodable {
  struct Failure: Decodable {
    let code: String
    let message: String
  }
  let instance: String
  let gameId: String?
  let messages: [Message]
  let error: Failure?
}

@MainActor protocol GamePage: AnyObject {
  var usable: Bool { get }
  var documentID: UUID { get }
  func call(_ action: [String: Any]) async throws -> AdapterReply
}
