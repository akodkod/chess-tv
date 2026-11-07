import SwiftUI

struct VoiceSettingsView: View {
  @Environment(\.openWindow) private var openWindow
  let voice: VoiceControl?
  @AppStorage("voicePreferAccuracy") private var preferAccuracy = true
  @AppStorage("voiceEngine") private var engine = VoiceEngine.apple.rawValue
  @AppStorage("voiceUseJev") private var useJev = false
  @State private var models = SpeechModelStore.shared
  @State private var apiKey = ""
  @State private var keyStatus: String?
  @State private var testingKey = false

  var body: some View {
    Form {
      Section("Speech recognition") {
        Button("Open Voice Recognition Debug…") { openWindow(id: "voice-debug") }
        Picker("Engine", selection: $engine) {
          Text("Apple (on device)").tag(VoiceEngine.apple.rawValue)
          Text("Parakeet Unified English").tag(VoiceEngine.parakeet.rawValue)
            .disabled(!models.installed || !supportsParakeet)
        }
        if engine == VoiceEngine.apple.rawValue {
          Toggle("Prefer recognition accuracy", isOn: $preferAccuracy)
          Text("Commands may take longer to recognize. Changing this restarts listening.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if models.downloading {
          ProgressView("Downloading speech models…", value: models.progress)
          Button("Cancel Download") { models.cancelDownload() }
        } else if models.installed {
          HStack {
            Text("Parakeet ready · English · 733 MB").foregroundStyle(.secondary)
            Spacer()
            Button("Remove Models") {
              voice?.stop(); engine = VoiceEngine.apple.rawValue; models.remove()
            }
          }
        } else {
          Button("Download Parakeet Unified (733 MB)") { models.download() }
            .disabled(!supportsParakeet)
          Text("Includes speech detection. Audio is processed on your Mac. Select Parakeet after the download completes.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let error = models.error { Text(error.displayText).foregroundStyle(.red) }
      }
      Section("Move interpretation") {
        Text("Say “Rook D4”, “Knight F3”, or “Pawn D4”. Always name the piece. Only add a starting square when ambiguous: “Rook from B1 to B4”.")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("Use Jev for unrecognized commands", isOn: $useJev)
        Text("Jev receives transcripts and legal-move descriptions, never audio. Confident interpretations play automatically; uncertain ones ask you to repeat. Requires internet and API credits.")
          .font(.caption).foregroundStyle(.secondary)
        SecureField("Jev API key", text: $apiKey)
        HStack {
          Button("Save Key") { saveKey() }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button(testingKey ? "Testing…" : "Test Saved Key") { testKey() }.disabled(testingKey)
          Button("Remove Key") {
            do { try JevKeyStore().save(""); apiKey = ""; useJev = false; keyStatus = "Key removed."; voice?.interpretationSettingsChanged() }
            catch { keyStatus = error.localizedDescription }
          }
        }
        if let keyStatus { Text(keyStatus.displayText).font(.caption).foregroundStyle(.secondary) }
      }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 490)
  }
  private var supportsParakeet: Bool {
    #if arch(arm64)
    true
    #else
    false
    #endif
  }
  private func testKey() {
    testingKey = true
    Task {
      defer { testingKey = false }
      do {
        guard let key = try JevKeyStore().load(), !key.isEmpty else { throw ProtocolFailure("Save a key first.") }
        let result = try await JevMoveInterpreter().interpret("Pawn G4", candidates: [
          VoiceCandidate(id: "g2g4", description: "Move the pawn from g2 to g4"),
          VoiceCandidate(id: "e2e4", description: "Move the pawn from e2 to e4")], key: key)
        keyStatus = result == "g2g4" ? "Connected. Sample command interpreted correctly; no move played." : "Connected, but sample command was not recognized."
      } catch { keyStatus = error.localizedDescription }
    }
  }
  private func saveKey() {
    do {
      try JevKeyStore().save(apiKey); apiKey = ""; keyStatus = "Key saved in Keychain."
      voice?.interpretationSettingsChanged()
    } catch { keyStatus = error.localizedDescription }
  }
}
