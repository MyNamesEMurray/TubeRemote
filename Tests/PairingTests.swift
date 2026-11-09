import XCTest
@testable import TubeRemote

final class PairingTests: XCTestCase {
    func testBothSidesGetSameCodeAndPairAfterBothAccept() {
        let settings = AppSettings()
        let a = Pairing(settings: settings), b = Pairing(settings: settings)
        var paired = 0
        a.onPaired = { _ in paired += 1 }
        b.onPaired = { _ in paired += 1 }
        let bToA: (PairMessage) -> Void = { a.receive($0, send: { _ in }) }
        a.begin { b.receive($0, send: bToA) }

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
        let bToA: (PairMessage) -> Void = { a.receive($0, send: { _ in }) }
        a.begin { b.receive($0, send: bToA) }

        a.answer(false)
        b.answer(true)
        XCTAssertEqual(paired, 0)
        XCTAssertNil(a.prompt)
    }
}
