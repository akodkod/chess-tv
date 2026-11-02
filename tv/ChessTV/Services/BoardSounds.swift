import AVFoundation

enum BoardSound: String, CaseIterable {
  case move = "move-self"
  case capture
  case check = "move-check"
  case win = "game-win"
  case lose = "game-lose"
  case boing = "capture-boing"
  case yoink = "capture-yoink"
  case bonk = "capture-bonk"
  case pop = "capture-pop"

  var fileExtension: String {
    switch self {
    case .move, .capture, .check: "mp3"
    default: "wav"
    }
  }
}

enum CaptureSound: String, CaseIterable {
  case classic, boing, pop, bonk
  // Preserve the stored choice when replacing the old generated whistle.
  case yoink = "slideWhistle"

  var title: String {
    switch self {
    case .classic: "Default"
    case .boing: "Spring boing"
    case .yoink: "Yoink!"
    case .bonk: "Bonk!"
    case .pop: "Cartoon pop"
    }
  }
  var sound: BoardSound {
    switch self {
    case .classic: .capture
    case .boing: .boing
    case .yoink: .yoink
    case .bonk: .bonk
    case .pop: .pop
    }
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
