import Foundation
import CryptoKit
import Observation

struct SpeechModelAsset: Sendable {
  let repository: String
  let revision: String
  let filename: String
  let bytes: Int64
  let sha256: String
  var url: URL { URL(string: "https://huggingface.co/handy-computer/\(repository)/resolve/\(revision)/\(filename)")! }
}

@MainActor @Observable final class SpeechModelStore {
  static let shared = SpeechModelStore()
  nonisolated static let assets = [
    SpeechModelAsset(repository: "parakeet-unified-en-0.6b-gguf", revision: "843b1b175ace04f5a89d379c79e2518c0d065b25",
      filename: "parakeet-unified-en-0.6b-Q8_0.gguf", bytes: 731357568,
      sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"),
    SpeechModelAsset(repository: "silero-vad-v6.2-gguf", revision: "a9b2d61c20ae4ddf3644edb34969e8185a485448",
      filename: "silero-vad-v6.2-F32.gguf", bytes: 1241056,
      sha256: "0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6")
  ]
  nonisolated static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ChessTV/SpeechModels", isDirectory: true)
  }
  private(set) var installed = assets.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
  private(set) var downloading = false
  private(set) var progress = 0.0
  private(set) var error: String?
  private var task: Task<Void, Never>?

  func download() {
    guard !downloading else { return }
    downloading = true; error = nil; progress = 0
    task = Task {
      defer { downloading = false; task = nil }
      do {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for (index, asset) in Self.assets.enumerated() {
          try Task.checkCancellation()
          let destination = Self.directory.appendingPathComponent(asset.filename)
          if (try? await Task.detached { try Self.verify(destination, asset: asset) }.value) != nil { continue }
          let completedBytes = Self.assets.prefix(index).reduce(Int64(0)) { $0 + $1.bytes }
          let totalBytes = Self.assets.reduce(Int64(0)) { $0 + $1.bytes }
          let progressDelegate = ModelDownloadProgress { [self] fraction in
            Task { @MainActor in progress = (Double(completedBytes) + fraction * Double(asset.bytes)) / Double(totalBytes) }
          }
          let (temporary, response) = try await URLSession.shared.download(from: asset.url, delegate: progressDelegate)
          defer { try? FileManager.default.removeItem(at: temporary) }
          guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProtocolFailure("Model download failed. Retry when connected.") }
          try await Task.detached { try Self.verify(temporary, asset: asset) }.value
          try Task.checkCancellation()
          // Only install a fully verified file; incomplete downloads never look ready.
          if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
          try FileManager.default.moveItem(at: temporary, to: destination)
        }
        installed = true; progress = 1
      } catch is CancellationError { error = nil }
      catch let failure as URLError where failure.code == .cancelled { error = nil }
      catch { self.error = error.localizedDescription }
    }
  }
  func cancelDownload() { task?.cancel() }
  func remove() {
    guard !downloading else { return }
    do {
      for asset in Self.assets {
        let url = Self.directory.appendingPathComponent(asset.filename)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
      }
      installed = false; error = nil
    } catch { self.error = error.localizedDescription }
  }
  nonisolated static func verify(_ url: URL, asset: SpeechModelAsset) throws {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard (attrs[.size] as? NSNumber)?.int64Value == asset.bytes else {
      throw ProtocolFailure("Model size mismatch. Remove and download the model again.")
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
    guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
      throw ProtocolFailure("Model checksum mismatch. Remove and download the model again.")
    }
  }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  let progress: @Sendable (Double) -> Void
  init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
