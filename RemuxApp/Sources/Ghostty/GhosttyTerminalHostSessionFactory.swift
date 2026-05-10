import GhosttyKit

@MainActor
final class GhosttyTerminalHostSessionFactory {
    typealias TransportFactory = (TmuxConnectionTarget) -> any TmuxControlTransport

    private let target: TmuxConnectionTarget
    private let transportFactory: TransportFactory
    private let flowID: String
    private let eventHandler: GhosttyHostSession.EventHandler

    init(
        target: TmuxConnectionTarget,
        transportFactory: @escaping TransportFactory,
        flowID: String,
        eventHandler: @escaping GhosttyHostSession.EventHandler
    ) {
        self.target = target
        self.transportFactory = transportFactory
        self.flowID = flowID
        self.eventHandler = eventHandler
    }

    func makeSession(runtime: GhosttyKitRuntime) -> GhosttyHostSession {
        let transport = transportFactory(target)
        GhosttyRuntimeTrace.flowEvent(flowID, event: "model.transport.created")
        return GhosttyHostSession(
            runtime: runtime,
            transport: transport,
            flowID: flowID,
            eventHandler: eventHandler
        )
    }
}
