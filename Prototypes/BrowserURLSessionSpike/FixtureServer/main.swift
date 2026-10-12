import Foundation
import Network

/// Entry point for the Spike 2 host-process fixture server.
///
/// The server runs as a macOS process that is completely independent from the
/// iOS application under test. Because the iOS Simulator shares the host
/// network stack, the application can reach these fixtures at 127.0.0.1 while
/// the server keeps running across app suspension, process termination, and
/// relaunch.
let arguments = CommandLine.arguments

func argumentValue(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

let portValue = UInt16(argumentValue("--port") ?? "") ?? UInt16(SpikeContract.port)
let runIdentifier = argumentValue("--run-id") ?? ISO8601DateFormatter().string(from: Date())
let defaultEvidencePath = FileManager.default.currentDirectoryPath
    + "/.build/" + SpikeContract.evidenceDirectoryName + "/fixture-server.json"
let evidencePath = argumentValue("--evidence") ?? defaultEvidencePath
let evidenceURL = URL(fileURLWithPath: evidencePath)

let authorizationMaterial = "\(SpikeContract.syntheticUserName):\(SpikeContract.syntheticPassword)"
let redactionTerms = [
    SpikeContract.syntheticPassword,
    SpikeContract.syntheticAuthCookieValue,
    Data(authorizationMaterial.utf8).base64EncodedString(),
]

let evidence = SpikeEvidenceRecorder(runIdentifier: runIdentifier, redactionTerms: redactionTerms)
evidence.attachExportURL(evidenceURL)
let state = SpikeFixtureState()
let router = SpikeFixtureRouter(evidence: evidence, state: state)
let server = SpikeFixtureServer(port: portValue, router: router)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
// Top-level code in this file is main-actor isolated, so the signal handlers
// run on the main queue that dispatchMain() drains below. A private queue
// would trip the runtime isolation check inside the handler.
let signalQueue = DispatchQueue.main
// The sources must stay strongly referenced for the lifetime of the process:
// a released dispatch source is cancelled and stops delivering signals, which
// would leave the server running after the harness asks it to stop.
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler {
        evidence.appendNote("fixture server stopping on signal \(signalNumber)")
        evidence.persist()
        server.stop()
        // _exit skips atexit handlers and static destructors: running the
        // full exit path from a dispatch source while the main thread is
        // parked in dispatchMain() can deadlock the process teardown, which
        // would leave the fixture server running after the harness stopped.
        fflush(stdout)
        fflush(stderr)
        _exit(0)
    }
    source.resume()
    signalSources.append(source)
}

do {
    try server.start()
    evidence.appendNote("fixture server ready on \(SpikeContract.primaryHost):\(portValue)")
    evidence.persist()
    print("fixture-server starting host=\(SpikeContract.primaryHost) port=\(portValue) evidence=\(evidenceURL.path)")
    print("fixture-server diagnostics=\(SpikeFixtureDiagnostics.isEnabled)")
    fflush(stdout)
} catch {
    print("fixture-server failed: \(error)")
    fflush(stdout)
    exit(1)
}

// Keep the process alive. Dispatch sources for the listener and for signal
// handling are attached to their own queues, so the main thread only has to
// stay parked.
let keepAliveTimer = Timer(timeInterval: 3_600, repeats: true) { _ in }
RunLoop.main.add(keepAliveTimer, forMode: .common)
RunLoop.main.run()
