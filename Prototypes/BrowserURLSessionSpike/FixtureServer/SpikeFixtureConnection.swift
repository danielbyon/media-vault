import Foundation
import Network

/// One accepted fixture connection.
///
/// All Network framework access happens on the connection's serial queue, so
/// the unchecked sendability annotation only covers that serialization.
final class SpikeFixtureConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let router: SpikeFixtureRouter
    /// Called once when the connection is finished so the server can release
    /// its strong reference.
    var onFinish: ((SpikeFixtureConnection) -> Void)?
    private var didFinish = false
    private var buffer: [UInt8] = []
    private var handledRequest = false
    private var clientClosedEarly = false
    private var activeSequence: Int?
    private var sentByteCount = 0
    private var reportedOutcome = false

    init(connection: NWConnection, queue: DispatchQueue, router: SpikeFixtureRouter) {
        self.connection = connection
        self.queue = queue
        self.router = router
    }

    /// Begin receiving the request.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.log("connection state \(state)")
            switch state {
            case .failed, .cancelled:
                self.clientClosedEarly = true
                self.reportOutcome(completed: false, note: "client-closed")
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.log("receive data=\(data?.count ?? 0) complete=\(isComplete) error=\(String(describing: error))")
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
            }
            if error != nil {
                self.clientClosedEarly = true
                self.reportOutcome(completed: false, note: "receive-failed")
                self.connection.cancel()
                return
            }
            if !self.handledRequest,
               let expected = SpikeFixtureHTTPRequestParser.expectedRequestLength(in: self.buffer),
               self.buffer.count >= expected {
                self.handledRequest = true
                self.handleBufferedRequest()
                return
            }
            if isComplete {
                self.clientClosedEarly = true
                self.reportOutcome(completed: false, note: "request-incomplete")
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    /// Diagnostic line for the fixture server log.
    private func log(_ message: String) {
        guard SpikeFixtureDiagnostics.isEnabled else { return }
        FileHandle.standardError.write(Data(("[\(Date().timeIntervalSince1970)] " + message + "\n").utf8))
    }

    private func handleBufferedRequest() {
        guard let request = SpikeFixtureHTTPRequestParser.parse(buffer) else {
            let outcome = router.routeUnparsable()
            send(sequence: outcome.sequence, response: outcome.response)
            return
        }
        let outcome = router.route(request)
        send(sequence: outcome.sequence, response: outcome.response)
    }

    private func send(sequence: Int, response: SpikeFixtureResponse) {
        activeSequence = sequence
        sentByteCount = 0
        let body = [UInt8](response.body)
        let declared = response.declaredByteCount ?? body.count
        let head = response.headData(bodyLength: declared)
        connection.send(content: head, isComplete: false, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.clientClosedEarly = error.map(Self.isPeerDisconnect) == true
                self.reportOutcome(completed: false, note: "head-send-failed")
                self.connection.cancel()
                return
            }
            self.streamBody(sequence: sequence, response: response, body: body, offset: 0)
        })
    }

    private func streamBody(sequence: Int, response: SpikeFixtureResponse, body: [UInt8], offset: Int) {
        guard !clientClosedEarly else {
            reportOutcome(completed: false, note: "client-closed-mid-response")
            connection.cancel()
            return
        }
        guard offset < body.count else {
            finishBody(sequence: sequence, response: response)
            return
        }
        let chunkBytes = response.throttle?.chunkBytes ?? body.count
        let end = min(offset + chunkBytes, body.count)
        let isLast = end >= body.count
        let chunk = Data(body[offset..<end])
        let completion = NWConnection.SendCompletion.contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.clientClosedEarly = error.map(Self.isPeerDisconnect) == true
                self.reportOutcome(completed: false, note: "body-send-failed")
                self.connection.cancel()
                return
            }
            self.sentByteCount += end - offset
            self.router.evidence.recordSendProgress(sequence: sequence, sentByteCount: self.sentByteCount)
            guard !isLast else {
                self.finishBody(sequence: sequence, response: response)
                return
            }
            let delay = response.throttle?.chunkDelayMilliseconds ?? 0
            self.queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                self?.streamBody(sequence: sequence, response: response, body: body, offset: end)
            }
        }
        connection.send(content: chunk, isComplete: isLast && !response.closesAbruptly, completion: completion)
    }

    private func finishBody(sequence: Int, response: SpikeFixtureResponse) {
        connection.cancel()
        if response.closesAbruptly {
            reportOutcome(completed: false, note: "server-closed-mid-response")
        } else {
            reportOutcome(completed: true, note: response.throttle == nil ? nil : "throttled-complete")
        }
    }

    private func reportOutcome(completed: Bool, note: String?) {
        notifyFinished()
        guard let sequence = activeSequence, !reportedOutcome else { return }
        reportedOutcome = true
        router.evidence.recordSendOutcome(
            sequence: sequence,
            sentByteCount: sentByteCount,
            completed: completed,
            clientClosedEarly: !completed && clientClosedEarly
        )
        if let note {
            router.evidence.appendNote("request \(sequence): \(note)")
        }
    }

    private static func isPeerDisconnect(_ error: NWError) -> Bool {
        guard case let .posix(code) = error else { return false }
        return code == .ECANCELED || code == .ECONNRESET || code == .EPIPE
    }

    private func notifyFinished() {
        guard !didFinish else { return }
        didFinish = true
        onFinish?(self)
    }
}
