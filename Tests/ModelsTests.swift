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
                             lastViewer: "WXYZ9876", pro: true)
        let again = try JSONDecoder().decode(SharedConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(again.paired.first?.secret, Data([1, 2, 3]))
        XCTAssertTrue(again.pro)
    }

    func testSessionRules() {
        func r(_ k: String, pro: Bool = false, _ s: Double = 0) -> SessionRules.Remote {
            SessionRules.Remote(key: k, pro: pro, since: Date(timeIntervalSince1970: s))
        }
        XCTAssertTrue(SessionRules.admits(r("a"), among: [], viewerPro: false), "the first remote is always let in")
        XCTAssertFalse(SessionRules.admits(r("b"), among: [r("a")], viewerPro: false))
        XCTAssertTrue(SessionRules.admits(r("b"), among: [r("a")], viewerPro: true), "Pro on the viewer is enough")
        XCTAssertTrue(SessionRules.admits(r("b", pro: true), among: [r("a")], viewerPro: false), "a Pro newcomer is let in")
        XCTAssertTrue(SessionRules.admits(r("b"), among: [r("a", pro: true)], viewerPro: false), "a connected Pro remote covers the newcomer")
        XCTAssertTrue(SessionRules.admits(r("a"), among: [r("a")], viewerPro: false), "a device reconnecting does not count against itself")

        let all = [r("a", 1), r("b", 2), r("c", 3)]
        XCTAssertEqual(SessionRules.excess(all, viewerPro: false), ["b", "c"], "the Pro remote left: keep the one connected longest")
        XCTAssertEqual(SessionRules.excess(all, viewerPro: true), [])
        XCTAssertEqual(SessionRules.excess([r("a", 1), r("b", pro: true, 2)], viewerPro: false), [])
        XCTAssertEqual(SessionRules.excess([r("a")], viewerPro: false), [])
    }

    func testTrimWaitsOneIdleMinuteAndNeverWhilePlaying() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(SessionRules.shouldTrim(playing: true, idleSince: now - 600, now: now))
        XCTAssertFalse(SessionRules.shouldTrim(playing: false, idleSince: nil, now: now))
        XCTAssertFalse(SessionRules.shouldTrim(playing: false, idleSince: now - 59, now: now))
        XCTAssertTrue(SessionRules.shouldTrim(playing: false, idleSince: now - 60, now: now))
    }

    func testQueueKeeperSavesTheVideoPositionAndQueue() {
        let a = VideoItem(videoID: "aaaaaaaaaaa", title: "a", channel: "c", duration: 600)
        let b = VideoItem(videoID: "bbbbbbbbbbb", title: "b", channel: "c", duration: 600)
        func state(_ current: VideoItem?, at position: Double, queue: [VideoItem] = []) -> ViewerState {
            ViewerState(deviceName: "d", current: current, isPlaying: true, position: position, duration: 600, volume: 0.5,
                        queue: queue, history: [])
        }
        XCTAssertNil(QueueKeeper.snapshot(state(nil, at: 0)), "an idle empty viewer says nothing about what was saved")
        let mid = QueueKeeper.snapshot(state(a, at: 372, queue: [b]))
        XCTAssertEqual(mid?.current?.videoID, "aaaaaaaaaaa")
        XCTAssertEqual(mid?.position, 372)
        XCTAssertEqual(mid?.items.map(\.videoID), ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        XCTAssertEqual(mid?.items.first?.startAt, 372, "the video resumes where it was")
        XCTAssertNil(mid?.items.last?.startAt)
        XCTAssertTrue(QueueKeeper.snapshot(state(a, at: 595))?.isEmpty == true, "a video that has all but ended is done, and forgets it")
        XCTAssertNil(QueueKeeper.snapshot(state(a, at: 3, queue: []))?.items.first?.startAt, "no start time for the first seconds")

        let saved = mid!
        XCTAssertFalse(QueueKeeper.shouldSave(saved: saved, new: QueueKeeper.snapshot(state(a, at: 376, queue: [b]))!))
        XCTAssertTrue(QueueKeeper.shouldSave(saved: saved, new: QueueKeeper.snapshot(state(a, at: 384, queue: [b]))!))
        XCTAssertTrue(QueueKeeper.shouldSave(saved: saved, new: QueueKeeper.snapshot(state(b, at: 1))!), "a new video")
        XCTAssertTrue(QueueKeeper.shouldSave(saved: saved, new: QueueKeeper.snapshot(state(a, at: 372))!), "the queue changed")
    }

    func testSavedQueueReadsTheOldListFormat() throws {
        let old = [VideoItem(videoID: "aaaaaaaaaaa", title: "a", channel: "c", duration: 600)]
        Store.write("queue.json", try JSONEncoder().encode(old))
        XCTAssertEqual(AppSettings().savedQueue.items.map(\.videoID), ["aaaaaaaaaaa"])
        Store.write("queue.json", try JSONEncoder().encode(SavedQueue()))
    }

    func testQueueKeeperShortVideoAndEmptiedViewer() {
        let s = VideoItem(videoID: "aaaaaaaaaaa", title: "a", channel: "c", duration: 9)
        func state(_ current: VideoItem?, at position: Double) -> ViewerState {
            ViewerState(deviceName: "d", current: current, isPlaying: true, position: position, duration: 9, volume: 0.5,
                        queue: [], history: [])
        }
        XCTAssertEqual(QueueKeeper.snapshot(state(s, at: 3))?.current?.videoID, "aaaaaaaaaaa", "a 9 second clip is not already finished at 3 s")
        XCTAssertTrue(QueueKeeper.snapshot(state(s, at: 8.8))?.isEmpty == true)
    }

    func testDetailsMessageRoundTrip() throws {
        let d = VideoDetails(videoID: "aaaaaaaaaaa", info: nil,
                             comments: [VideoComment(id: "1", author: "a", text: "hi", likes: "3", age: nil, replies: nil)],
                             commentsStatus: "ok", moreComments: true)
        let data = try JSONEncoder().encode(ServerMessage.details(d))
        guard case .details(let back) = try JSONDecoder().decode(ServerMessage.self, from: data) else { return XCTFail("wrong case") }
        XCTAssertEqual(back, d)
    }

    func testStoryboardSpecIsReadAndAFrameIsAskedFor() async {
        let spec = "https://i.ytimg.com/sb/abc/storyboard3_L$L/$N.jpg?sqp=x|48#27#100#10#10#0#default#rs$aa|160#90#100#10#10#10000#M$M#rs$bb"
        await MainActor.run {
            let s = Storyboard()
            s.load(spec: spec, videoID: "abc", duration: 1000)
            XCTAssertNil(s.frame(at: 25), "the sheet has not arrived yet")
            s.load(spec: nil, videoID: "abc", duration: 1000)
            XCTAssertNil(s.frame(at: 25))
        }
    }

    func testListsMessageRoundTrip() throws {
        let item = VideoItem(videoID: "aaaaaaaaaaa", title: "a", channel: "c", duration: 10)
        let data = try JSONEncoder().encode(ServerMessage.lists(queue: [item], history: []))
        guard case .lists(let q, let h) = try JSONDecoder().decode(ServerMessage.self, from: data) else { return XCTFail("wrong case") }
        XCTAssertEqual(q.map(\.videoID), ["aaaaaaaaaaa"])
        XCTAssertTrue(h.isEmpty)
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
