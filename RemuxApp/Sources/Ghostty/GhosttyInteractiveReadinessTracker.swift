import CoreGraphics
import Foundation

struct GhosttyInteractiveSurfaceReadinessState: Equatable {
    let selected: Bool
    let visible: Bool
    let focused: Bool
    let runtimePresentationReady: Bool
    let presentationReady: Bool

    var isInteractive: Bool {
        selected && visible && focused && runtimePresentationReady && presentationReady
    }
}

struct GhosttyInteractiveReadinessCompletion: Equatable {
    let flow: String
    let surfaceID: UUID
    let rendered: Bool
    let size: CGSize?
    let state: GhosttyInteractiveSurfaceReadinessState
}

struct GhosttyInteractiveReadinessWaiting: Equatable {
    let surfaceID: UUID
    let rendered: Bool
    let size: CGSize?
    let state: GhosttyInteractiveSurfaceReadinessState
    let pendingFlows: [String]
}

struct GhosttyInteractiveReadinessEvaluation: Equatable {
    let completions: [GhosttyInteractiveReadinessCompletion]
    let waiting: GhosttyInteractiveReadinessWaiting?
}

final class GhosttyInteractiveReadinessTracker {
    private struct Pending {
        let flow: String
        let surfaceID: UUID
    }

    private struct RenderState {
        let rendered: Bool
        let size: CGSize?
    }

    private var pendingByFlow: [String: Pending] = [:]
    private var renderedSurfaces: [UUID: RenderState] = [:]

    func reset() {
        pendingByFlow = [:]
        renderedSurfaces = [:]
    }

    func begin(flow: String, surfaceID: UUID) {
        pendingByFlow[flow] = Pending(flow: flow, surfaceID: surfaceID)
    }

    func removeSurface(_ surfaceID: UUID) {
        renderedSurfaces[surfaceID] = nil
        pendingByFlow = pendingByFlow.filter { _, pending in
            pending.surfaceID != surfaceID
        }
    }

    func pendingFlows(for surfaceID: UUID) -> [String] {
        pendingByFlow.values
            .filter { $0.surfaceID == surfaceID }
            .map(\.flow)
            .sorted()
    }

    func renderStatus(for surfaceID: UUID) -> (rendered: Bool, size: CGSize?) {
        let state = renderedSurfaces[surfaceID]
        return (state?.rendered ?? false, state?.size)
    }

    func recordRender(
        surfaceID: UUID,
        size: CGSize,
        state: GhosttyInteractiveSurfaceReadinessState
    ) -> GhosttyInteractiveReadinessEvaluation {
        let rendered = size.width > 1 && size.height > 1
        renderedSurfaces[surfaceID] = RenderState(
            rendered: rendered,
            size: rendered ? size : nil
        )
        return evaluate(
            surfaceID: surfaceID,
            state: state,
            completions: completeReadyPending(surfaceID: surfaceID, state: state)
        )
    }

    func updatePresentation(
        surfaceID: UUID,
        state: GhosttyInteractiveSurfaceReadinessState
    ) -> GhosttyInteractiveReadinessEvaluation {
        evaluate(
            surfaceID: surfaceID,
            state: state,
            completions: completeReadyPending(surfaceID: surfaceID, state: state)
        )
    }

    private func evaluate(
        surfaceID: UUID,
        state: GhosttyInteractiveSurfaceReadinessState,
        completions: [GhosttyInteractiveReadinessCompletion]
    ) -> GhosttyInteractiveReadinessEvaluation {
        guard completions.isEmpty else {
            return GhosttyInteractiveReadinessEvaluation(
                completions: completions,
                waiting: nil
            )
        }

        let pendingFlows = pendingFlows(for: surfaceID)
        guard !pendingFlows.isEmpty else {
            return GhosttyInteractiveReadinessEvaluation(
                completions: [],
                waiting: nil
            )
        }

        let renderState = renderedSurfaces[surfaceID]
        return GhosttyInteractiveReadinessEvaluation(
            completions: [],
            waiting: GhosttyInteractiveReadinessWaiting(
                surfaceID: surfaceID,
                rendered: renderState?.rendered ?? false,
                size: renderState?.size,
                state: state,
                pendingFlows: pendingFlows
            )
        )
    }

    private func completeReadyPending(
        surfaceID: UUID,
        state: GhosttyInteractiveSurfaceReadinessState
    ) -> [GhosttyInteractiveReadinessCompletion] {
        guard state.isInteractive else { return [] }
        guard renderedSurfaces[surfaceID]?.rendered == true else { return [] }

        var completions: [GhosttyInteractiveReadinessCompletion] = []
        for (flow, pending) in pendingByFlow where pending.surfaceID == surfaceID {
            let renderState = renderedSurfaces[surfaceID]
            completions.append(
                GhosttyInteractiveReadinessCompletion(
                    flow: flow,
                    surfaceID: surfaceID,
                    rendered: true,
                    size: renderState?.size,
                    state: state
                )
            )
        }
        for completion in completions {
            pendingByFlow[completion.flow] = nil
        }
        return completions
    }
}
