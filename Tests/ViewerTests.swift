import XCTest
@testable import TubeRemote

final class ViewerTests: XCTestCase {
    private func item(_ v: String) -> VideoItem { VideoItem(videoID: v, title: v, channel: "c", duration: 100) }

    private func makeViewer() -> ViewerController {
        let settings = AppSettings()
        return ViewerController(settings: settings, pairing: Pairing(settings: settings))
    }

    func testQueueAdvanceAndPrevious() {
        let v = makeViewer()
        v.handle(.enqueue(item("aaaaaaaaaaa")), from: nil)
        v.handle(.enqueue(item("bbbbbbbbbbb")), from: nil)
        v.handle(.playNext(item("ccccccccccc")), from: nil)
        XCTAssertEqual(v.current?.videoID, "aaaaaaaaaaa")
        XCTAssertEqual(v.queue.map(\.videoID), ["ccccccccccc", "bbbbbbbbbbb"])

        v.handle(.next, from: nil)
        XCTAssertEqual(v.current?.videoID, "ccccccccccc")
        XCTAssertEqual(v.history.map(\.videoID), ["aaaaaaaaaaa"])

        v.handle(.previous, from: nil)
        XCTAssertEqual(v.current?.videoID, "aaaaaaaaaaa")
        XCTAssertEqual(v.queue.map(\.videoID), ["ccccccccccc", "bbbbbbbbbbb"])
        XCTAssertTrue(v.history.isEmpty)
    }

    func testReorderRemoveAndInvalidItems() {
        let v = makeViewer()
        v.handle(.play(item("aaaaaaaaaaa")), from: nil)
        v.handle(.enqueue(item("bbbbbbbbbbb")), from: nil)
        v.handle(.enqueue(item("ccccccccccc")), from: nil)
        v.handle(.enqueue(item("x');alert(1)//")), from: nil)
        XCTAssertEqual(v.queue.count, 2)

        v.handle(.reorder([v.queue[1].id]), from: nil)
        XCTAssertEqual(v.queue.map(\.videoID), ["ccccccccccc", "bbbbbbbbbbb"])

        v.handle(.remove(v.queue[0].id), from: nil)
        XCTAssertEqual(v.queue.map(\.videoID), ["bbbbbbbbbbb"])
    }

    func testQueueEndGoesIdleAndKeepsHistory() {
        let v = makeViewer()
        v.handle(.play(item("aaaaaaaaaaa")), from: nil)
        v.handle(.next, from: nil)
        XCTAssertNil(v.current)
        XCTAssertFalse(v.isPlaying)
        XCTAssertEqual(v.history.map(\.videoID), ["aaaaaaaaaaa"])
    }

    func testChannelEncryptsBothWaysAndRejectsReplay() throws {
        let secret = Data(repeating: 7, count: 32), salt = Data(repeating: 1, count: 32)
        var remote = Channel(secret: secret, salt: salt, viewer: false)
        var viewer = Channel(secret: secret, salt: salt, viewer: true)

        let box = try XCTUnwrap(remote.seal(ClientMessage.command(.seek(12.5))))
        let body = try XCTUnwrap(viewer.open(box))
        if case .command(.seek(let t)) = try JSONDecoder().decode(ClientMessage.self, from: body) {
            XCTAssertEqual(t, 12.5)
        } else { XCTFail("wrong message") }

        XCTAssertNil(viewer.open(box), "a replayed message must be rejected")
        XCTAssertNil(remote.open(box), "a message must not open with the sender's own key")

        let second = try XCTUnwrap(remote.seal(ClientMessage.command(.pause)))
        XCTAssertNotNil(viewer.open(second))

        var stranger = Channel(secret: Data(repeating: 8, count: 32), salt: salt, viewer: true)
        XCTAssertNil(stranger.open(try XCTUnwrap(remote.seal(ClientMessage.command(.pause)))))
    }
}
