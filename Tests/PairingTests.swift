import XCTest
@testable import TubeRemote

final class PairingTests: XCTestCase {
    func testBothSidesGetSameCodeAndPairAfterBothAccept() {
        let settings = AppSettings()
        let a = Pairing(settings: settings), b = Pairing(settings: settings)
        var paired = 0
        a.onPaired = { _ in paired += 1 }
        b.onPaired = { _ in paired += 1 }
        let bToA: (PairMessage) -> Void = { a.receive($0, from: "b", send: { _ in }) }
        a.begin(peer: "b") { b.receive($0, from: "a", send: bToA) }

        XCTAssertNotNil(a.prompt)
        XCTAssertEqual(a.prompt?.code, b.prompt?.code)
        XCTAssertEqual(a.prompt?.code.count, 6)

        a.answer(true)
        XCTAssertEqual(paired, 0)
        b.answer(true)
        XCTAssertEqual(paired, 2)
    }

    func testDeclineCancelsBothSides() {
        let settings = AppSettings()
        let a = Pairing(settings: settings), b = Pairing(settings: settings)
        var paired = 0
        a.onPaired = { _ in paired += 1 }
        b.onPaired = { _ in paired += 1 }
        let bToA: (PairMessage) -> Void = { a.receive($0, from: "b", send: { _ in }) }
        a.begin(peer: "b") { b.receive($0, from: "a", send: bToA) }

        a.answer(false)
        b.answer(true)
        XCTAssertEqual(paired, 0)
        XCTAssertNil(a.prompt)
    }

    func testMessagesFromAnotherDeviceAreIgnored() {
        let settings = AppSettings()
        let a = Pairing(settings: settings), b = Pairing(settings: settings)
        let bToA: (PairMessage) -> Void = { a.receive($0, from: "b", send: { _ in }) }
        a.begin(peer: "b") { b.receive($0, from: "a", send: bToA) }
        let code = a.prompt?.code

        a.receive(.decision(false), from: "c", send: { _ in })
        a.receive(.commit(Data(count: 32)), from: "c", send: { _ in })
        XCTAssertEqual(a.prompt?.code, code)
    }

    func testRevealedKeyMustMatchCommitment() {
        let settings = AppSettings()
        let b = Pairing(settings: settings)
        b.receive(.commit(Data(count: 32)), from: "a", send: { _ in })
        b.receive(.key(pub: Data(count: 32), deviceKey: "k", name: "n"), from: "a", send: { _ in })
        XCTAssertNil(b.prompt)
    }

    func testNewAttemptReplacesStaleOne() {
        let settings = AppSettings()
        let a = Pairing(settings: settings), b = Pairing(settings: settings)
        let bToA: (PairMessage) -> Void = { a.receive($0, from: "b", send: { _ in }) }
        a.begin(peer: "b") { b.receive($0, from: "a", send: bToA) }
        b.answer(true)

        a.begin(peer: "b") { b.receive($0, from: "a", send: bToA) }
        XCTAssertNotNil(b.prompt)
        XCTAssertEqual(a.prompt?.code, b.prompt?.code)
    }
}
