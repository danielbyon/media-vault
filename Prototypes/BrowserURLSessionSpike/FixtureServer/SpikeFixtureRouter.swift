import Foundation

/// Result of routing one fixture request.
struct SpikeFixtureRouteOutcome: Sendable {
    let sequence: Int
    let response: SpikeFixtureResponse
}

/// Deterministic fixture routing for the Spike 2 experiment.
///
/// Routes serve only local synthetic fixtures. Every observation is redacted
/// before it reaches the evidence recorder: header names and presence flags,
/// hashes of sensitive values, and non-secret fixture values are stored, while
/// raw cookie, authorization, token, and body values are not.
final class SpikeFixtureRouter: @unchecked Sendable {
    let evidence: SpikeEvidenceRecorder
    let state: SpikeFixtureState

    init(evidence: SpikeEvidenceRecorder, state: SpikeFixtureState) {
        self.evidence = evidence
        self.state = state
    }

    /// Record a request that could not be parsed as HTTP.
    func routeUnparsable() -> SpikeFixtureRouteOutcome {
        let sequence = evidence.nextSequence()
        evidence.appendNote("request \(sequence): unparsable request line")
        let response = SpikeFixtureResponse.text(status: 400, reason: "Bad Request", body: "malformed request\n")
        return SpikeFixtureRouteOutcome(sequence: sequence, response: response)
    }

    /// Route one parsed request.
    func route(_ request: SpikeFixtureRequest) -> SpikeFixtureRouteOutcome {
        if request.method == "POST", request.path == SpikeContract.Path.reset {
            return handleReset()
        }
        if request.method == "POST", request.path == SpikeContract.Path.appEvent {
            return handleAppEvent(request)
        }
        if request.method == "GET", request.path == SpikeContract.Path.lifecycleMarker {
            return handleLifecycleMarker(request)
        }
        let sequence = evidence.nextSequence()
        return dispatch(request: request, sequence: sequence)
    }

    private func handleReset() -> SpikeFixtureRouteOutcome {
        state.reset()
        evidence.reset()
        let sequence = evidence.nextSequence()
        evidence.appendNote("fixture state reset")
        return SpikeFixtureRouteOutcome(sequence: sequence, response: .text(body: "reset\n"))
    }

    private func handleAppEvent(_ request: SpikeFixtureRequest) -> SpikeFixtureRouteOutcome {
        let sequence = evidence.nextSequence()
        let decoder = JSONDecoder()
        if let events = try? decoder.decode([SpikeAppEvent].self, from: request.body) {
            for event in events {
                evidence.appendAppEvent(event)
            }
        } else if let event = try? decoder.decode(SpikeAppEvent.self, from: request.body) {
            evidence.appendAppEvent(event)
        } else {
            evidence.appendNote("request \(sequence): app event body was not decodable")
        }
        return SpikeFixtureRouteOutcome(
            sequence: sequence,
            response: SpikeFixtureResponse(
                status: 204,
                reason: "No Content",
                headers: [],
                body: Data(),
                throttle: nil,
                declaredByteCount: 0,
                closesAbruptly: false
            )
        )
    }

    private func handleLifecycleMarker(_ request: SpikeFixtureRequest) -> SpikeFixtureRouteOutcome {
        let sequence = evidence.nextSequence()
        let allowedLabels: Set<String> = [
            "background-window-start",
            "foreground-reactivation",
            "process-terminated",
            "process-relaunch",
            "process-relaunch-observed",
        ]
        guard let label = request.queryValue("label"), allowedLabels.contains(label) else {
            return SpikeFixtureRouteOutcome(
                sequence: sequence,
                response: .text(status: 400, reason: "Bad Request", body: "invalid lifecycle marker\n")
            )
        }
        var fields: [String: String] = [:]
        if let taskIdentifier = request.queryValue("taskIdentifier"), Int(taskIdentifier) != nil {
            fields["taskIdentifier"] = taskIdentifier
        }
        if let processInstance = request.queryValue("processInstance"), processInstance.count <= 64 {
            fields["processInstance"] = processInstance
        }
        evidence.recordLifecycleMarker(label: label, fields: fields)
        return SpikeFixtureRouteOutcome(
            sequence: sequence,
            response: .text(status: 204, reason: "No Content", body: "")
        )
    }

    private func dispatch(request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        if let outcome = routeServerControl(request, sequence: sequence) {
            return outcome
        }
        if let outcome = routeResources(request, sequence: sequence) {
            return outcome
        }
        if let outcome = routeRedirects(request, sequence: sequence) {
            return outcome
        }
        if let outcome = routeCookieFlow(request, sequence: sequence) {
            return outcome
        }
        if let outcome = routeHeaderProbes(request, sequence: sequence) {
            return outcome
        }
        if let outcome = routeRequestBodies(request, sequence: sequence) {
            return outcome
        }
        if let outcome = routeAuthentication(request, sequence: sequence) {
            return outcome
        }
        if let outcome = routeLifecycle(request, sequence: sequence) {
            return outcome
        }
        return respond(
            request,
            sequence: sequence,
            response: .text(status: 404, reason: "Not Found", body: "unknown fixture\n")
        )
    }
}
