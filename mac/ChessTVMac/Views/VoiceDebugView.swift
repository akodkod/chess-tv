import SwiftUI

struct VoiceDebugView: View {
  @State private var diagnostics = VoiceDiagnostics.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Recent recognition events stay in memory (up to 300). Includes transcripts and Jev payloads, without authorization headers or audio.")
        .font(.callout).foregroundStyle(.secondary).padding()
      Divider()
      if diagnostics.events.isEmpty {
        ContentUnavailableView("No voice events yet", systemImage: "waveform", description: Text("Enable the microphone and say a move. Events appear here even when this window is closed."))
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(diagnostics.events.reversed()) { event in
              VStack(alignment: .leading, spacing: 5) {
                Text("\(event.date.formatted(date: .omitted, time: .standard)) · \(event.stage) · \(event.trace.map { String($0.uuidString.prefix(8)) } ?? "session")")
                  .font(.headline)
                Text(event.detail).font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              }
              Divider()
            }
          }.padding()
        }
      }
    }
    .frame(minWidth: 640, minHeight: 400)
    .toolbar {
      Button("Copy All", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.export, forType: .string)
      }.disabled(diagnostics.events.isEmpty)
      Button("Clear", systemImage: "trash") { diagnostics.clear() }.disabled(diagnostics.events.isEmpty)
    }
  }
}

struct VoiceDebugCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    CommandMenu("Voice") {
      Button("Voice Recognition Debug…") { openWindow(id: "voice-debug") }
        .keyboardShortcut("d", modifiers: [.command, .option])
    }
  }
}
