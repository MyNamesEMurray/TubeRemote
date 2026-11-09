import XCTest
@testable import TubeRemote

final class ModelsTests: XCTestCase {
    private func id(_ s: String) -> String? { parseVideoID(URL(string: s)) }

    func testParseVideoID() {
        XCTAssertEqual(id("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://www.youtube.com/shorts/abcdefghijk"), "abcdefghijk")
        XCTAssertEqual(id("https://www.youtube.com/embed/abcdefghijk"), "abcdefghijk")
        XCTAssertNil(id("https://example.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(parseVideoID(nil))
    }

    func testIsValid() {
        func item(_ v: String) -> VideoItem { VideoItem(videoID: v, title: "t", channel: "c", duration: nil) }
        XCTAssertTrue(item("dQw4w9WgXcQ").isValid)
        XCTAssertFalse(item("abc").isValid)
        XCTAssertFalse(item("abc'def\"ghi").isValid)
        XCTAssertFalse(item("abcdefgh');alert(1)//").isValid)
    }

    func testClock() {
        XCTAssertEqual(clock(0), "0:00")
        XCTAssertEqual(clock(65), "1:05")
        XCTAssertEqual(clock(3725), "1:02:05")
        XCTAssertEqual(clock(-1), "0:00")
        XCTAssertEqual(clock(.nan), "0:00")
    }

    func testCommandRoundTrip() throws {
        let item = VideoItem(videoID: "dQw4w9WgXcQ", title: "t", channel: "c", duration: 10)
        for cmd in [Command.play(item), .seek(12.5), .setMuted(true), .clearQueue] {
            let data = try JSONEncoder().encode(cmd)
            let again = try JSONEncoder().encode(try JSONDecoder().decode(Command.self, from: data))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: again) as? NSDictionary)
        }
        if case .seek(let s) = try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(Command.seek(12.5))) {
            XCTAssertEqual(s, 12.5)
        } else { XCTFail("wrong case") }
    }
}
