import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyKitRuntimeTests: XCTestCase {
    func testRuntimeInitializesGhosttyBackend() throws {
        _ = try GhosttyKitRuntime()
    }

    func testSurfaceViewDoesNotDefaultToDesktopSizedFrame() {
        let view = GhosttyKitSurfaceView(frame: .zero)

        XCTAssertEqual(view.frame.size.width, 1)
        XCTAssertEqual(view.frame.size.height, 1)
    }

    func testPhoneTerminalAppearanceUsesAccessibleMobileDensity() {
        var config = ghostty_surface_config_new()

        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .large
        ).apply(to: &config)

        XCTAssertGreaterThanOrEqual(config.font_size, GhosttyTerminalAppearancePolicy.phoneMinimumFontSize)
        XCTAssertEqual(config.font_size, GhosttyTerminalAppearancePolicy.phoneDefaultFontSize)
    }

    func testPhoneTerminalAppearanceScalesWithAccessibilityTextSize() {
        var regularConfig = ghostty_surface_config_new()
        var accessibilityConfig = ghostty_surface_config_new()

        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .large
        ).apply(to: &regularConfig)
        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        ).apply(to: &accessibilityConfig)

        XCTAssertGreaterThan(accessibilityConfig.font_size, regularConfig.font_size)
    }

    func testPhoneTerminalAppearancePreservesExplicitGhosttyFontSize() {
        var config = ghostty_surface_config_new()
        config.font_size = 14

        GhosttyTerminalAppearancePolicy.appearance(
            for: .phone,
            contentSizeCategory: .accessibilityExtraExtraExtraLarge
        ).apply(to: &config)

        XCTAssertEqual(config.font_size, 14)
    }

    func testPadTerminalAppearanceUsesGhosttyDefaultDensity() {
        var config = ghostty_surface_config_new()

        GhosttyTerminalAppearancePolicy.appearance(for: .pad).apply(to: &config)

        XCTAssertEqual(config.font_size, 0)
    }

    func testTmuxHistoryCapturePolicyUsesMobileInitialLimit() {
        var config = ghostty_surface_config_new()

        GhosttyTmuxHistoryCapturePolicy.apply(to: &config)

        XCTAssertEqual(config.tmux_history_capture_limit, 1000)
    }

    func testRuntimeCreatesManualHostSurfaceThatAcceptsOutput() throws {
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let surface = try runtime.makeManualHostSurface(view: view)

        XCTAssertTrue(surface.processOutput(Data("hello from tmux\n".utf8)))
        surface.setBackingExited(true)
    }

    func testManualSurfaceInputRoutesToWriteCallback() async throws {
        let recorder = ManualWriteRecorder()
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let surface = try runtime.makeManualHostSurface(
            view: view,
            onWrite: { data, linefeed in
                recorder.record(data: data, linefeed: linefeed)
                return true
            }
        )

        XCTAssertTrue(surface.sendInput("q"))

        let wrote = await waitUntil {
            recorder.writes().contains { $0.data == Data("q".utf8) }
        }

        XCTAssertTrue(wrote)
        surface.setBackingExited(true)
    }

    func testManualHostSurfaceTmuxBootstrapQueuesControlCommands() async throws {
        let recorder = ManualWriteRecorder()
        let runtime = try GhosttyKitRuntime()
        let view = GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let surface = try runtime.makeManualHostSurface(
            view: view,
            onWrite: { data, linefeed in
                recorder.record(data: data, linefeed: linefeed)
                return true
            }
        )

        var chunk = Data([0x1B])
        chunk.append(Data(
            (
                "P1000p%begin 1778596464 3801170 0\r\n" +
                    "%end 1778596464 3801170 0\r\n" +
                    "%session-changed $209 remux-fidelity-localssh\r\n"
            ).utf8
        ))

        XCTAssertTrue(surface.processOutput(chunk))

        let wroteBootstrapCommands = await waitUntil {
            let writes = recorder.writes().map(\.data)
            return writes.contains { data in
                String(decoding: data, as: UTF8.self).contains("display-message -p '#{version}'")
            } && writes.contains { data in
                String(decoding: data, as: UTF8.self).contains("list-windows")
            }
        }

        XCTAssertTrue(wroteBootstrapCommands)
        surface.setBackingExited(true)
    }

    func testRuntimeCreateSurfaceTreeUsesFocusedLeafIndex() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        defer {
            registry.prepareForRuntimeTeardown()
        }
        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let created = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &leafSurfaces,
            focusedLeafIndex: 1
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(created)
        let secondID = try XCTUnwrap(
            registry.managedSurfaceIDForTesting(handle: leafSurfaces[1])
        )
        XCTAssertEqual(registry.topologySnapshot.selectedActiveLeafID, secondID)

        registry.prepareForRuntimeTeardown()
    }

    func testRuntimeCreateSurfaceTreeCoalescesRegistryChangeNotification() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        defer {
            registry.prepareForRuntimeTeardown()
        }
        var notificationCount = 0
        registry.onChange = {
            notificationCount += 1
        }
        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let created = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &leafSurfaces,
            focusedLeafIndex: 1
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(created)
        XCTAssertEqual(notificationCount, 1)
    }

    func testRuntimeCreateSurfaceCoalescesRegistryChangeNotification() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        defer {
            registry.prepareForRuntimeTeardown()
        }
        var notificationCount = 0
        registry.onChange = {
            notificationCount += 1
        }
        var config = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW
        )

        let surface = withUnsafePointer(to: &config) { configPtr in
            registry.runtimeCreateSurface(
                app: runtime.appHandleForTesting,
                request: ghostty_runtime_create_surface_s(
                    parent: nil,
                    split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                    config: configPtr
                )
            )
        }

        XCTAssertNotNil(surface)
        XCTAssertEqual(notificationCount, 1)
    }

    func testRuntimeSelectSurfaceIgnoresDuplicateSelectionCallback() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        defer {
            registry.prepareForRuntimeTeardown()
        }
        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let created = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &leafSurfaces,
            focusedLeafIndex: 1
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(created)
        let selectedID = try XCTUnwrap(
            registry.managedSurfaceIDForTesting(handle: leafSurfaces[1])
        )
        XCTAssertEqual(registry.topologySnapshot.selectedActiveLeafID, selectedID)

        var notificationCount = 0
        registry.onChange = {
            notificationCount += 1
        }

        registry.runtimeSelectSurface(
            app: runtime.appHandleForTesting,
            surface: leafSurfaces[1]
        )

        XCTAssertEqual(registry.topologySnapshot.selectedActiveLeafID, selectedID)
        XCTAssertEqual(notificationCount, 0)
    }

    func testRuntimeSelectSurfaceCoalescesSelectionChangeNotification() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        defer {
            registry.prepareForRuntimeTeardown()
        }
        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let created = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &leafSurfaces,
            focusedLeafIndex: 1
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(created)
        let firstID = try XCTUnwrap(
            registry.managedSurfaceIDForTesting(handle: leafSurfaces[0])
        )

        var notificationCount = 0
        registry.onChange = {
            notificationCount += 1
        }

        registry.runtimeSelectSurface(
            app: runtime.appHandleForTesting,
            surface: leafSurfaces[0]
        )

        XCTAssertEqual(registry.topologySnapshot.selectedActiveLeafID, firstID)
        XCTAssertEqual(notificationCount, 1)

        registry.runtimeSelectSurface(
            app: runtime.appHandleForTesting,
            surface: leafSurfaces[0]
        )

        XCTAssertEqual(registry.topologySnapshot.selectedActiveLeafID, firstID)
        XCTAssertEqual(notificationCount, 1)
    }

    func testRuntimeCreateSurfaceTreeFocusedAppendSelectsAppendedTopLevel() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        defer {
            registry.prepareForRuntimeTeardown()
        }
        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA701)!
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA702)!
        )
        var firstLeafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let firstCreated = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &firstLeafSurfaces,
            focusedLeafIndex: 0
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(firstCreated)
        let firstFocusedID = try XCTUnwrap(
            registry.managedSurfaceIDForTesting(handle: firstLeafSurfaces[0])
        )
        XCTAssertEqual(registry.topologySnapshot.selectedActiveLeafID, firstFocusedID)

        var thirdConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA703)!
        )
        var fourthConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA704)!
        )
        var secondLeafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)
        var notificationCount = 0
        registry.onChange = {
            notificationCount += 1
        }

        let secondCreated = try withRuntimeTreeRequest(
            firstConfig: &thirdConfig,
            secondConfig: &fourthConfig,
            leafSurfaces: &secondLeafSurfaces,
            focusedLeafIndex: 1
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(secondCreated)
        let secondFocusedID = try XCTUnwrap(
            registry.managedSurfaceIDForTesting(handle: secondLeafSurfaces[1])
        )
        XCTAssertEqual(registry.topologySnapshot.selectedActiveLeafID, secondFocusedID)
        XCTAssertEqual(notificationCount, 1)
    }

    func testRuntimeCallbackBatchCoalescesCreateTreeAndSelectionCallbacks() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        defer {
            registry.prepareForRuntimeTeardown()
        }
        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA711)!
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA712)!
        )
        var firstLeafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let firstCreated = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &firstLeafSurfaces,
            focusedLeafIndex: 0
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(firstCreated)
        let previousSelectedID = try XCTUnwrap(
            registry.managedSurfaceIDForTesting(handle: firstLeafSurfaces[0])
        )
        XCTAssertEqual(registry.topologySnapshot.selectedActiveLeafID, previousSelectedID)

        var thirdConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA713)!
        )
        var fourthConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA714)!
        )
        var secondLeafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)
        let lease = try XCTUnwrap(registry.activeRuntimeCallbackLeaseForTesting)
        var batchError: Error?
        var secondCreated = false
        var notificationCount = 0
        registry.onChange = {
            notificationCount += 1
        }

        registry.withRuntimeCallbackBatch(lease: lease) {
            do {
                secondCreated = try withRuntimeTreeRequest(
                    firstConfig: &thirdConfig,
                    secondConfig: &fourthConfig,
                    leafSurfaces: &secondLeafSurfaces,
                    focusedLeafIndex: 1
                ) { request in
                    registry.runtimeCreateSurfaceTree(
                        app: runtime.appHandleForTesting,
                        request: request
                    )
                }
                registry.runtimeSelectSurface(
                    app: runtime.appHandleForTesting,
                    surface: firstLeafSurfaces[0]
                )
                registry.runtimeSelectSurface(
                    app: runtime.appHandleForTesting,
                    surface: secondLeafSurfaces[1]
                )
            } catch {
                batchError = error
            }
        }

        if let batchError {
            throw batchError
        }
        XCTAssertTrue(secondCreated)
        let finalSelectedID = try XCTUnwrap(
            registry.managedSurfaceIDForTesting(handle: secondLeafSurfaces[1])
        )
        XCTAssertEqual(registry.topologySnapshot.selectedActiveLeafID, finalSelectedID)
        XCTAssertNotEqual(previousSelectedID, finalSelectedID)
        XCTAssertEqual(notificationCount, 1)
    }

    func testRuntimeCreateSurfaceTreeAppendsIndependentRootsWithOverlappingManualUserdata() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        defer {
            registry.prepareForRuntimeTeardown()
        }

        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA501)!
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA502)!
        )
        var firstLeafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let firstCreated = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &firstLeafSurfaces,
            focusedLeafIndex: 0
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(firstCreated)
        XCTAssertEqual(registry.topologySnapshot.topLevels.count, 1)
        let firstTopLevelID = try XCTUnwrap(registry.topologySnapshot.topLevels.first?.id)
        let firstTreeLeafIDs = registry.topologySnapshot.topLevels.first?.leafIDs ?? []

        var overlappingConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA501)!
        )
        var thirdConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            manualUserdata: UnsafeMutableRawPointer(bitPattern: 0xA503)!
        )
        var secondLeafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let secondCreated = try withRuntimeTreeRequest(
            firstConfig: &overlappingConfig,
            secondConfig: &thirdConfig,
            leafSurfaces: &secondLeafSurfaces,
            focusedLeafIndex: 1
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(secondCreated)
        XCTAssertEqual(registry.topologySnapshot.topLevels.count, 2)
        XCTAssertEqual(registry.topologySnapshot.topLevels.first?.id, firstTopLevelID)
        XCTAssertEqual(registry.topologySnapshot.topLevels.first?.leafIDs, firstTreeLeafIDs)
        XCTAssertEqual(registry.topologySnapshot.topLevels.last?.leafIDs.count, 2)
        XCTAssertNotEqual(registry.topologySnapshot.topLevels.first?.id, registry.topologySnapshot.topLevels.last?.id)
    }

    func testRuntimeCloseSurfaceReleasesSurfaceBeforeRuntimeDeinit() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let created = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &leafSurfaces,
            focusedLeafIndex: 0
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertTrue(created)
        let firstID = try XCTUnwrap(
            registry.managedSurfaceIDForTesting(handle: leafSurfaces[0])
        )
        let secondID = try XCTUnwrap(
            registry.managedSurfaceIDForTesting(handle: leafSurfaces[1])
        )

        registry.runtimeCloseSurface(id: firstID, processAlive: false)
        registry.runtimeCloseSurface(id: secondID, processAlive: false)

        XCTAssertTrue(registry.topologySnapshot.topLevels.isEmpty)
        XCTAssertNil(registry.managedSurface(for: firstID))
        XCTAssertNil(registry.managedSurface(for: secondID))
    }

    func testRuntimeCreateSurfaceReleasesSurfaceWhenSplitInsertFails() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        var config = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )

        let surface = withUnsafePointer(to: &config) { configPtr in
            registry.runtimeCreateSurface(
                app: runtime.appHandleForTesting,
                request: ghostty_runtime_create_surface_s(
                    parent: nil,
                    split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                    config: configPtr
                )
            )
        }

        XCTAssertNil(surface)
        XCTAssertTrue(registry.topologySnapshot.topLevels.isEmpty)
    }

    func testRuntimeTmuxProtocolErrorCallbackReachesRegistry() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        var delivered: TmuxControlProtocolError?
        registry.onTmuxProtocolError = { error in
            delivered = error
        }

        runtime.deliverTmuxProtocolErrorForTesting(
            ghostty_tmux_protocol_error_s(
                surface: nil,
                reason: GHOSTTY_TMUX_PROTOCOL_ERROR_REASON_MALFORMED_NOTIFICATION,
                byte_valid: false,
                byte: 0,
                command_valid: true,
                command: GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_OUTPUT
            )
        )

        let expected = TmuxControlProtocolError(
            reason: .malformedNotification,
            command: .output
        )
        XCTAssertEqual(registry.lastTmuxProtocolError, expected)
        XCTAssertEqual(delivered, expected)
    }

    func testResetDoesNotInvalidateRuntimeCallbackLeaseButTeardownDoes() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        let lease = try XCTUnwrap(registry.activeRuntimeCallbackLeaseForTesting)

        registry.reset()

        XCTAssertTrue(registry.acceptsRuntimeCallback(lease))

        registry.prepareForRuntimeTeardown()

        XCTAssertFalse(registry.acceptsRuntimeCallback(lease))
        _ = runtime
    }

    func testRuntimeDeinitInvalidatesOnlyItsOwnCallbackLease() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        var firstRuntime: GhosttyKitRuntime? = try GhosttyKitRuntime(surfaceDelegate: registry)
        let firstLease = try XCTUnwrap(registry.activeRuntimeCallbackLeaseForTesting)
        let secondRuntime = try GhosttyKitRuntime(surfaceDelegate: registry)
        let secondLease = try XCTUnwrap(registry.activeRuntimeCallbackLeaseForTesting)

        XCTAssertNotNil(firstRuntime)
        firstRuntime = nil

        XCTAssertFalse(registry.acceptsRuntimeCallback(firstLease))
        XCTAssertTrue(registry.acceptsRuntimeCallback(secondLease))
        _ = secondRuntime
    }

    func testStaleRuntimeProtocolErrorCallbackCannotMutateRegistry() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        var delivered: TmuxControlProtocolError?
        registry.onTmuxProtocolError = { error in
            delivered = error
        }

        registry.prepareForRuntimeTeardown()
        runtime.deliverTmuxProtocolErrorForTesting(Self.malformedOutputProtocolError())

        XCTAssertNil(registry.lastTmuxProtocolError)
        XCTAssertNil(delivered)
    }

    func testStaleRuntimeTmuxCommandFailureCallbackCannotMutateRegistry() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let staleLease = try XCTUnwrap(registry.makeRuntimeCallbackLease())
        let currentLease = try XCTUnwrap(registry.makeRuntimeCallbackLease())
        let expected = TmuxControlCommandFailure(
            kind: .splitPane,
            reason: .tmuxError("split failed"),
            message: "split failed"
        )
        var delivered: TmuxControlCommandFailure?
        registry.onTmuxCommandFailure = { failure in
            delivered = failure
        }

        registry.runtimeTmuxCommandFailure(
            app: nil,
            failure: expected,
            lease: staleLease
        )
        XCTAssertNil(delivered)

        registry.runtimeTmuxCommandFailure(
            app: nil,
            failure: expected,
            lease: currentLease
        )

        XCTAssertEqual(delivered, expected)
    }

    func testStaleRuntimeCreateSurfaceTreeCallbackIsRejectedBeforeMutation() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let staleRuntime = try GhosttyKitRuntime(surfaceDelegate: registry)
        let staleLease = try XCTUnwrap(registry.activeRuntimeCallbackLeaseForTesting)
        let currentRuntime = try GhosttyKitRuntime(surfaceDelegate: registry)
        XCTAssertFalse(registry.acceptsRuntimeCallback(staleLease))

        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let created = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &leafSurfaces,
            focusedLeafIndex: 0
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: currentRuntime.appHandleForTesting,
                request: request,
                lease: staleLease
            )
        }

        XCTAssertFalse(created)
        XCTAssertTrue(registry.topologySnapshot.topLevels.isEmpty)
        XCTAssertNil(leafSurfaces[0])
        XCTAssertNil(leafSurfaces[1])
        _ = staleRuntime
    }

    func testStaleRuntimeCreateSurfaceCallbackReturnsNilBeforeMutation() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let staleRuntime = try GhosttyKitRuntime(surfaceDelegate: registry)
        let staleLease = try XCTUnwrap(registry.activeRuntimeCallbackLeaseForTesting)
        let currentRuntime = try GhosttyKitRuntime(surfaceDelegate: registry)
        XCTAssertFalse(registry.acceptsRuntimeCallback(staleLease))
        var config = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_WINDOW
        )

        let surface = withUnsafePointer(to: &config) { configPtr in
            registry.runtimeCreateSurface(
                app: currentRuntime.appHandleForTesting,
                request: ghostty_runtime_create_surface_s(
                    parent: nil,
                    split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                    config: configPtr
                ),
                lease: staleLease
            )
        }

        XCTAssertNil(surface)
        XCTAssertTrue(registry.topologySnapshot.topLevels.isEmpty)
        XCTAssertTrue(registry.allManagedSurfaces().isEmpty)
        _ = staleRuntime
    }

    func testRuntimeCreateSurfaceTreeRejectsInvalidFocusedLeafIndexBeforeInstall() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let created = try withRuntimeTreeRequest(
            firstConfig: &firstConfig,
            secondConfig: &secondConfig,
            leafSurfaces: &leafSurfaces,
            focusedLeafIndex: 2
        ) { request in
            registry.runtimeCreateSurfaceTree(
                app: runtime.appHandleForTesting,
                request: request
            )
        }

        XCTAssertFalse(created)
        XCTAssertTrue(registry.topologySnapshot.topLevels.isEmpty)
        XCTAssertNil(leafSurfaces[0])
        XCTAssertNil(leafSurfaces[1])
    }

    func testRuntimeCreateSurfaceTreeRejectsInvalidChildIndexBeforeInstall() throws {
        let registry = GhosttyRuntimeSurfaceRegistry()
        let runtime = try GhosttyKitRuntime(surfaceDelegate: registry)
        var firstConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        var secondConfig = Self.manualRuntimeTreeConfig(
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT
        )
        var leafSurfaces = [ghostty_surface_t?](repeating: nil, count: 2)

        let created = try withUnsafePointer(to: &firstConfig) { firstConfigPtr in
            try withUnsafePointer(to: &secondConfig) { secondConfigPtr in
                var nodes = [
                    ghostty_runtime_surface_tree_node_s(
                        key: GHOSTTY_SURFACE_TREE_NODE_SPLIT,
                        split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        split_ratio: 0.5,
                        left_index: 1,
                        right_index: 3,
                        config: nil
                    ),
                    ghostty_runtime_surface_tree_node_s(
                        key: GHOSTTY_SURFACE_TREE_NODE_LEAF,
                        split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        split_ratio: 0.5,
                        left_index: 0,
                        right_index: 0,
                        config: firstConfigPtr
                    ),
                    ghostty_runtime_surface_tree_node_s(
                        key: GHOSTTY_SURFACE_TREE_NODE_LEAF,
                        split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        split_ratio: 0.5,
                        left_index: 0,
                        right_index: 0,
                        config: secondConfigPtr
                    ),
                ]

                return try nodes.withUnsafeBufferPointer { nodeBuffer in
                    try leafSurfaces.withUnsafeMutableBufferPointer { leafBuffer in
                        let request = ghostty_runtime_create_surface_tree_s(
                            parent: nil,
                            nodes: nodeBuffer.baseAddress,
                            nodes_len: nodeBuffer.count,
                            root_index: 0,
                            leaf_surfaces: leafBuffer.baseAddress,
                            leaf_surfaces_len: leafBuffer.count,
                            focused_leaf_index: 0,
                            focused_leaf_index_valid: true
                        )
                        return registry.runtimeCreateSurfaceTree(
                            app: runtime.appHandleForTesting,
                            request: request
                        )
                    }
                }
            }
        }

        XCTAssertFalse(created)
        XCTAssertTrue(registry.topologySnapshot.topLevels.isEmpty)
        XCTAssertNil(leafSurfaces[0])
        XCTAssertNil(leafSurfaces[1])
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static let runtimeTreeManualWrite: ghostty_surface_manual_write_cb = { _, _, _, _ in
        true
    }

    private static func malformedOutputProtocolError() -> ghostty_tmux_protocol_error_s {
        ghostty_tmux_protocol_error_s(
            surface: nil,
            reason: GHOSTTY_TMUX_PROTOCOL_ERROR_REASON_MALFORMED_NOTIFICATION,
            byte_valid: false,
            byte: 0,
            command_valid: true,
            command: GHOSTTY_TMUX_PROTOCOL_ERROR_COMMAND_OUTPUT
        )
    }

    private static func manualRuntimeTreeConfig(
        context: ghostty_surface_context_e,
        manualUserdata: UnsafeMutableRawPointer? = nil
    ) -> ghostty_surface_config_s {
        var config = ghostty_surface_config_new()
        config.context = context
        config.backing = GHOSTTY_SURFACE_BACKING_MANUAL
        config.manual_write = runtimeTreeManualWrite
        config.manual_userdata = manualUserdata
        return config
    }

    private func withRuntimeTreeRequest<T>(
        firstConfig: inout ghostty_surface_config_s,
        secondConfig: inout ghostty_surface_config_s,
        leafSurfaces: inout [ghostty_surface_t?],
        focusedLeafIndex: Int,
        body: (ghostty_runtime_create_surface_tree_s) throws -> T
    ) throws -> T {
        try withUnsafePointer(to: &firstConfig) { firstConfigPtr in
            try withUnsafePointer(to: &secondConfig) { secondConfigPtr in
                var nodes = [
                    ghostty_runtime_surface_tree_node_s(
                        key: GHOSTTY_SURFACE_TREE_NODE_SPLIT,
                        split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        split_ratio: 0.5,
                        left_index: 1,
                        right_index: 2,
                        config: nil
                    ),
                    ghostty_runtime_surface_tree_node_s(
                        key: GHOSTTY_SURFACE_TREE_NODE_LEAF,
                        split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        split_ratio: 0.5,
                        left_index: 0,
                        right_index: 0,
                        config: firstConfigPtr
                    ),
                    ghostty_runtime_surface_tree_node_s(
                        key: GHOSTTY_SURFACE_TREE_NODE_LEAF,
                        split_direction: GHOSTTY_SPLIT_DIRECTION_RIGHT,
                        split_ratio: 0.5,
                        left_index: 0,
                        right_index: 0,
                        config: secondConfigPtr
                    )
                ]

                return try nodes.withUnsafeBufferPointer { nodeBuffer in
                    try leafSurfaces.withUnsafeMutableBufferPointer { leafBuffer in
                        let request = ghostty_runtime_create_surface_tree_s(
                            parent: nil,
                            nodes: nodeBuffer.baseAddress,
                            nodes_len: nodeBuffer.count,
                            root_index: 0,
                            leaf_surfaces: leafBuffer.baseAddress,
                            leaf_surfaces_len: leafBuffer.count,
                            focused_leaf_index: focusedLeafIndex,
                            focused_leaf_index_valid: true
                        )
                        return try body(request)
                    }
                }
            }
        }
    }
}

private final class ManualWriteRecorder: @unchecked Sendable {
    struct Write: Equatable {
        let data: Data
        let linefeed: Bool
    }

    private let lock = NSLock()
    private var recordedWrites: [Write] = []

    func record(data: Data, linefeed: Bool) {
        lock.withLock {
            recordedWrites.append(Write(data: data, linefeed: linefeed))
        }
    }

    func writes() -> [Write] {
        lock.withLock {
            recordedWrites
        }
    }
}
