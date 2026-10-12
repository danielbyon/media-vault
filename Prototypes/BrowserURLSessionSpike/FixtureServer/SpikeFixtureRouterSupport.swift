import Foundation

/// Route sections, response builders, and redaction helpers for the fixture
/// router. Kept separate from the dispatch entry points so each section stays
/// small enough to review.
extension SpikeFixtureRouter {
    // MARK: - Section routers

    func routeServerControl(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome? {
        switch (request.method, request.path) {
        case ("GET", SpikeContract.Path.health):
            return respond(request, sequence: sequence, response: .text(body: "ready\n"))
        case ("GET", SpikeContract.Path.menu):
            return respond(
                request,
                sequence: sequence,
                response: .text(body: SpikeFixtureHTML.menu(), contentType: "text/html; charset=utf-8")
            )
        case ("GET", SpikeContract.Path.evidence):
            let json = String(decoding: evidence.exportJSON(), as: UTF8.self)
            return respond(request, sequence: sequence, response: .text(body: json, contentType: "application/json"))
        case ("GET", SpikeContract.Path.exportEvidence):
            evidence.persist()
            return respond(request, sequence: sequence, response: .text(body: "exported\n"))
        default:
            return nil
        }
    }

    func routeResources(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome? {
        switch (request.method, request.path) {
        case ("GET", SpikeContract.Path.stillControl), ("GET", SpikeContract.Path.stillTransfer):
            return respondWithAsset(request, sequence: sequence, asset: .stillImage)
        case ("GET", SpikeContract.Path.clipControl), ("GET", SpikeContract.Path.clipTransfer):
            return respondWithAsset(request, sequence: sequence, asset: .clipVideo)
        case ("GET", SpikeContract.Path.attachmentControl):
            return respondWithAsset(request, sequence: sequence, asset: .clipVideo, attachment: true)
        case ("GET", SpikeContract.Path.attachmentTransfer):
            return respondWithAsset(request, sequence: sequence, asset: .largeAttachment, attachment: true)
        default:
            return nil
        }
    }

    func routeRedirects(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome? {
        switch (request.method, request.path) {
        case ("GET", SpikeContract.Path.redirectControlSingle):
            return respond(request, sequence: sequence, response: redirect(to: SpikeContract.Path.stillControl))
        case ("GET", SpikeContract.Path.redirectControlChain):
            return respond(
                request,
                sequence: sequence,
                response: redirect(to: SpikeContract.Path.redirectChainControlSecond)
            )
        case ("GET", SpikeContract.Path.redirectChainControlSecond):
            return respond(request, sequence: sequence, response: redirect(to: SpikeContract.Path.clipControl))
        case ("GET", SpikeContract.Path.redirectTransferSingle):
            return respond(request, sequence: sequence, response: redirect(to: SpikeContract.Path.stillTransfer))
        case ("GET", SpikeContract.Path.redirectTransferChain):
            return respond(
                request,
                sequence: sequence,
                response: redirect(to: SpikeContract.Path.redirectChainTransferSecond)
            )
        case ("GET", SpikeContract.Path.redirectChainTransferSecond):
            return respond(request, sequence: sequence, response: redirect(to: SpikeContract.Path.clipTransfer))
        case ("GET", SpikeContract.Path.credentialControlSameOrigin),
             ("GET", SpikeContract.Path.credentialTransferSameOrigin):
            return respond(request, sequence: sequence, response: redirect(to: SpikeContract.Path.credentialTerminal))
        case ("GET", SpikeContract.Path.credentialControlCrossOrigin),
             ("GET", SpikeContract.Path.credentialTransferCrossOrigin):
            return respond(request, sequence: sequence, response: redirect(to: crossOriginTerminalURL()))
        case ("GET", SpikeContract.Path.credentialTerminal):
            return respond(request, sequence: sequence, response: .text(body: credentialSummary(request)))
        default:
            return nil
        }
    }

    func routeCookieFlow(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome? {
        switch (request.method, request.path) {
        case ("GET", SpikeContract.Path.login):
            return respond(
                request,
                sequence: sequence,
                response: .text(body: SpikeFixtureHTML.login(), contentType: "text/html; charset=utf-8")
            )
        case ("POST", SpikeContract.Path.loginSubmit):
            return handleLoginSubmit(request, sequence: sequence)
        case ("GET", SpikeContract.Path.vaultGuard):
            return respond(
                request,
                sequence: sequence,
                response: guardResponse(
                    title: "Vault fixture",
                    controlLabel: SpikeAnchor.loginControlLink,
                    controlPath: SpikeContract.Path.vaultControl,
                    transferLabel: SpikeAnchor.loginTransferLink,
                    transferPath: SpikeContract.Path.vaultTransfer,
                    notes: "Both resources answer with a session-cookie check; signing in is not required to reach this page."
                )
            )
        case ("GET", SpikeContract.Path.vaultControl), ("GET", SpikeContract.Path.vaultTransfer):
            return handleProtectedAsset(request, sequence: sequence)
        case ("GET", SpikeContract.Path.scopeSetup):
            return handleScopeSetup(request, sequence: sequence)
        case ("GET", SpikeContract.Path.scopeSetupOtherHost):
            return handleScopeSetupOtherHost(request, sequence: sequence)
        case ("GET", SpikeContract.Path.scopeProbeControl), ("GET", SpikeContract.Path.scopeProbeTransfer):
            return respond(request, sequence: sequence, response: .text(body: scopeSummary(request)))
        default:
            return nil
        }
    }

    func routeHeaderProbes(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome? {
        switch (request.method, request.path) {
        case ("GET", SpikeContract.Path.refererGuard):
            return respond(request, sequence: sequence, response: guardResponse(
                title: "Referer fixture",
                controlLabel: SpikeAnchor.refererControlLink,
                controlPath: SpikeContract.Path.refererControl,
                transferLabel: SpikeAnchor.refererTransferLink,
                transferPath: SpikeContract.Path.refererTransfer,
                notes: "The asset requires a Referer whose path is the guard page."
            ))
        case ("GET", SpikeContract.Path.refererControl), ("GET", SpikeContract.Path.refererTransfer):
            return handleRefererAsset(request, sequence: sequence)
        case ("GET", SpikeContract.Path.originGuard):
            return respond(request, sequence: sequence, response: guardResponse(
                title: "Origin fixture",
                controlLabel: SpikeAnchor.originControlLink,
                controlPath: SpikeContract.Path.originControl,
                transferLabel: SpikeAnchor.originTransferLink,
                transferPath: SpikeContract.Path.originTransfer,
                notes: "The asset requires an Origin header that top-level navigations do not send."
            ))
        case ("GET", SpikeContract.Path.originControl), ("GET", SpikeContract.Path.originTransfer):
            return handleOriginAsset(request, sequence: sequence)
        case ("GET", SpikeContract.Path.userAgentGuard):
            return respond(request, sequence: sequence, response: guardResponse(
                title: "User agent fixture",
                controlLabel: SpikeAnchor.userAgentControlLink,
                controlPath: SpikeContract.Path.userAgentControl,
                transferLabel: SpikeAnchor.userAgentTransferOwnedLink,
                transferPath: SpikeContract.Path.userAgentTransferOwned,
                notes: "A second transfer control reports the default URLSession user agent.",
                extra: SpikeFixtureHTML.controlLink(
                    label: SpikeAnchor.userAgentTransferDefaultLink,
                    path: SpikeContract.Path.userAgentTransferDefault
                )
            ))
        case ("GET", SpikeContract.Path.userAgentControl),
             ("GET", SpikeContract.Path.userAgentTransferOwned),
             ("GET", SpikeContract.Path.userAgentTransferDefault):
            return respond(request, sequence: sequence, response: .text(body: userAgentSummary(request)))
        default:
            return nil
        }
    }

    func routeRequestBodies(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome? {
        switch (request.method, request.path) {
        case ("GET", SpikeContract.Path.postForm):
            return respond(
                request,
                sequence: sequence,
                response: .text(body: SpikeFixtureHTML.postForm(), contentType: "text/html; charset=utf-8")
            )
        case ("POST", SpikeContract.Path.postControl), ("POST", SpikeContract.Path.postTransfer):
            return respond(request, sequence: sequence, response: .text(body: postSummary(request)))
        case ("GET", SpikeContract.Path.signedMint):
            return handleSignedMint(request, sequence: sequence)
        case ("GET", SpikeContract.Path.signedPreRequest):
            return handleSignedConsume(request, sequence: sequence, attachment: false)
        case ("GET", SpikeContract.Path.signedResponseTriggered):
            return handleSignedConsume(request, sequence: sequence, attachment: true)
        case ("GET", SpikeContract.Path.blobGuard):
            return respond(
                request,
                sequence: sequence,
                response: .text(body: SpikeFixtureHTML.blobGuard(), contentType: "text/html; charset=utf-8")
            )
        default:
            return nil
        }
    }

    func routeAuthentication(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome? {
        switch (request.method, request.path) {
        case ("GET", SpikeContract.Path.authGuard):
            return respond(request, sequence: sequence, response: guardResponse(
                title: "HTTP authentication fixture",
                controlLabel: SpikeAnchor.authControlLink,
                controlPath: SpikeContract.Path.authControl,
                transferLabel: SpikeAnchor.authTransferLink,
                transferPath: SpikeContract.Path.authTransfer,
                notes: "The asset answers 401 with a Basic challenge until credentials are supplied."
            ))
        case ("GET", SpikeContract.Path.authControl), ("GET", SpikeContract.Path.authTransfer):
            return handleAuthAsset(request, sequence: sequence)
        default:
            return nil
        }
    }

    func routeLifecycle(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome? {
        switch (request.method, request.path) {
        case ("GET", SpikeContract.Path.lifecycleGuard):
            return respond(request, sequence: sequence, response: guardResponse(
                title: "Lifecycle fixture",
                controlLabel: nil,
                controlPath: nil,
                transferLabel: "transfer lifecycle clip",
                transferPath: SpikeContract.Path.lifecycleTransfer,
                notes: "The throttled clip stays in flight long enough to suspend or kill the app."
            ))
        case ("GET", SpikeContract.Path.lifecycleTransfer):
            return respondWithAsset(request, sequence: sequence, asset: .largeClip)
        case ("GET", SpikeContract.Path.failureClose):
            return handleFailureClose(request, sequence: sequence)
        case ("GET", SpikeContract.Path.failureCancel):
            return respondWithAsset(request, sequence: sequence, asset: .largeAttachment)
        default:
            return nil
        }
    }

    // MARK: - Response builders

    func respond(
        _ request: SpikeFixtureRequest,
        sequence: Int,
        response: SpikeFixtureResponse,
        asset: SpikeFixtureAsset? = nil,
        tokenLabel: String? = nil,
        tokenConsumed: Bool? = nil,
        note: String? = nil
    ) -> SpikeFixtureRouteOutcome {
        evidence.record(makeRecord(
            request,
            sequence: sequence,
            response: response,
            asset: asset,
            tokenLabel: tokenLabel,
            tokenConsumed: tokenConsumed,
            note: note
        ))
        return SpikeFixtureRouteOutcome(sequence: sequence, response: response)
    }

    func respondWithAsset(
        _ request: SpikeFixtureRequest,
        sequence: Int,
        asset: SpikeFixtureAsset,
        attachment: Bool = false,
        tokenLabel: String? = nil,
        tokenConsumed: Bool? = nil
    ) -> SpikeFixtureRouteOutcome {
        respond(
            request,
            sequence: sequence,
            response: assetResponse(asset, attachment: attachment),
            asset: asset,
            tokenLabel: tokenLabel,
            tokenConsumed: tokenConsumed
        )
    }

    func assetResponse(_ asset: SpikeFixtureAsset, attachment: Bool) -> SpikeFixtureResponse {
        var headers = [SpikeFixtureHeader(name: "Content-Type", value: asset.contentType)]
        if attachment {
            let disposition = "attachment; filename=\"\(asset.suggestedFilename)\""
            headers.append(SpikeFixtureHeader(name: "Content-Disposition", value: disposition))
        }
        return SpikeFixtureResponse(
            status: 200,
            reason: "OK",
            headers: headers,
            body: asset.payload,
            throttle: asset.throttle,
            declaredByteCount: nil,
            closesAbruptly: false
        )
    }

    func redirect(to location: String) -> SpikeFixtureResponse {
        SpikeFixtureResponse(
            status: 302,
            reason: "Found",
            headers: [SpikeFixtureHeader(name: "Location", value: location)],
            body: Data(),
            throttle: nil,
            declaredByteCount: 0,
            closesAbruptly: false
        )
    }

    func guardResponse(
        title: String,
        controlLabel: String?,
        controlPath: String?,
        transferLabel: String?,
        transferPath: String?,
        notes: String? = nil,
        extra: String = ""
    ) -> SpikeFixtureResponse {
        let html = SpikeFixtureHTML.guardPage(
            title: title,
            controlLabel: controlLabel,
            controlPath: controlPath,
            transferLabel: transferLabel,
            transferPath: transferPath,
            notes: notes
        )
        let withExtra = extra.isEmpty ? html : html.replacingOccurrences(of: "</body>", with: extra + "</body>")
        return .text(body: withExtra, contentType: "text/html; charset=utf-8")
    }

    // MARK: - Flow handlers

    func handleLoginSubmit(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        var response = SpikeFixtureHTML.echoText("signed in")
        response.headers.append(SpikeFixtureHeader(
            name: "Set-Cookie",
            value: "\(SpikeContract.syntheticAuthCookieName)=\(SpikeContract.syntheticAuthCookieValue); Path=/; HttpOnly"
        ))
        response.body = Data(SpikeFixtureHTML.loginResult(authenticated: true).utf8)
        response.headers.append(SpikeFixtureHeader(name: "Content-Type", value: "text/html; charset=utf-8"))
        return respond(request, sequence: sequence, response: response, note: "session-cookie-issued")
    }

    func handleProtectedAsset(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        let authenticated = hasSyntheticAuthCookie(request)
        guard authenticated else {
            return respond(
                request,
                sequence: sequence,
                response: .text(status: 403, reason: "Forbidden", body: "missing session cookie\n"),
                note: "session-cookie-missing"
            )
        }
        return respondWithAsset(request, sequence: sequence, asset: .stillImage)
    }

    func handleScopeSetup(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        var response = SpikeFixtureHTML.echoText("scope markers set")
        response.body = Data(SpikeFixtureHTML.scopeSetup().utf8)
        response.headers.append(SpikeFixtureHeader(name: "Content-Type", value: "text/html; charset=utf-8"))
        let pathMarker = SpikeContract.ScopeMarker.path
        response.headers.append(SpikeFixtureHeader(
            name: "Set-Cookie",
            value: "\(pathMarker.rawValue)=\(pathMarker.value); Path=/scoped"
        ))
        let expiredMarker = SpikeContract.ScopeMarker.expired
        response.headers.append(SpikeFixtureHeader(
            name: "Set-Cookie",
            value: "\(expiredMarker.rawValue)=\(expiredMarker.value); Path=/; Max-Age=0"
        ))
        return respond(request, sequence: sequence, response: response, note: "scope-markers-issued")
    }

    func handleScopeSetupOtherHost(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        var response = SpikeFixtureHTML.echoText("other-host marker set")
        response.body = Data(SpikeFixtureHTML.scopeSetupOtherHost().utf8)
        response.headers.append(SpikeFixtureHeader(name: "Content-Type", value: "text/html; charset=utf-8"))
        let marker = SpikeContract.ScopeMarker.otherHost
        response.headers.append(SpikeFixtureHeader(
            name: "Set-Cookie",
            value: "\(marker.rawValue)=\(marker.value); Path=/"
        ))
        return respond(request, sequence: sequence, response: response, note: "other-host-marker-issued")
    }

    func handleRefererAsset(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        let referer = refererHostPath(request.header("referer"))
        if referer?.hasSuffix(SpikeContract.Path.refererGuard) == true {
            return respondWithAsset(request, sequence: sequence, asset: .stillImage)
        }
        return respond(
            request,
            sequence: sequence,
            response: .text(status: 403, reason: "Forbidden", body: "referer required\n"),
            note: "referer-missing-or-mismatched"
        )
    }

    func handleOriginAsset(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        let expected = SpikeContract.baseURLString(host: SpikeContract.primaryHost)
        if request.header("origin") == expected {
            return respondWithAsset(request, sequence: sequence, asset: .stillImage)
        }
        return respond(
            request,
            sequence: sequence,
            response: .text(status: 403, reason: "Forbidden", body: "origin required\n"),
            note: "origin-missing-or-mismatched"
        )
    }

    func handleSignedMint(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        let preRequest = state.mintToken()
        let responseTriggered = state.mintToken()
        evidence.registerToken(label: preRequest.label)
        evidence.registerToken(label: responseTriggered.label)
        let html = SpikeFixtureHTML.signedMint(
            preRequestToken: preRequest.value,
            responseTriggeredToken: responseTriggered.value
        )
        return respond(
            request,
            sequence: sequence,
            response: .text(body: html, contentType: "text/html; charset=utf-8"),
            note: "tokens-issued:\(preRequest.label),\(responseTriggered.label)"
        )
    }

    func handleSignedConsume(
        _ request: SpikeFixtureRequest,
        sequence: Int,
        attachment: Bool
    ) -> SpikeFixtureRouteOutcome {
        let token = request.queryValue("token") ?? ""
        guard let label = state.label(forToken: token) else {
            return respond(
                request,
                sequence: sequence,
                response: .text(status: 403, reason: "Forbidden", body: "unknown signed token\n"),
                note: "unknown-token"
            )
        }
        guard !evidence.isTokenConsumed(label: label) else {
            return respond(
                request,
                sequence: sequence,
                response: .text(status: 403, reason: "Forbidden", body: "signed token already used\n"),
                tokenLabel: label,
                tokenConsumed: false,
                note: "token-already-consumed"
            )
        }
        evidence.consumeToken(label: label, transport: transport(for: request))
        return respondWithAsset(
            request,
            sequence: sequence,
            asset: .signedResource,
            attachment: attachment,
            tokenLabel: label,
            tokenConsumed: true
        )
    }

    func handleFailureClose(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        let payload = SpikeFixtureAsset.largeClip.payload
        let partial = Data(payload.prefix(4_096))
        let response = SpikeFixtureResponse(
            status: 200,
            reason: "OK",
            headers: [SpikeFixtureHeader(name: "Content-Type", value: "application/octet-stream")],
            body: partial,
            throttle: nil,
            declaredByteCount: payload.count,
            closesAbruptly: true
        )
        return respond(request, sequence: sequence, response: response, note: "truncated-response-fixture")
    }

    func handleAuthAsset(_ request: SpikeFixtureRequest, sequence: Int) -> SpikeFixtureRouteOutcome {
        if authorizationAccepted(request) == true {
            return respondWithAsset(request, sequence: sequence, asset: .stillImage)
        }
        let challenge = SpikeFixtureHeader(name: "WWW-Authenticate", value: "Basic realm=\"Spike\"")
        return respond(
            request,
            sequence: sequence,
            response: .text(
                status: 401,
                reason: "Unauthorized",
                body: "authentication required\n",
                extraHeaders: [challenge]
            ),
            note: "challenge-issued"
        )
    }

    // MARK: - Redaction helpers

    func crossOriginTerminalURL() -> String {
        SpikeContract.baseURLString(host: SpikeContract.secondaryHost) + SpikeContract.Path.credentialTerminal
    }

    func transport(for request: SpikeFixtureRequest) -> String {
        guard let raw = request.header(SpikeContract.transportHeader) else {
            return "webkit"
        }
        return SpikeContract.Transport(rawValue: raw)?.rawValue ?? "unknown"
    }

    func refererHostPath(_ referer: String?) -> String? {
        guard let referer, let url = URL(string: referer) else { return nil }
        return "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
    }

    func authorizationAccepted(_ request: SpikeFixtureRequest) -> Bool? {
        guard let value = request.header("authorization") else { return nil }
        let raw = "\(SpikeContract.syntheticUserName):\(SpikeContract.syntheticPassword)"
        let expected = "Basic " + Data(raw.utf8).base64EncodedString()
        return value == expected
    }

    func hasSyntheticAuthCookie(_ request: SpikeFixtureRequest) -> Bool {
        guard let cookie = request.header("cookie") else { return false }
        return cookie.contains("\(SpikeContract.syntheticAuthCookieName)=")
    }

    func cookieMarkers(in cookieHeader: String?) -> [String] {
        guard let cookieHeader else { return [] }
        return SpikeContract.ScopeMarker.allCases
            .filter { cookieHeader.contains("\($0.rawValue)=\($0.value)") }
            .map(\.rawValue)
            .sorted()
    }

    func credentialSummary(_ request: SpikeFixtureRequest) -> String {
        var lines = ["credential terminal reached"]
        lines.append("host: \(request.header("host") ?? "unknown")")
        lines.append("transport: \(transport(for: request))")
        lines.append("cookie markers: \(cookieMarkers(in: request.header("cookie")).joined(separator: ","))")
        lines.append("synthetic auth cookie present: \(hasSyntheticAuthCookie(request))")
        lines.append("authorization header present: \(request.header("authorization") != nil)")
        lines.append("referer: \(refererHostPath(request.header("referer")) ?? "none")")
        return lines.joined(separator: "\n") + "\n"
    }

    func scopeSummary(_ request: SpikeFixtureRequest) -> String {
        var lines = ["scope probe"]
        lines.append("host: \(request.header("host") ?? "unknown")")
        lines.append("transport: \(transport(for: request))")
        let markers = cookieMarkers(in: request.header("cookie"))
        lines.append("markers present: \(markers.isEmpty ? "none" : markers.joined(separator: ","))")
        lines.append("cookie header present: \(request.header("cookie") != nil)")
        return lines.joined(separator: "\n") + "\n"
    }

    func userAgentSummary(_ request: SpikeFixtureRequest) -> String {
        "user-agent: \(request.header("user-agent") ?? "none")\n"
    }

    func postSummary(_ request: SpikeFixtureRequest) -> String {
        let contentType = request.header("content-type") ?? "none"
        let parameterNames = formParameterNames(request.body)
        var lines = ["post received"]
        lines.append("transport: \(transport(for: request))")
        lines.append("content-type: \(contentType)")
        lines.append("body bytes: \(request.body.count)")
        lines.append("body sha256 prefix: \(request.body.isEmpty ? "none" : SpikeEvidenceHash.prefix(request.body))")
        lines.append("body parameters: \(parameterNames.isEmpty ? "none" : parameterNames.joined(separator: ","))")
        return lines.joined(separator: "\n") + "\n"
    }

    func formParameterNames(_ body: Data) -> [String] {
        guard let text = String(data: body, encoding: .utf8) else { return [] }
        return text
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { pair in String(pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
            .filter { !$0.isEmpty }
            .sorted()
    }

    func makeRecord(
        _ request: SpikeFixtureRequest,
        sequence: Int,
        response: SpikeFixtureResponse,
        asset: SpikeFixtureAsset?,
        tokenLabel: String?,
        tokenConsumed: Bool?,
        note: String?
    ) -> SpikeRecordedRequest {
        let cookieHeader = request.header("cookie")
        let authorization = request.header("authorization")
        let transferCorrelationID = request.header(SpikeContract.transferCorrelationHeader)
            .flatMap { UUID(uuidString: $0)?.uuidString }
        let queryKeys = Array(Set(request.queryItems.map(\.name))).sorted()
        return SpikeRecordedRequest(
            sequence: sequence,
            timestamp: Date().timeIntervalSince1970,
            method: request.method,
            path: request.path,
            transferCorrelationID: transferCorrelationID,
            queryKeys: queryKeys,
            querySHA256: request.rawQuery.isEmpty ? nil : SpikeEvidenceHash.prefix(request.rawQuery),
            host: request.header("host") ?? "unknown",
            transport: transport(for: request),
            headerNames: request.headerNames,
            hasCookieHeader: cookieHeader != nil,
            cookieSHA256: cookieHeader.map { SpikeEvidenceHash.prefix($0) },
            cookieMarkers: cookieMarkers(in: cookieHeader),
            hasSyntheticAuthCookie: hasSyntheticAuthCookie(request),
            hasAuthorizationHeader: authorization != nil,
            authorizationSHA256: authorization.map { SpikeEvidenceHash.prefix($0) },
            authorizationAccepted: authorizationAccepted(request),
            refererHostPath: refererHostPath(request.header("referer")),
            originValue: request.header("origin"),
            userAgentValue: request.header("user-agent"),
            bodyByteCount: request.body.count,
            bodySHA256: request.body.isEmpty ? nil : SpikeEvidenceHash.prefix(request.body),
            assetID: asset?.rawValue,
            responsePayloadSHA256: asset.map { SpikeEvidenceHash.full($0.payload) },
            responseStatusCode: response.status,
            declaredByteCount: response.declaredByteCount ?? response.body.count,
            sentByteCount: 0,
            completed: false,
            responseCompletedAt: nil,
            sendSamples: [],
            clientClosedEarly: false,
            throttleMilliseconds: response.throttle?.chunkDelayMilliseconds,
            tokenLabel: tokenLabel,
            tokenConsumedByThisRequest: tokenConsumed,
            note: note
        )
    }
}
