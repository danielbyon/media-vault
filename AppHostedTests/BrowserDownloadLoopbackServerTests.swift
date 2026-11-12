//
//  BrowserDownloadLoopbackServerTests.swift
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
    struct BrowserDownloadLoopbackServerTests {
        @Test("Complete HTTP responses remain open until the peer closes")
        func completedResponseWaitsForPeerClose() async throws {
            let server = try BrowserDownloadLoopbackServer()
            try await server.start()
            defer { server.stop() }

            let (body, response) = try await URLSession.shared.data(from: server.url("attachment"))
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == 200)
            #expect(body == server.payload)

            let peerClosed = try await waitForAppHostedPolling(timeout: .seconds(2)) {
                server.connectionEvidence.contains { $0["closeReason"] == "peerClosedAfterResponse" }
            }
            #expect(peerClosed)
            #expect(server.connectionEvidence.contains {
                $0["peerClosedAfterResponse"] == "true" && $0["sendStackState"] == "stackProcessed"
            })
        }

        @Test("Incomplete and malformed requests never become parsed readiness evidence")
        func incompleteAndMalformedRequestsDoNotBecomeReadinessEvidence() throws {
            let server = try BrowserDownloadLoopbackServer()

            let incomplete = NWConnection(host: "127.0.0.1", port: .https, using: .tcp)
            let incompleteConnection = try #require(server.accept(incomplete))
            incompleteConnection.didReceive(
                Data("GET \(server.cookiePath)first HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8),
                complete: true,
                failed: false,
            )
            #expect(server.requests.isEmpty)

            let malformed = NWConnection(host: "127.0.0.1", port: .https, using: .tcp)
            let malformedConnection = try #require(server.accept(malformed))
            malformedConnection.didReceive(
                Data("malformed request\r\n\r\n".utf8),
                complete: true,
                failed: false,
            )
            #expect(server.requests.isEmpty)

            server.stop()
        }

        @Test("A connection parses only its first pipelined request")
        func pipelinedBytesDoNotCreateSecondRequest() throws {
            let server = try BrowserDownloadLoopbackServer()
            let pipelinedConnection = try #require(
                server.accept(NWConnection(host: "127.0.0.1", port: .https, using: .tcp)),
            )
            let requests = [
                "GET \(server.cookiePath)first HTTP/1.1\r\n",
                "Host: 127.0.0.1\r\n",
                "\r\n",
                "GET \(server.cookiePath)attachment HTTP/1.1\r\n",
                "Host: 127.0.0.1\r\n\r\n",
            ].joined()

            pipelinedConnection.didReceive(Data(requests.utf8), complete: false, failed: false)

            #expect(server.requests.count == 1)
            #expect(server.requests.first?.path.hasSuffix("/first") == true)
            #expect(server.connectionEvidence.contains {
                $0["connectionID"] == pipelinedConnection.id.uuidString
                    && $0["extraRequestBytesObserved"] == "true"
            })

            let separateCallbacks = try #require(
                server.accept(NWConnection(host: "127.0.0.1", port: .https, using: .tcp)),
            )
            let firstRequest = Data(
                "GET \(server.cookiePath)first HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8,
            )
            let secondRequest = Data(
                "GET \(server.cookiePath)attachment HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8,
            )
            separateCallbacks.didReceive(firstRequest, complete: false, failed: false)
            separateCallbacks.didReceive(secondRequest, complete: false, failed: false)

            #expect(server.requests.count == 2)
            #expect(server.requests.suffix(2).allSatisfy { $0.path.hasSuffix("/first") })
            #expect(server.connectionEvidence.contains {
                $0["connectionID"] == separateCallbacks.id.uuidString
                    && $0["extraRequestBytesObserved"] == "true"
            })
            server.stop()
        }

        @Test("Post-response receive callbacks stay within the fixture budget")
        func postResponseReceiveCallbacksAreBounded() throws {
            let server = try BrowserDownloadLoopbackServer()
            let connection = try #require(
                server.accept(NWConnection(host: "127.0.0.1", port: .https, using: .tcp)),
            )
            let request = Data(
                "GET \(server.cookiePath)first HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8,
            )
            connection.didReceive(request, complete: false, failed: false)

            for _ in 0 ..< 129 {
                connection.didReceive(Data([0x41]), complete: false, failed: false)
            }

            #expect(connection.closed)
            #expect(server.connectionEvidence.contains {
                $0["connectionID"] == connection.id.uuidString
                    && $0["closeReason"] == "postResponseReceiveLimit"
            })
            server.stop()
        }

        @Test("Stopped server rejects queued acceptance and receive without recreating work")
        func stopRejectsLateCallbacks() throws {
            let server = try BrowserDownloadLoopbackServer()
            // Hold the same connection delivery used by the listener. No WebKit delegate or
            // request is reconstructed: only the server's queued callback boundary is replayed.
            let native = NWConnection(host: "127.0.0.1", port: .https, using: .tcp)
            let queued = try #require(server.accept(native))
            #expect(server.connectionCount == 1)
            server.stop()
            #expect(queued.closed)
            #expect(server.connectionCount == 0)
            let stoppedEvidence = server.connectionEvidence
            queued.didFinishResponseSend(failed: false)
            queued.didFinishResponseSend(failed: true)
            #expect(server.connectionEvidence == stoppedEvidence)
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
