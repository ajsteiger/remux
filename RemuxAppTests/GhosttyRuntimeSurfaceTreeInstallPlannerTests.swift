import XCTest
@testable import Remux

final class GhosttyRuntimeSurfaceTreeInstallPlannerTests: XCTestCase {
    func testReplacesTopLevelContainingParentSurface() {
        let parentLeafID = Self.id(1)
        let siblingLeafID = Self.id(2)
        let otherWindowLeafID = Self.id(3)
        let firstTopLevelID = Self.id(10)
        let secondTopLevelID = Self.id(11)
        let replacementLeafID = Self.id(4)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(
                    id: firstTopLevelID,
                    tree: Self.split(parentLeafID, siblingLeafID),
                    focusedLeafID: siblingLeafID
                ),
                Self.topLevel(id: secondTopLevelID, tree: Self.leaf(otherWindowLeafID)),
            ],
            selectedTopLevelID: firstTopLevelID,
            parentSurfaceID: parentLeafID,
            tree: Self.leaf(replacementLeafID),
            focusedLeafID: replacementLeafID,
            incomingIdentities: [
                .init(id: replacementLeafID, manualUserdata: nil),
            ]
        )

        XCTAssertEqual(plan.kind, .replaceByParent(parentLeafID))
        XCTAssertEqual(plan.topLevels.map(\.id), [firstTopLevelID, secondTopLevelID])
        XCTAssertEqual(plan.topLevels[0].tree, Self.leaf(replacementLeafID))
        XCTAssertEqual(plan.topLevels[0].resolvedFocusedLeafID, replacementLeafID)
        XCTAssertEqual(plan.selectedTopLevelID, firstTopLevelID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, replacementLeafID)
        XCTAssertEqual(plan.debugSummary, .replacedSurfaceTree)
    }

    func testManualIdentityReplacementPreservesFocusedPane() {
        let oldFirstLeafID = Self.id(1)
        let oldFocusedLeafID = Self.id(2)
        let newFirstLeafID = Self.id(3)
        let newFocusedLeafID = Self.id(4)
        let topLevelID = Self.id(10)
        let focusedIdentity = Self.identity(0xA001)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(
                    id: topLevelID,
                    tree: Self.split(oldFirstLeafID, oldFocusedLeafID),
                    focusedLeafID: oldFocusedLeafID
                ),
            ],
            selectedTopLevelID: topLevelID,
            allowManualIdentityReplacement: true,
            tree: Self.split(newFirstLeafID, newFocusedLeafID),
            existingIdentities: [
                .init(id: oldFirstLeafID, manualUserdata: Self.identity(0xA000)),
                .init(id: oldFocusedLeafID, manualUserdata: focusedIdentity),
            ],
            incomingIdentities: [
                .init(id: newFirstLeafID, manualUserdata: Self.identity(0xB000)),
                .init(id: newFocusedLeafID, manualUserdata: focusedIdentity),
            ]
        )

        XCTAssertEqual(plan.kind, .replaceByManualIdentity(topLevelID))
        XCTAssertEqual(plan.topLevels[0].tree, Self.split(newFirstLeafID, newFocusedLeafID))
        XCTAssertEqual(plan.topLevels[0].resolvedFocusedLeafID, newFocusedLeafID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, newFocusedLeafID)
    }

    func testExplicitFocusOverridesManualIdentityPreservation() {
        let oldFirstLeafID = Self.id(1)
        let oldFocusedLeafID = Self.id(2)
        let explicitFocusedLeafID = Self.id(3)
        let identityMatchedLeafID = Self.id(4)
        let topLevelID = Self.id(10)
        let focusedIdentity = Self.identity(0xA101)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(
                    id: topLevelID,
                    tree: Self.split(oldFirstLeafID, oldFocusedLeafID),
                    focusedLeafID: oldFocusedLeafID
                ),
            ],
            selectedTopLevelID: topLevelID,
            allowManualIdentityReplacement: true,
            tree: Self.split(explicitFocusedLeafID, identityMatchedLeafID),
            focusedLeafID: explicitFocusedLeafID,
            existingIdentities: [
                .init(id: oldFirstLeafID, manualUserdata: Self.identity(0xA100)),
                .init(id: oldFocusedLeafID, manualUserdata: focusedIdentity),
            ],
            incomingIdentities: [
                .init(id: explicitFocusedLeafID, manualUserdata: Self.identity(0xB100)),
                .init(id: identityMatchedLeafID, manualUserdata: focusedIdentity),
            ]
        )

        XCTAssertEqual(plan.kind, .replaceByManualIdentity(topLevelID))
        XCTAssertEqual(plan.topLevels[0].resolvedFocusedLeafID, explicitFocusedLeafID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, explicitFocusedLeafID)
    }

    func testParentReplacementTakesPrecedenceOverManualIdentityReplacement() {
        let firstWindowLeafID = Self.id(1)
        let parentLeafID = Self.id(2)
        let firstTopLevelID = Self.id(10)
        let secondTopLevelID = Self.id(11)
        let replacementLeafID = Self.id(3)
        let overlappingIdentity = Self.identity(0xA201)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: firstTopLevelID, tree: Self.leaf(firstWindowLeafID)),
                Self.topLevel(id: secondTopLevelID, tree: Self.leaf(parentLeafID)),
            ],
            selectedTopLevelID: secondTopLevelID,
            parentSurfaceID: parentLeafID,
            allowManualIdentityReplacement: true,
            tree: Self.leaf(replacementLeafID),
            focusedLeafID: replacementLeafID,
            existingIdentities: [
                .init(id: firstWindowLeafID, manualUserdata: overlappingIdentity),
                .init(id: parentLeafID, manualUserdata: Self.identity(0xA202)),
            ],
            incomingIdentities: [
                .init(id: replacementLeafID, manualUserdata: overlappingIdentity),
            ]
        )

        XCTAssertEqual(plan.kind, .replaceByParent(parentLeafID))
        XCTAssertEqual(plan.topLevels[0].leafIDs, [firstWindowLeafID])
        XCTAssertEqual(plan.topLevels[1].leafIDs, [replacementLeafID])
        XCTAssertEqual(plan.selectedTopLevelID, secondTopLevelID)
    }

    func testAppendPreservesValidPreviousSelection() {
        let selectedLeafID = Self.id(1)
        let selectedTopLevelID = Self.id(10)
        let appendedLeafID = Self.id(2)
        let appendedTopLevelID = Self.id(12)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: selectedTopLevelID, tree: Self.leaf(selectedLeafID)),
            ],
            selectedTopLevelID: selectedTopLevelID,
            tree: Self.leaf(appendedLeafID),
            focusedLeafID: appendedLeafID,
            newTopLevelID: appendedTopLevelID
        )

        XCTAssertEqual(plan.kind, .append)
        XCTAssertEqual(plan.topLevels.map(\.id), [selectedTopLevelID, appendedTopLevelID])
        XCTAssertEqual(plan.selectedTopLevelID, selectedTopLevelID)
        XCTAssertNil(plan.presentationTargetSurfaceID)
        XCTAssertEqual(plan.debugSummary, .createdSurfaceTree)
    }

    func testFocusedRuntimeAppendPolicySelectsAppendedTopLevel() {
        let selectedLeafID = Self.id(1)
        let selectedTopLevelID = Self.id(10)
        let appendedLeafID = Self.id(2)
        let appendedTopLevelID = Self.id(12)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: selectedTopLevelID, tree: Self.leaf(selectedLeafID)),
            ],
            selectedTopLevelID: selectedTopLevelID,
            appendSelectionPolicy: .selectAppendedTopLevelWhenFocused,
            tree: Self.leaf(appendedLeafID),
            focusedLeafID: appendedLeafID,
            newTopLevelID: appendedTopLevelID
        )

        XCTAssertEqual(plan.kind, .append)
        XCTAssertEqual(plan.topLevels.map(\.id), [selectedTopLevelID, appendedTopLevelID])
        XCTAssertEqual(plan.selectedTopLevelID, appendedTopLevelID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, appendedLeafID)
        XCTAssertEqual(plan.debugSummary, .createdSurfaceTree)
    }

    func testAppendFallsBackToNewTopLevelWhenSelectionIsStale() {
        let existingLeafID = Self.id(1)
        let existingTopLevelID = Self.id(10)
        let appendedLeafID = Self.id(2)
        let appendedTopLevelID = Self.id(12)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: existingTopLevelID, tree: Self.leaf(existingLeafID)),
            ],
            selectedTopLevelID: Self.id(99),
            tree: Self.leaf(appendedLeafID),
            focusedLeafID: appendedLeafID,
            newTopLevelID: appendedTopLevelID
        )

        XCTAssertEqual(plan.kind, .append)
        XCTAssertEqual(plan.selectedTopLevelID, appendedTopLevelID)
        XCTAssertEqual(plan.presentationTargetSurfaceID, appendedLeafID)
    }

    func testReplacingNonSelectedTopLevelPreservesSelectedTopLevel() {
        let selectedLeafID = Self.id(1)
        let replacedLeafID = Self.id(2)
        let selectedTopLevelID = Self.id(10)
        let replacedTopLevelID = Self.id(11)
        let replacementLeafID = Self.id(3)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: selectedTopLevelID, tree: Self.leaf(selectedLeafID)),
                Self.topLevel(id: replacedTopLevelID, tree: Self.leaf(replacedLeafID)),
            ],
            selectedTopLevelID: selectedTopLevelID,
            replacingTopLevelID: replacedTopLevelID,
            tree: Self.leaf(replacementLeafID),
            focusedLeafID: replacementLeafID
        )

        XCTAssertEqual(plan.kind, .replaceByTopLevel(replacedTopLevelID))
        XCTAssertEqual(plan.topLevels[1].leafIDs, [replacementLeafID])
        XCTAssertEqual(plan.selectedTopLevelID, selectedTopLevelID)
        XCTAssertNil(plan.presentationTargetSurfaceID)
    }

    func testMissingParentAndNoManualOverlapAppends() {
        let existingLeafID = Self.id(1)
        let existingTopLevelID = Self.id(10)
        let appendedLeafID = Self.id(2)
        let appendedTopLevelID = Self.id(12)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: existingTopLevelID, tree: Self.leaf(existingLeafID)),
            ],
            selectedTopLevelID: existingTopLevelID,
            parentSurfaceID: Self.id(99),
            allowManualIdentityReplacement: true,
            tree: Self.leaf(appendedLeafID),
            focusedLeafID: appendedLeafID,
            existingIdentities: [
                .init(id: existingLeafID, manualUserdata: Self.identity(0xA301)),
            ],
            incomingIdentities: [
                .init(id: appendedLeafID, manualUserdata: Self.identity(0xB301)),
            ],
            newTopLevelID: appendedTopLevelID
        )

        XCTAssertEqual(plan.kind, .append)
        XCTAssertEqual(plan.topLevels.map(\.id), [existingTopLevelID, appendedTopLevelID])
        XCTAssertEqual(plan.selectedTopLevelID, existingTopLevelID)
        XCTAssertNil(plan.presentationTargetSurfaceID)
    }

    func testManualOverlapAppendsWhenManualReplacementDisabled() {
        let existingLeafID = Self.id(1)
        let existingTopLevelID = Self.id(10)
        let appendedLeafID = Self.id(2)
        let appendedTopLevelID = Self.id(12)
        let overlappingIdentity = Self.identity(0xA401)

        let plan = makePlan(
            topLevels: [
                Self.topLevel(id: existingTopLevelID, tree: Self.leaf(existingLeafID)),
            ],
            selectedTopLevelID: existingTopLevelID,
            allowManualIdentityReplacement: false,
            tree: Self.leaf(appendedLeafID),
            focusedLeafID: appendedLeafID,
            existingIdentities: [
                .init(id: existingLeafID, manualUserdata: overlappingIdentity),
            ],
            incomingIdentities: [
                .init(id: appendedLeafID, manualUserdata: overlappingIdentity),
            ],
            newTopLevelID: appendedTopLevelID
        )

        XCTAssertEqual(plan.kind, .append)
        XCTAssertEqual(plan.topLevels.map(\.id), [existingTopLevelID, appendedTopLevelID])
        XCTAssertEqual(plan.topLevels[0].leafIDs, [existingLeafID])
        XCTAssertEqual(plan.topLevels[1].leafIDs, [appendedLeafID])
        XCTAssertEqual(plan.selectedTopLevelID, existingTopLevelID)
        XCTAssertNil(plan.presentationTargetSurfaceID)
    }

    private typealias Planner = GhosttyRuntimeSurfaceTreeInstallPlanner

    private func makePlan(
        topLevels: [GhosttyTopLevelSurface] = [],
        selectedTopLevelID: UUID? = nil,
        parentSurfaceID: UUID? = nil,
        replacingTopLevelID: UUID? = nil,
        allowManualIdentityReplacement: Bool = false,
        appendSelectionPolicy: Planner.AppendSelectionPolicy = .preserveExistingSelection,
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID? = nil,
        existingIdentities: [Planner.LeafIdentity] = [],
        incomingIdentities: [Planner.LeafIdentity] = [],
        newTopLevelID: UUID = UUID(uuid: (250, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    ) -> Planner.Plan {
        Planner().plan(
            .init(
                topLevels: topLevels,
                selectedTopLevelID: selectedTopLevelID,
                parentSurfaceID: parentSurfaceID,
                replacingTopLevelID: replacingTopLevelID,
                allowManualIdentityReplacement: allowManualIdentityReplacement,
                appendSelectionPolicy: appendSelectionPolicy,
                tree: tree,
                focusedLeafID: focusedLeafID,
                existingLeafIdentities: existingIdentities,
                incomingLeafIdentities: incomingIdentities,
                newTopLevelID: newTopLevelID
            )
        )
    }

    private static func topLevel(
        id: UUID,
        tree: GhosttySurfaceTree,
        focusedLeafID: UUID? = nil
    ) -> GhosttyTopLevelSurface {
        GhosttyTopLevelSurface(
            id: id,
            tree: tree,
            focusedLeafID: focusedLeafID
        )
    }

    private static func leaf(_ id: UUID) -> GhosttySurfaceTree {
        GhosttySurfaceTree(root: .leaf(id))
    }

    private static func split(
        _ left: UUID,
        _ right: UUID
    ) -> GhosttySurfaceTree {
        GhosttySurfaceTree(
            root: .split(
                axis: .horizontal,
                ratio: 0.5,
                left: .leaf(left),
                right: .leaf(right)
            )
        )
    }

    private static func id(_ value: UInt8) -> UUID {
        UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    private static func identity(_ value: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: value)!
    }
}
