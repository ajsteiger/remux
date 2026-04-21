import XCTest
@testable import RemuxV2

final class GhosttySurfaceKeyEventTests: XCTestCase {
    func testWithCValuePreservesCoreFields() {
        let event = GhosttySurfaceKeyEvent(
            action: .repeat,
            keyCode: .arrowRight,
            text: "x",
            composing: true,
            mods: [.shift, .ctrl],
            consumedMods: [.alt],
            unshiftedCodepoint: 120
        )

        event.withCValue { cValue in
            XCTAssertEqual(cValue.action.rawValue, event.action.rawValue)
            XCTAssertEqual(cValue.keycode, event.keyCode.rawValue)
            XCTAssertTrue(cValue.composing)
            XCTAssertEqual(cValue.mods.rawValue, (GhosttySurfaceKeyEvent.Mods.shift.union(.ctrl)).rawValue)
            XCTAssertEqual(cValue.consumed_mods.rawValue, GhosttySurfaceKeyEvent.Mods.alt.rawValue)
            XCTAssertEqual(cValue.unshifted_codepoint, 120)
            XCTAssertNotNil(cValue.text)
            if let text = cValue.text {
                XCTAssertEqual(String(cString: text), "x")
            }
        }
    }

    func testWithCValueLeavesTextNilWhenAbsent() {
        let event = GhosttySurfaceKeyEvent(
            action: .press,
            keyCode: .escape
        )

        event.withCValue { cValue in
            XCTAssertEqual(cValue.action.rawValue, event.action.rawValue)
            XCTAssertEqual(cValue.keycode, event.keyCode.rawValue)
            XCTAssertNil(cValue.text)
        }
    }
}
