import CoreGraphics
import GhosttyKit

enum GhosttyTerminalInitialAttachTransactionResult {
    case succeeded
    case failed(error: any Error, sessionToCloseReusable: GhosttyHostSession?)
}

@MainActor
enum GhosttyTerminalInitialAttachTransaction {
    static func perform(
        view: GhosttyKitSurfaceView,
        size: CGSize,
        surfaceRegistry: GhosttyRuntimeSurfaceRegistry,
        runtimePrecreationController: GhosttyTerminalRuntimePrecreationController,
        hostSessionFactory: GhosttyTerminalHostSessionFactory,
        hostSessionSlot: GhosttyTerminalHostSessionSlot,
        flowID: String
    ) -> GhosttyTerminalInitialAttachTransactionResult {
        var sessionToCloseOnFailure: GhosttyHostSession?

        do {
            surfaceRegistry.reset()
            let runtime = try runtimePrecreationController.claim(
                delegate: surfaceRegistry,
                flowID: flowID
            )
            GhosttyRuntimeTrace.flowEvent(flowID, event: "model.runtime.created")
            let hostSession = hostSessionFactory.makeSession(runtime: runtime)
            sessionToCloseOnFailure = hostSession
            GhosttyRuntimeTrace.flowEvent(flowID, event: "model.transport.prepare.scheduled")
            hostSessionSlot.install(hostSession)
            try hostSession.attach(view: view, size: size)
            GhosttyRuntimeTrace.flowEvent(flowID, event: "model.hostSurface.created")
            GhosttyRuntimeTrace.flowEvent(flowID, event: "model.hostPump.started")

            return .succeeded
        } catch {
            if let sessionToCloseOnFailure {
                hostSessionSlot.clearIfCurrent(sessionToCloseOnFailure)
            }
            return .failed(
                error: error,
                sessionToCloseReusable: sessionToCloseOnFailure
            )
        }
    }
}
