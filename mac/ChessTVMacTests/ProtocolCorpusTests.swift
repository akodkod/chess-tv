import XCTest
@testable import ChessTV

final class ProtocolCorpusTests: XCTestCase {
  func testSharedWireCorpus() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "messages", withExtension: "json"))
    let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    for entry in entries {
      let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(entry["message"]))
      if entry["valid"] as? Bool == true {
        let message = try Message.decode(data)
        XCTAssertEqual(try Message.decode(message.encoded()), message)
      } else { XCTAssertThrowsError(try Message.decode(data)) }
    }
  }
}
