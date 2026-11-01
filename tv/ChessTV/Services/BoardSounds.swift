import AVFoundation

enum BoardSound: String {
  case move = "move-self"
  case capture
  case check = "move-check"
}

@MainActor protocol BoardSoundPlaying {
  func play(_ sound: BoardSound)
  func stop()
}

/// Short, local clips: playback never depends on the relay or a browser request.
@MainActor final class BoardSounds: BoardSoundPlaying {
  private var players: [String: AVAudioPlayer] = [:]

  init(bundle: Bundle = .main) {
    for sound in [BoardSound.move, .capture, .check] {
      guard let url = bundle.url(forResource: sound.rawValue, withExtension: "mp3"),
        let player = try? AVAudioPlayer(contentsOf: url)
      else { continue }
      player.prepareToPlay()
      players[sound.rawValue] = player
    }
  }

  func play(_ sound: BoardSound) {
    guard let player = players[sound.rawValue] else { return }
    stop()
    player.currentTime = 0
    player.play()
  }

  func stop() {
    for player in players.values { player.stop() }
  }
}
