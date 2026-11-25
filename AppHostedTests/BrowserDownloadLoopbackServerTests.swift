//
//  BrowserDownloadLoopbackServerTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO
import Network
import Testing
import UniformTypeIdentifiers

extension AppHostedUITests {
    @Suite("Loopback fixture teardown")
    @MainActor
    struct BrowserDownloadLoopbackServerTests {
        @Test("Image attachment routes preserve actual PNG bytes despite misleading metadata")
        func imageAttachmentRoutesPreserveActualPNGBytes() async throws {
            let server = try BrowserDownloadLoopbackServer()
            try await server.start()
            defer { server.stop() }

            for route in ["image", "image-as-pdf"] {
                let (body, response) = try await URLSession.shared.data(from: server.url(route))
                let http = try #require(response as? HTTPURLResponse)
                #expect(http.statusCode == 200)
                #expect(body == BrowserDownloadLoopbackServer.fixturePNG)
                let source = try #require(CGImageSourceCreateWithData(body as CFData, nil))
                #expect(CGImageSourceGetCount(source) == 1)
                #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
                #expect(hasSupportedStillImageContent(body))
                #expect(http.mimeType == (route == "image" ? "image/png" : "application/pdf"))
                let disposition = try #require(http.value(forHTTPHeaderField: "Content-Disposition"))
                #expect(disposition.contains(route == "image" ? "valid-image.png" : "document.pdf"))
            }
        }

        @Test("A PDF labelled as PNG still contains the unchanged non-media PDF")
        func pdfWithImageMetadataPreservesPDFBytes() async throws {
            let server = try BrowserDownloadLoopbackServer()
            try await server.start()
            defer { server.stop() }
            let (body, response) = try await URLSession.shared.data(from: server.url("pdf-as-image"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.mimeType == "image/png")
            #expect(body == BrowserDownloadLoopbackServer.fixturePDF)
            let provider = try #require(CGDataProvider(data: body as CFData))
            let pdf = try #require(CGPDFDocument(provider))
            #expect(pdf.numberOfPages == 1)
            #expect(!hasSupportedStillImageContent(body))
            #expect(http.value(forHTTPHeaderField: "Content-Disposition") == "attachment; filename=image.png")
        }

        /// Uses the importer's count, decoded-dimension, and detected-type gates.
        /// Creating an ImageIO source alone does not establish supported image content.
        private func hasSupportedStillImageContent(_ bytes: Data) -> Bool {
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width > 0, image.height > 0,
                  let sourceType = CGImageSourceGetType(source),
                  let type = UTType(sourceType as String),
                  type.conforms(to: .image),
                  !type.conforms(to: .rawImage),
                  type != .livePhoto else {
                return false
            }

            return true
        }

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

        @Test("Qualification request identity is scoped to its loopback fixture")
        func qualificationRequestIdentityIsScopedToLoopbackFixture() async throws {
            let server = try BrowserDownloadLoopbackServer()
            try await server.start()
            defer { server.stop() }

            let requestID = UUID()
            let fixtureURL = try server.url("slow-known")
            var components = try #require(URLComponents(url: fixtureURL, resolvingAgainstBaseURL: false))
            components.queryItems = [
                URLQueryItem(name: "qualificationRequest", value: requestID.uuidString),
            ]
            let requestURL = try #require(components.url)
            let identity = try #require(server.fixtureRequestIdentity(for: requestURL))
            #expect(identity.route == "slow-known")
            #expect(identity.requestID == requestID)

            var unrelatedHost = components
            unrelatedHost.host = "example.invalid"
            let unrelatedURL = try #require(unrelatedHost.url)
            #expect(server.fixtureRequestIdentity(for: unrelatedURL) == nil)

            let missingIdentityURL = try server.url("slow-known")
            #expect(server.fixtureRequestIdentity(for: missingIdentityURL) == nil)
        }

        @Test("Slow-known evidence reports the parsed request and fixture length")
        func slowKnownEvidenceReportsParsedRequestAndFixtureLength() throws {
            let server = try BrowserDownloadLoopbackServer()
            defer { server.stop() }

            let requestID = UUID()
            let connection = try #require(
                server.accept(NWConnection(host: "127.0.0.1", port: .https, using: .tcp)),
            )
            let request = Data(
                (
                    "GET \(server.cookiePath)slow-known?qualificationRequest=\(requestID.uuidString) HTTP/1.1\r\n"
                        + "Host: 127.0.0.1\r\n\r\n"
                ).utf8,
            )
            connection.didReceive(request, complete: false, failed: false)

            let evidence = server.slowKnownEvidence(for: requestID)
            #expect(evidence["requestCount"] == "1")
            #expect(evidence["connectionCount"] == "1")
            #expect(evidence["route"] == "slow-known")
            #expect(evidence["requestParsed"] == "true")
            #expect(evidence["expectedBytes"] == String(BrowserDownloadLoopbackServer.slowPayload.count))
        }

        @Test("Peer EOF during a slow response records pre-deadline closure")
        func peerEOFDuringSlowResponseRecordsClosure() throws {
            let server = try BrowserDownloadLoopbackServer()
            let (connection, requestID) = try slowKnownConnection(server: server)

            connection.didReceive(nil, complete: true, failed: false)

            let evidence = server.slowKnownEvidence(for: requestID)
            #expect(connection.closed)
            #expect(evidence["closeReason"] == "peerClosedDuringResponse")
            #expect(evidence["responseComplete"] == "false")
            #expect(evidence["closedAtUptime"].flatMap(Double.init) != nil)
            let elapsed = try #require(evidence["deadlineElapsedMilliseconds"].flatMap(Int.init))
            #expect((0 ..< 15_000).contains(elapsed))

            connection.close()
            server.stop()
        }

        @Test("Peer receive failure during a slow response records pre-deadline closure")
        func peerReceiveFailureDuringSlowResponseRecordsClosure() throws {
            let server = try BrowserDownloadLoopbackServer()
            let (connection, requestID) = try slowKnownConnection(server: server)

            connection.didReceive(nil, complete: false, failed: true)

            let evidence = server.slowKnownEvidence(for: requestID)
            #expect(connection.closed)
            #expect(evidence["closeReason"] == "peerReceiveFailedDuringResponse")
            #expect(evidence["responseComplete"] == "false")
            #expect(evidence["closedAtUptime"].flatMap(Double.init) != nil)
            let elapsed = try #require(evidence["deadlineElapsedMilliseconds"].flatMap(Int.init))
            #expect((0 ..< 15_000).contains(elapsed))

            connection.close()
            server.stop()
        }

        @Test("Finite response sends the exact remainder once after its release event")
        func finiteResponseCompletesExactBodyAfterRelease() async throws {
            let server = try BrowserDownloadLoopbackServer()
            try await server.start()
            defer { server.stop() }
            let requestID = UUID()
            var released = false
            var duplicateRelease = true
            server.qualificationEvidenceDidChange = {
                let evidence = server.slowKnownEvidence(for: requestID, route: "finite-continuation")
                guard !released, evidence["sendStackState"] == "stackPrefixProcessed",
                      let value = evidence["connectionID"], let connectionID = UUID(uuidString: value)
                else {
                    return
                }

                // Set the guard before release publishes another transport observation.
                released = true
                #expect(evidence["responseComplete"] == "false")
                #expect(!server.releaseFiniteResponse(requestID: UUID(), connectionID: connectionID))
                #expect(!server.releaseFiniteResponse(requestID: requestID, connectionID: UUID()))
                #expect(server.releaseFiniteResponse(requestID: requestID, connectionID: connectionID))
                duplicateRelease = server.releaseFiniteResponse(requestID: requestID, connectionID: connectionID)
            }
            let url = try server.url("finite-continuation").appending(queryItems: [
                URLQueryItem(name: "qualificationRequest", value: requestID.uuidString),
            ])
            let (body, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(released)
            #expect(!duplicateRelease)
            #expect(body == BrowserDownloadLoopbackServer.slowPayload)
            let completed = try await waitForAppHostedPolling(timeout: .seconds(2)) {
                server.slowKnownEvidence(for: requestID, route: "finite-continuation")["responseComplete"] == "true"
            }
            #expect(completed)
            let evidence = server.slowKnownEvidence(for: requestID, route: "finite-continuation")
            #expect(evidence["remainderBytes"] == String(body.count - 262_144))
            #expect(evidence["releaseUptime"].flatMap(Double.init) != nil)
        }

        @Test("Finite release rejects duplicate requests, prefix-pending and stopped connections")
        func finiteReleaseFailsClosed() throws {
            let server = try BrowserDownloadLoopbackServer()
            defer { server.stop() }
            let requestID = UUID()
            let request = Data((
                "GET \(server.cookiePath)finite-continuation?qualificationRequest=\(requestID.uuidString) HTTP/1.1\r\n"
                    + "Host: 127.0.0.1\r\n\r\n"
            ).utf8)
            let connection = try #require(server.accept(NWConnection(host: "127.0.0.1", port: .https, using: .tcp)))
            connection.didReceive(request, complete: false, failed: false)
            #expect(!server.releaseFiniteResponse(requestID: requestID, connectionID: connection.id))
            connection.didSendSlowPrefix(failed: false)
            let duplicate = try #require(server.accept(NWConnection(host: "127.0.0.1", port: .https, using: .tcp)))
            duplicate.didReceive(request, complete: false, failed: false)
            #expect(!server.releaseFiniteResponse(requestID: requestID, connectionID: connection.id))
            server.stop()
            #expect(!server.releaseFiniteResponse(requestID: requestID, connectionID: connection.id))
            #expect(!connection.releaseFiniteRemainder())
        }

        @Test("Original slow-known route cannot release a remainder")
        func slowKnownPreservesPrefixOnlySemantics() throws {
            let server = try BrowserDownloadLoopbackServer()
            defer { server.stop() }
            let (connection, requestID) = try slowKnownConnection(server: server)
            connection.didSendSlowPrefix(failed: false)
            #expect(!connection.releaseFiniteRemainder())
            #expect(!server.releaseFiniteResponse(requestID: requestID, connectionID: connection.id))
            let evidence = server.slowKnownEvidence(for: requestID)
            #expect(evidence["responseComplete"] == "false")
            #expect(evidence["sendStackState"] == "stackPrefixProcessed")
            #expect(evidence["releaseUptime"] == "unavailable")
        }

        private func slowKnownConnection(
            server: BrowserDownloadLoopbackServer,
        ) throws -> (BrowserDownloadLoopbackServer.Connection, UUID) {
            let requestID = UUID()
            let native = NWConnection(host: "127.0.0.1", port: .https, using: .tcp)
            let connection = try #require(server.accept(native))
            let request = Data(
                (
                    "GET \(server.cookiePath)slow-known?qualificationRequest=\(requestID.uuidString) HTTP/1.1\r\n"
                        + "Host: 127.0.0.1\r\n\r\n"
                ).utf8,
            )
            connection.didReceive(request, complete: false, failed: false)
            return (connection, requestID)
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
