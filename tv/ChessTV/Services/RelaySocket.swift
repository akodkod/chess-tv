import Foundation

@MainActor protocol RelayConnecting: AnyObject {
  var onMessage: ((Message) -> Void)? { get set }
  var onClose: ((Int, String) -> Void)? { get set }
  func connect(url: URL, credential: String)
  func send(_ message: Message) async throws
  func disconnect()
}

@MainActor final class RelaySocket: RelayConnecting {
  var onMessage: ((Message) -> Void)?
  var onClose: ((Int, String) -> Void)?
  private var socket: URLSessionWebSocketTask?
  private var receiver: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var epoch = UUID()
  private var lastPong = ProcessInfo.processInfo.systemUptime
  private var pingNonce: String?

  func connect(url: URL, credential: String) {
    disconnect()
    let epoch = self.epoch
    let socket = URLSession.shared.webSocketTask(with: url)
    socket.maximumMessageSize = 65_536
    self.socket = socket
    lastPong = ProcessInfo.processInfo.systemUptime
    socket.resume()
    receiver = Task { [weak self] in
      guard let self else { return }
      do {
        var auth = Message(type: "authenticate")
        auth.credential = credential
        try await send(auth)
        guard epoch == self.epoch else { return }
        heartbeat = Task { [weak self] in
          while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, epoch == self.epoch else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastPong >= 60 {
              self.fail(epoch: epoch, code: 0, reason: "Relay heartbeat timed out.")
              return
            }
            if self.pingNonce == nil {
              var ping = Message(type: "ping")
              ping.nonce = UUID().uuidString
              self.pingNonce = ping.nonce
              do { try await self.send(ping) } catch {
                self.fail(epoch: epoch, code: 0, reason: "Relay connection was lost.")
                return
              }
            }
          }
        }
        while !Task.isCancelled {
          let frame = try await socket.receive()
          guard epoch == self.epoch else { return }
          guard case .string(let text) = frame else {
            throw ProtocolFailure("Expected a text JSON relay message.")
          }
          let message = try Message.decode(Data(text.utf8))
          if message.type == "ping" {
            var pong = Message(type: "pong")
            pong.nonce = message.nonce
            try await send(pong)
          } else if message.type == "pong" {
            if message.nonce == pingNonce {
              lastPong = ProcessInfo.processInfo.systemUptime
              pingNonce = nil
            }
          } else {
            onMessage?(message)
          }
        }
      } catch {
        let protocolError = error as? ProtocolFailure
        fail(
          epoch: epoch,
          code: protocolError != nil || error is DecodingError ? 1002 : socket.closeCode.rawValue,
          reason: protocolError?.localizedDescription ?? socket.closeReason.flatMap {
            String(data: $0, encoding: .utf8)
          } ?? "Relay connection was lost.")
      }
    }
  }
  func send(_ message: Message) async throws {
    guard let socket else { throw ProtocolFailure("Relay is disconnected.") }
    let text = String(decoding: try message.encoded(), as: UTF8.self)
    try await socket.send(.string(text))
  }
  func disconnect() {
    epoch = UUID()
    receiver?.cancel()
    heartbeat?.cancel()
    receiver = nil
    heartbeat = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    pingNonce = nil
  }
  private func fail(epoch: UUID, code: Int, reason: String) {
    guard epoch == self.epoch else { return }
    disconnect()
    onClose?(code, reason)
  }
}
