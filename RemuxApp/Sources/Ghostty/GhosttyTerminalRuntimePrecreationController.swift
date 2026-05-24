import GhosttyKit

@MainActor
final class GhosttyTerminalRuntimePrecreationController {
    typealias RuntimeFactory = (GhosttyKitRuntimeSurfaceDelegate?) throws -> GhosttyKitRuntime

    private let runtimeFactory: RuntimeFactory
    private var precreatedRuntime: Result<GhosttyKitRuntime, Error>?

    init(runtimeFactory: @escaping RuntimeFactory) {
        self.runtimeFactory = runtimeFactory
    }

    func precreateIfNeeded(
        delegate: GhosttyKitRuntimeSurfaceDelegate?,
        flowID: String
    ) {
        guard precreatedRuntime == nil else { return }

        let start = GhosttyRuntimeTrace.nowNanos()
        GhosttyRuntimeTrace.flowEvent(flowID, event: "model.runtime.precreate.begin")
        do {
            let runtime = try runtimeFactory(delegate)
            precreatedRuntime = .success(runtime)
            GhosttyRuntimeTrace.flowEvent(
                flowID,
                event: "model.runtime.precreate.end",
                fields: ["elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: start)]
            )
        } catch {
            precreatedRuntime = .failure(error)
            GhosttyRuntimeTrace.flowEvent(
                flowID,
                event: "model.runtime.precreate.failed",
                fields: [
                    "elapsed_ms": GhosttyRuntimeTrace.elapsedMilliseconds(from: start),
                    "error": String(describing: error),
                ]
            )
        }
    }

    func claim(
        delegate: GhosttyKitRuntimeSurfaceDelegate?,
        flowID: String
    ) throws -> GhosttyKitRuntime {
        switch precreatedRuntime {
        case .success(let runtime):
            precreatedRuntime = nil
            GhosttyRuntimeTrace.flowEvent(flowID, event: "model.runtime.precreate.claimed")
            return runtime

        case .failure(let error):
            precreatedRuntime = nil
            GhosttyRuntimeTrace.flowEvent(
                flowID,
                event: "model.runtime.precreate.claimFailed",
                fields: ["error": String(describing: error)]
            )
            throw error

        case nil:
            return try runtimeFactory(delegate)
        }
    }

    func clear() {
        precreatedRuntime = nil
    }

    func applyTerminalSettings(_ settings: TerminalSettings) throws {
        guard case .success(let runtime) = precreatedRuntime else { return }
        try runtime.applyTerminalSettings(settings)
    }
}
