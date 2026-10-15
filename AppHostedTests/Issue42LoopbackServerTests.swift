//
//  Issue42LoopbackServerTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network
import Testing

extension AppHostedUITests {
    @Suite("Loopback fixture teardown")
    @MainActor
    struct Issue42LoopbackServerTests {
        @Test("Stopped server rejects queued acceptance and receive without recreating work")
        func stopRejectsLateCallbacks() throws {
            let server = try Issue42LoopbackServer()
            // Hold the same connection delivery used by the listener. No WebKit delegate or
            // request is reconstructed: only the server's queued callback boundary is replayed.
            let native = NWConnection(host: "127.0.0.1", port: .https, using: .tcp)
            let queued = try #require(server.accept(native))
            #expect(server.connectionCount == 1)
            server.stop()
            #expect(queued.closed)
            #expect(server.connectionCount == 0)
            let late = NWConnection(host: "127.0.0.1", port: .https, using: .tcp)
            #expect(server.accept(late) == nil)
            let request = Data("GET \(server.cookiePath)first HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
            queued.didReceive(request, complete: true, failed: false)
            queued.didSendSlowPrefix(failed: false)
            queued.didSendSlowPrefix(failed: true)
            queued.close()
            server.stop()
            #expect(server.stopped)
            #expect(!server.ready)
            #expect(server.requests.isEmpty)
            #expect(server.connectionCount == 0)
            #expect(!server.slowPrefixSent)
        }
    }
}
