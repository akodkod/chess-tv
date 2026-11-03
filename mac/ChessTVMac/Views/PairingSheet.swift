import SwiftUI

struct PairingSheet: View {
  let session: MacSession
  @Environment(\.dismiss) private var dismiss
  @State private var code = ""
  @State private var submitted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Pair your TV").font(.headline)
      Text(session.pairing ? "Confirm the pairing request on your TV."
        : "Enter the six-digit code displayed in Chess TV.")
        .foregroundStyle(.secondary)
      if !session.pairing {
        TextField("TV code", text: $code)
          .textFieldStyle(.roundedBorder)
          .onChange(of: code) { _, value in code = String(value.filter(\.isASCII).filter(\.isNumber).prefix(6)) }
          .onSubmit { submit() }
      } else { ProgressView().controlSize(.small) }
      if let error = session.error { Text(error).foregroundStyle(.red).font(.callout) }
      HStack {
        Spacer()
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        if !session.pairing {
          Button("Pair") { submit() }
            .keyboardShortcut(.defaultAction)
            .disabled(code.count != 6 || submitted)
        }
      }
    }
    .padding(24).frame(width: 360)
    .onChange(of: session.paired) { _, paired in if paired { dismiss() } }
    .onChange(of: session.error) { _, _ in submitted = false }
    .onChange(of: session.pairing) { _, _ in submitted = false }
  }
  private func submit() {
    guard code.count == 6, !submitted else { return }
    submitted = true
    session.pair(code: code)
  }
}
