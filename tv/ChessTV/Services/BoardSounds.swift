import AVFoundation

enum BoardSound: String, CaseIterable {
  case move = "move-self"
  case capture
  case check = "move-check"
  case win = "game-win"
  case lose = "game-lose"

  var fileExtension: String {
    self == .win || self == .lose ? "wav" : "mp3"
  }
}

@MainActor protocol BoardSoundPlaying {
  func play(_ sound: BoardSound)
  func stop()
}

/// Short, local clips: playback never depends on the relay or a browser request.
@MainActor final class BoardSounds: BoardSoundPlaying {
  private var players: [String: AVAudioPlayer] = [:]

  init(bundle: Bundle = .main) {
    for sound in BoardSound.allCases {
      guard let url = bundle.url(forResource: sound.rawValue, withExtension: sound.fileExtension),
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
