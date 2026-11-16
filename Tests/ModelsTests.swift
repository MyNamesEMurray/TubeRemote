import XCTest
@testable import TubeRemote

final class ModelsTests: XCTestCase {
    private func id(_ s: String) -> String? { parseVideoID(URL(string: s)) }

    func testParseVideoID() {
        XCTAssertEqual(id("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(id("https://www.youtube.com/shorts/abcdefghijk"), "abcdefghijk")
        XCTAssertEqual(id("https://www.youtube.com/embed/abcdefghijk"), "abcdefghijk")
        XCTAssertEqual(id("https://www.youtube.com/live/abcdefghijk"), "abcdefghijk")
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

    func testGoodbyeAndSpeedLabels() throws {
        let data = try JSONEncoder().encode(ServerMessage.goodbye)
        guard case .goodbye = try JSONDecoder().decode(ServerMessage.self, from: data) else { return XCTFail("wrong case") }
        XCTAssertEqual(rateLabel(1), "1×")
        XCTAssertEqual(rateLabel(1.25), "1.25×")
    }

    func testParseListID() {
        func list(_ s: String) -> String? { parseListID(URL(string: s)) }
        XCTAssertEqual(list("https://m.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI"), "PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI")
        XCTAssertEqual(list("https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc123"), "PLabc123")
        XCTAssertEqual(list("https://www.youtube.com/playlist?list=WL"), "WL")
        XCTAssertNil(list("https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ"), "auto-made mixes are not playlists")
        XCTAssertNil(list("https://example.com/playlist?list=PLabc123"))
        XCTAssertNil(list("https://m.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testSharedConfigRoundTrip() throws {
        let c = SharedConfig(deviceKey: "ABCD1234", deviceName: "Phone",
                             paired: [PairedDevice(key: "WXYZ9876", name: "iPad", secret: Data([1, 2, 3]))],
                             lastViewer: "WXYZ9876", queueAction: .playNext, pro: true)
        let again = try JSONDecoder().decode(SharedConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(again.paired.first?.secret, Data([1, 2, 3]))
        XCTAssertEqual(again.queueAction, .playNext)
        XCTAssertTrue(again.pro)
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

    func testPlaylistCommandRoundTrip() throws {
        let item = VideoItem(videoID: "dQw4w9WgXcQ", title: "t", channel: "c", duration: 10)
        let data = try JSONEncoder().encode(Command.playlist([item], .playNext))
        guard case .playlist(let items, let action) = try JSONDecoder().decode(Command.self, from: data) else { return XCTFail("wrong case") }
        XCTAssertEqual(items.map(\.videoID), ["dQw4w9WgXcQ"])
        XCTAssertEqual(action, .playNext)
    }
}
