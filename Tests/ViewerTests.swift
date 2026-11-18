import XCTest
@testable import TubeRemote

final class ViewerTests: XCTestCase {
    private func item(_ v: String) -> VideoItem { VideoItem(videoID: v, title: v, channel: "c", duration: 100) }

    /// History is saved on the device, so a viewer starts empty unless a test asks to keep what an earlier one saved.
    private func makeViewer(keepingHistory: Bool = false) -> ViewerController {
        let settings = AppSettings()
        let v = ViewerController(settings: settings, pairing: Pairing(settings: settings), browser: Browser())
        if !keepingHistory { v.history = [] }
        return v
    }

    func testHistorySurvivesARestartAndPreviousUsesIt() {
        let v = makeViewer()
        v.handle(.play(item("aaaaaaaaaaa")), from: nil)
        v.handle(.play(item("bbbbbbbbbbb")), from: nil)
        XCTAssertEqual(v.history.map(\.videoID), ["aaaaaaaaaaa"])

        let w = makeViewer(keepingHistory: true)
        XCTAssertEqual(w.history.map(\.videoID), ["aaaaaaaaaaa"])
        w.handle(.play(item("ccccccccccc")), from: nil)
        w.handle(.previous, from: nil)
        XCTAssertEqual(w.current?.videoID, "aaaaaaaaaaa", "previous plays the most recent video from history")
        XCTAssertEqual(w.queue.first?.videoID, "ccccccccccc", "and the one that was playing goes next in the queue")
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

    func testPlaybackSettingsAreLimited() {
        XCTAssertEqual(qualityLabel("hd1080"), "1080p")
        XCTAssertEqual(qualityLabel("large"), "480p")
        XCTAssertEqual(qualityLabel(nil), "Auto")
        let v = makeViewer()
        v.handle(.setSpeed(9), from: nil)
        v.handle(.setQuality("x');alert(1)//"), from: nil)
        v.handle(.setCaptions(true), from: nil)
        XCTAssertEqual(v.snapshot().speed, 2)
        XCTAssertEqual(v.snapshot().autoQuality, true, "a malformed quality name must be ignored")
        // Captions are only reported on once the player confirms them; until then the state says searching.
        XCTAssertEqual(v.snapshot().captions, false)
        XCTAssertEqual(v.snapshot().captionsStatus, "searching")
        v.handle(.setCaptions(false), from: nil)
        XCTAssertNil(v.snapshot().captionsStatus)
    }

    func testEndSessionStopsEverythingAndKeepsHistory() {
        let v = makeViewer()
        v.handle(.play(item("aaaaaaaaaaa")), from: nil)
        v.handle(.enqueue(item("bbbbbbbbbbb")), from: nil)
        v.endSession()
        XCTAssertNil(v.current)
        XCTAssertTrue(v.queue.isEmpty)
        XCTAssertFalse(v.isPlaying)
        XCTAssertEqual(v.history.map(\.videoID), ["aaaaaaaaaaa"])
    }

    func testPreferredQualityIsChecked_StoredAndOnlyLastsPerVideoWhenOverridden() {
        let settings = AppSettings()
        settings.preferredQuality = "auto"
        let v = ViewerController(settings: settings, pairing: Pairing(settings: settings), browser: Browser())
        v.handle(.setPreferredQuality("x');alert(1)//"), from: nil)
        XCTAssertEqual(v.snapshot().preferredQuality, "auto")
        v.handle(.setPreferredQuality("best"), from: nil)
        XCTAssertEqual(v.snapshot().preferredQuality, "best")
        XCTAssertEqual(v.snapshot().autoQuality, false)

        v.handle(.setPreferredQuality("auto"), from: nil)
        v.handle(.setQuality("large"), from: nil)
        XCTAssertEqual(v.snapshot().autoQuality, false)
        v.handle(.play(item("aaaaaaaaaaa")), from: nil)
        XCTAssertEqual(v.snapshot().autoQuality, true, "the next video returns to the preference")
        settings.preferredQuality = "auto"
    }

    func testQueueIsLimited() {
        let v = makeViewer()
        let many = (0..<300).map { item(String(format: "vid%08d", $0)) }
        for _ in 0..<4 { v.handle(.playlist(many, .addToEnd), from: nil) }
        XCTAssertEqual(v.queue.count, ViewerController.maxQueue)
    }

    func testSleepTimerAtTheEndOfTheQueue() {
        let v = makeViewer()
        v.handle(.setSleepTimer(-1), from: nil)
        XCTAssertNil(v.snapshot().sleepEndsAt, "needs a video")
        v.handle(.play(item("aaaaaaaaaaa")), from: nil)
        v.handle(.enqueue(item("bbbbbbbbbbb")), from: nil)
        v.handle(.setSleepTimer(-1), from: nil)
        XCTAssertNotNil(v.snapshot().sleepEndsAt)
        v.handle(.next, from: nil)
        XCTAssertNotNil(v.snapshot().sleepEndsAt, "the queue is not empty yet, and the timer outlives a video")
        v.handle(.next, from: nil)
        XCTAssertNil(v.snapshot().sleepEndsAt, "the queue ran out")
        XCTAssertFalse(v.isPlaying)
    }

    func testSleepTimerSetsClearsAndRejectsBadValues() {
        let v = makeViewer()
        v.handle(.setSleepTimer(.nan), from: nil)
        XCTAssertNil(v.snapshot().sleepEndsAt)
        v.handle(.setSleepTimer(0), from: nil)
        XCTAssertNil(v.snapshot().sleepEndsAt, "end of video needs a video")
        v.handle(.setSleepTimer(600), from: nil)
        let ends = try? XCTUnwrap(v.snapshot().sleepEndsAt)
        XCTAssertNotNil(ends)
        XCTAssertEqual(ends?.timeIntervalSinceNow ?? 0, 600, accuracy: 5)
        v.handle(.setSleepTimer(nil), from: nil)
        XCTAssertNil(v.snapshot().sleepEndsAt)
        v.handle(.play(item("aaaaaaaaaaa")), from: nil)
        v.handle(.setSleepTimer(0), from: nil)
        XCTAssertNotNil(v.snapshot().sleepEndsAt)
        v.handle(.play(item("bbbbbbbbbbb")), from: nil)
        XCTAssertNil(v.snapshot().sleepEndsAt, "an end-of-video timer ends with its video")
    }

    func testPlaylistPlaysFirstQueuesRestAndSkipsBadIds() {
        let v = makeViewer()
        let list = [item("aaaaaaaaaaa"), item("x');alert(1)//"), item("bbbbbbbbbbb"), item("ccccccccccc")]
        v.handle(.playlist(list, .playNow), from: nil)
        XCTAssertEqual(v.current?.videoID, "aaaaaaaaaaa")
        XCTAssertEqual(v.queue.map(\.videoID), ["bbbbbbbbbbb", "ccccccccccc"])

        v.handle(.playlist([item("ddddddddddd")], .addToEnd), from: nil)
        XCTAssertEqual(v.queue.map(\.videoID), ["bbbbbbbbbbb", "ccccccccccc", "ddddddddddd"])
        v.handle(.playlist([item("eeeeeeeeeee")], .playNext), from: nil)
        XCTAssertEqual(v.queue.first?.videoID, "eeeeeeeeeee")

        let before = v.queue.count
        v.handle(.playlist([item("bad id")], .addToEnd), from: nil)
        XCTAssertEqual(v.queue.count, before, "a playlist with no valid ids changes nothing")
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
