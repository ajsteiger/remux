import CoreGraphics
import XCTest
@testable import RemuxV2

final class GhosttyPhoneChromeLayoutTests: XCTestCase {
    func testPortraitWithoutKeyboardUsesExpandedChrome() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 390, height: 844),
            isSoftwareKeyboardVisible: false
        )

        XCTAssertFalse(layout.isCompact)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 12)
        XCTAssertEqual(layout.bottomPadding, 4)
    }

    func testKeyboardForcesCompactChromeInPortrait() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 390, height: 844),
            isSoftwareKeyboardVisible: true
        )

        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 8)
        XCTAssertEqual(layout.bottomPadding, 2)
    }

    func testLandscapeUsesCompactChromeWithoutKeyboard() {
        let layout = GhosttyPhoneChromeLayout(
            screenSize: CGSize(width: 844, height: 390),
            isSoftwareKeyboardVisible: false
        )

        XCTAssertTrue(layout.isLandscape)
        XCTAssertTrue(layout.isCompact)
        XCTAssertEqual(layout.surfaceHorizontalPadding, 8)
        XCTAssertEqual(layout.bottomPadding, 2)
    }

    func testKeyboardFrameInsideScreenIsVisible() {
        XCTAssertTrue(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 544, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testKeyboardFrameReportsVisibleOverlapHeight() {
        XCTAssertEqual(
            GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
                frameEnd: CGRect(x: 0, y: 544, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            ),
            300
        )
    }

    func testKeyboardFrameAtBottomEdgeIsHidden() {
        XCTAssertFalse(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testKeyboardFrameAtBottomEdgeReportsNoOverlapHeight() {
        XCTAssertEqual(
            GhosttySoftwareKeyboardVisibility.visibleOverlapHeight(
                frameEnd: CGRect(x: 0, y: 844, width: 390, height: 300),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            ),
            0
        )
    }

    func testZeroHeightKeyboardFrameIsHiddenForHardwareKeyboard() {
        XCTAssertFalse(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 844, width: 390, height: 0),
                screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testKeyboardFrameVisibilityUsesScreenBoundsMaxYForRotation() {
        XCTAssertTrue(
            GhosttySoftwareKeyboardVisibility.isVisible(
                frameEnd: CGRect(x: 0, y: 190, width: 844, height: 200),
                screenBounds: CGRect(x: 0, y: 0, width: 844, height: 390)
            )
        )
    }

    func testSelectionSheetKeepsPreferredHeightWhenBottomStackIsShorter() {
        let bottomReplacementHeight = GhosttySelectionSheetSizing.bottomReplacementHeight(
            bottomChromeHeight: 92,
            softwareKeyboardOverlapHeight: 0
        )

        XCTAssertEqual(
            GhosttySelectionSheetSizing.fixedDetentHeight(
                preferredHeight: 310,
                bottomReplacementHeight: bottomReplacementHeight
            ),
            310
        )
    }

    func testSelectionSheetExpandsToReplaceKeyboardAndChromeStack() {
        let bottomReplacementHeight = GhosttySelectionSheetSizing.bottomReplacementHeight(
            bottomChromeHeight: 92.2,
            softwareKeyboardOverlapHeight: 291.4
        )

        XCTAssertEqual(bottomReplacementHeight, 385)
        XCTAssertEqual(
            GhosttySelectionSheetSizing.fixedDetentHeight(
                preferredHeight: 310,
                bottomReplacementHeight: bottomReplacementHeight
            ),
            385
        )
    }

    func testKeyboardChromeSystemPanelUsesAccessoryHeightOnly() {
        let keyboardReplacement = GhosttyKeyboardChromeSizing.keyboardReplacementHeight(
            keyboardOverlapHeight: 308,
            bottomSafeAreaHeight: 34
        )
        let visibleSystemPanel = GhosttyKeyboardChromeSizing.auxiliaryPanelHeight(
            for: .system,
            isSoftwareKeyboardVisible: true,
            reservedKeyboardReplacementHeight: keyboardReplacement
        )
        let pendingSystemPanel = GhosttyKeyboardChromeSizing.auxiliaryPanelHeight(
            for: .system,
            isSoftwareKeyboardVisible: false,
            reservedKeyboardReplacementHeight: keyboardReplacement
        )

        XCTAssertEqual(visibleSystemPanel, GhosttyKeyboardChromeSizing.systemAccessoryPanelHeight)
        XCTAssertEqual(pendingSystemPanel, GhosttyKeyboardChromeSizing.systemAccessoryPanelHeight)
    }

    func testKeyboardChromeSystemPanelReservesOnlyUncoveredKeyboardHeightDuringHandoff() {
        let keyboardReplacement = GhosttyKeyboardChromeSizing.keyboardReplacementHeight(
            keyboardOverlapHeight: 308,
            bottomSafeAreaHeight: 34
        )
        let currentReplacement = GhosttyKeyboardChromeSizing.keyboardReplacementHeight(
            keyboardOverlapHeight: 134,
            bottomSafeAreaHeight: 34
        )
        let pendingSystemPanel = GhosttyKeyboardChromeSizing.auxiliaryPanelHeight(
            for: .system,
            isSoftwareKeyboardVisible: true,
            reservedKeyboardReplacementHeight: keyboardReplacement,
            currentKeyboardReplacementHeight: currentReplacement,
            reservesSystemKeyboardReplacement: true
        )

        XCTAssertEqual(
            pendingSystemPanel,
            GhosttyKeyboardChromeSizing.systemAccessoryPanelHeight + keyboardReplacement - currentReplacement
        )
    }

    func testKeyboardChromeSystemPanelDropsHandoffReservationWhenKeyboardCatchesUp() {
        let keyboardReplacement = GhosttyKeyboardChromeSizing.keyboardReplacementHeight(
            keyboardOverlapHeight: 308,
            bottomSafeAreaHeight: 34
        )
        let pendingSystemPanel = GhosttyKeyboardChromeSizing.auxiliaryPanelHeight(
            for: .system,
            isSoftwareKeyboardVisible: true,
            reservedKeyboardReplacementHeight: keyboardReplacement,
            currentKeyboardReplacementHeight: keyboardReplacement,
            reservesSystemKeyboardReplacement: true
        )

        XCTAssertEqual(pendingSystemPanel, GhosttyKeyboardChromeSizing.systemAccessoryPanelHeight)
    }

    func testKeyboardChromeKeepsCustomAndSystemBottomOcclusionEquivalent() {
        let keyboardReplacement = GhosttyKeyboardChromeSizing.keyboardReplacementHeight(
            keyboardOverlapHeight: 308,
            bottomSafeAreaHeight: 34
        )
        let systemOcclusion = GhosttyKeyboardChromeSizing.auxiliaryPanelHeight(
            for: .system,
            isSoftwareKeyboardVisible: true,
            reservedKeyboardReplacementHeight: keyboardReplacement
        ) + keyboardReplacement
        let customOcclusion = GhosttyKeyboardChromeSizing.auxiliaryPanelHeight(
            for: .custom,
            isSoftwareKeyboardVisible: false,
            reservedKeyboardReplacementHeight: keyboardReplacement
        )

        XCTAssertEqual(systemOcclusion, customOcclusion)
    }

    func testKeyboardChromeReplacementHeightExcludesBottomSafeArea() {
        XCTAssertEqual(
            GhosttyKeyboardChromeSizing.keyboardReplacementHeight(
                keyboardOverlapHeight: 308,
                bottomSafeAreaHeight: 34
            ),
            274
        )
    }

    func testKeyboardChromeCustomPanelHasNaturalMinimumWithoutKeyboardHistory() {
        XCTAssertEqual(
            GhosttyKeyboardChromeSizing.auxiliaryPanelHeight(
                for: .custom,
                isSoftwareKeyboardVisible: false,
                reservedKeyboardReplacementHeight: 0
            ),
            GhosttyKeyboardChromeSizing.customKeyboardPanelMinimumHeight
        )
    }

    func testChromeDisplayKeepsSystemChromeDuringSystemToCustomHandoff() {
        XCTAssertEqual(
            GhosttyKeyboardChromeDisplayMode.resolve(
                inputMode: .custom,
                handoffTarget: .custom
            ),
            .system
        )
    }

    func testChromeDisplayRendersSystemChromeDuringCustomToSystemHandoff() {
        XCTAssertEqual(
            GhosttyKeyboardChromeDisplayMode.resolve(
                inputMode: .custom,
                handoffTarget: .system
            ),
            .system
        )
    }

    func testChromeDisplayUsesInputModeWithoutHandoff() {
        XCTAssertEqual(
            GhosttyKeyboardChromeDisplayMode.resolve(inputMode: .hidden, handoffTarget: nil),
            .hidden
        )
        XCTAssertEqual(
            GhosttyKeyboardChromeDisplayMode.resolve(inputMode: .system, handoffTarget: nil),
            .system
        )
        XCTAssertEqual(
            GhosttyKeyboardChromeDisplayMode.resolve(inputMode: .custom, handoffTarget: nil),
            .custom
        )
    }

    func testSystemKeyboardReservationOnlyAppliesWhenPresentingSystemKeyboard() {
        XCTAssertFalse(
            GhosttyKeyboardChromeReservation.reservesSystemKeyboardReplacement(
                handoffTarget: .custom
            )
        )
        XCTAssertTrue(
            GhosttyKeyboardChromeReservation.reservesSystemKeyboardReplacement(
                handoffTarget: .system
            )
        )
        XCTAssertTrue(
            GhosttyKeyboardChromeReservation.reservesSystemKeyboardReplacement(
                handoffTarget: nil,
                isAwaitingSystemKeyboardPresentation: true
            )
        )
    }
}
