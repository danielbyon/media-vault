import Foundation
import Network

/// Minimal loopback HTTP listener for the Spike 2 fixtures.
final class SpikeFixtureServer: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.danielbyon.mediavault.spike.fixture-server")
    private let router: SpikeFixtureRouter
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: SpikeFixtureConnection] = [:]
    private let connectionLock = NSLock()
    private let readyLock = NSLock()
    private var hasResolved = false
    private var startFailure: Error?

    init(port: UInt16, router: SpikeFixtureRouter) {
        self.port = port
        self.router = router
    }

    /// Begin listening. Readiness and failure are reported on standard output
    /// because the server has no other channel to the supervising process.
    func start() throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw SpikeFixtureServerError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            print("fixture-server accepted connection")
            fflush(stdout)
            guard let self else {
                connection.cancel()
                return
            }
            let session = SpikeFixtureConnection(connection: connection, queue: self.queue, router: self.router)
            session.onFinish = { [weak self] finished in
                self?.releaseConnection(finished)
            }
            self.retainConnection(session)
            session.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.resolveReady()
            case let .failed(error):
                self.resolveFailure(error)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    /// Stop listening.
    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Keep an accepted connection alive while it serves its response.
    private func retainConnection(_ session: SpikeFixtureConnection) {
        connectionLock.lock()
        activeConnections[ObjectIdentifier(session)] = session
        connectionLock.unlock()
    }

    /// Release a connection that has finished serving.
    private func releaseConnection(_ session: SpikeFixtureConnection) {
        connectionLock.lock()
        activeConnections[ObjectIdentifier(session)] = nil
        connectionLock.unlock()
    }

    private func resolveReady() {
        readyLock.lock()
        let alreadyResolved = hasResolved
        hasResolved = true
        readyLock.unlock()
        guard !alreadyResolved else { return }
        print("fixture-server ready host=\(SpikeContract.primaryHost) port=\(port)")
        fflush(stdout)
    }

    private func resolveFailure(_ error: Error) {
        readyLock.lock()
        let alreadyResolved = hasResolved
        hasResolved = true
        startFailure = error
        readyLock.unlock()
        guard !alreadyResolved else { return }
        print("fixture-server failed: \(error)")
        fflush(stdout)
        exit(1)
    }
}

/// Startup failures for the fixture listener.
enum SpikeFixtureServerError: Error {
    case invalidPort(UInt16)
}
