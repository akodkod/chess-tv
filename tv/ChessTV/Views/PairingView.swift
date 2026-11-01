import SwiftUI

struct PairingView: View {
  let session: TVSession
  var body: some View {
    VStack(spacing: 28) {
      Text("Chess TV").font(.largeTitle.bold())
      Text("Your game, on the big screen").font(.title2).foregroundStyle(.secondary)
      if let challenge = session.challenge {
        Text(challenge.code).font(.system(size: 96, weight: .semibold, design: .monospaced))
          .tracking(12).accessibilityLabel(
            "Pairing code: \(challenge.code.map(String.init).joined(separator: ", "))")
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let remaining = max(
            0, Int(ceil(challenge.expiresAt / 1000 - context.date.timeIntervalSince1970)))
          Text("Code expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }.accessibilityHidden(true)
        Text(session.notice).multilineTextAlignment(.center)
      } else {
        Text(session.notice).multilineTextAlignment(.center)
        Button(session.busy ? "Requesting code…" : "Get pairing code") { session.createCode() }
          .disabled(session.busy)
      }
      Text("Keep Chrome awake, with the connected game tab selected and visible.")
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.frame(maxWidth: 1100).padding(60)
  }
}
