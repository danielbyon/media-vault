//
//  BrowserInlineMediaSpikeApp.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import SwiftUI
import WebKit

@main
@MainActor
struct BrowserInlineMediaSpikeApp: App {
    @State
    private var harness = InlineMediaHarness()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 4) {
                Text("Inline media selection spike")
                    .font(.caption)
                    .accessibilityIdentifier("spike-title")
                Text(harness.status)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("spike-status")
                Button("Flush recorder") {
                    Task { await harness.flushRecorder() }
                }
                .accessibilityIdentifier("flush-recorder")
                WebView(harness.page)
                    .accessibilityIdentifier("spike-web-view")
            }
            .task { harness.startIfNeeded() }
            .onChange(of: harness.page.url) { _, url in
                harness.notePageURL(url)
            }
        }
    }
}

/// Owns one disposable SwiftUI WebView and records only the current gesture.
@MainActor
@Observable
final class InlineMediaHarness: NSObject, WKScriptMessageHandler {
    private let baseURL: URL
    private let reporter: InlineMediaReporter
    private let mode: String
    private let caseID: String
    private let pressID: String?
    private var started = false
    private var activeCaseID: String?
    private var fixtureSeen = false
    private(set) var page: WebPage
    private(set) var status = "starting"

    override init() {
        let environment = ProcessInfo.processInfo.environment
        guard let fallback = URL(string: "http://127.0.0.1:18755") else {
            preconditionFailure("The fixed loopback fixture URL must parse")
        }

        baseURL = environment["SPIKE_BASE_URL"].flatMap(URL.init(string:)) ?? fallback
        mode = environment["SPIKE_MODE"] ?? "native"
        caseID = environment["SPIKE_CASE"] ?? "unlinked-image"
        pressID = environment["SPIKE_PRESS_ID"]
        reporter = InlineMediaReporter(baseURL: baseURL, pressID: pressID)
        page = WebPage()
        super.init()

        var configuration = WebPage.Configuration()
        if mode == "bridge" || mode == "diagnostic" {
            let contentController = WKUserContentController()
            let script = WKUserScript(
                source: Self.gestureScript(diagnostic: mode == "diagnostic"),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient,
            )
            contentController.addUserScript(script)
            contentController.add(self, contentWorld: .defaultClient, name: "spikeGesture")
            configuration.userContentController = contentController
        }
        page = WebPage(configuration: configuration)
    }

    func startIfNeeded() {
        guard !started else {
            return
        }

        started = true
        activeCaseID = caseID
        status = "\(mode): \(caseID)"
        reporter.record(kind: "host-started", fields: ["mode": mode, "case": caseID])
        guard let url = URL(string: "/case/\(caseID)", relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            status = "invalid fixture URL"
            return
        }

        if let pressID {
            components.queryItems = [URLQueryItem(name: "pressID", value: pressID)]
        }
        guard let fixtureURL = components.url else {
            status = "invalid fixture URL"
            return
        }

        _ = page.load(URLRequest(url: fixtureURL))
    }

    func flushRecorder() async {
        let delivered = await reporter.flush()
        status = delivered ? "evidence flushed" : "evidence flush failed"
    }

    /// Retire the case once the visible browser leaves its fixture document.
    func notePageURL(_ url: URL?) {
        guard let url, let activeCaseID else {
            return
        }

        if url.path == "/case/\(activeCaseID)", url.host == baseURL.host {
            fixtureSeen = true
            return
        }
        guard fixtureSeen else {
            return
        }

        self.activeCaseID = nil
        status = "retired after navigation"
        reporter.record(kind: "navigation-retired", fields: [
            "case": activeCaseID,
            "to": Self.safeURL(url),
        ])
    }

    /// The message body is page-influenced; WebKit's frame metadata is separate.
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        let port = origin.port == 0 ? "" : ":\(origin.port)"
        let world: MessageContentWorld =
            if message.world == WKContentWorld.defaultClient {
                .defaultClient
            } else if message.world == WKContentWorld.page {
                .page
            } else {
                .other
            }
        let native = NativeMessageMetadata(
            contentWorld: world,
            isMainFrame: message.frameInfo.isMainFrame,
            securityOrigin: "\(origin.protocol)://\(origin.host)\(port)",
            requestURL: message.frameInfo.request.url,
        )
        let result = BridgeMessageDecoder.decode(message.body, native: native, activeCaseID: activeCaseID)
        switch result {
        case let .rejected(reason):
            let body = message.body as? [String: Any]
            let shape = body.map { values in
                values.keys
                    .sorted()
                    .map { key in
                        "\(key):\(type(of: values[key] ?? NSNull()))"
                    }
                    .joined(separator: ",")
            } ?? "non-dictionary"
            reporter.record(kind: "bridge-rejected", fields: [
                "case": caseID,
                "mode": mode,
                "reason": reason,
                "nativeWorld": String(describing: native.contentWorld),
                "nativeMainFrame": String(native.isMainFrame),
                "nativeOrigin": native.securityOrigin,
                "nativeRequest": Self.safeURL(native.requestURL),
                "bodyShape": String(shape.prefix(400)),
                "bodyTrusted": String(body?["isTrusted"] as? Bool ?? false),
            ])
        case let .accepted(observation):
            status = "\(observation.eventType.rawValue): \(observation.tagName)"
            reporter.record(kind: "bridge-observation", fields: [
                "case": caseID,
                "mode": mode,
                "event": observation.eventType.rawValue,
                "tag": observation.tagName,
                "currentSrc": Self.safeURL(observation.currentSourceURL),
                "src": Self.safeURL(observation.sourceAttributeURL),
                "selectedMedia": Self.safeURL(observation.mediaURL),
                "mediaScheme": observation.mediaScheme ?? "absent",
                "linkDestination": Self.safeURL(observation.linkURL),
                "pageFrameURL": Self.safePageURL(observation.pageFrameURL),
                "pageFrameOrigin": Self.safePageURL(observation.pageFrameOrigin),
                "nativeWorld": String(describing: observation.native.contentWorld),
                "nativeMainFrame": String(observation.native.isMainFrame),
                "nativeOrigin": observation.native.securityOrigin,
                "nativeRequest": Self.safeURL(observation.native.requestURL),
            ])
        }
    }

    private static func safeURL(_ url: URL?) -> String {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "absent"
        }

        return "\(url.scheme ?? "http")://\(url.host ?? "unknown")\(url.port.map { ":\($0)" } ?? "")\(url.path)"
    }

    private static func safePageURL(_ raw: String) -> String {
        safeURL(URL(string: raw))
    }

    /// Capture the activated event path only; diagnostic mode reports no source.
    private static func gestureScript(diagnostic: Bool) -> String {
        let diagnosticListeners = diagnostic
            ? """
              ['pointerdown','touchstart'].forEach(name=>addEventListener(name,event=>{
                const t=event.target;
                send({eventType:name,isTrusted:event.isTrusted,caseID:caseID(),tagName:t&&t.tagName||'UNKNOWN',currentSrc:null,src:null,linkHref:null,frameURL:location.href,frameOrigin:location.origin});
              },true));
            """
            : ""
        return """
        (()=>{
          const send=value=>window.webkit.messageHandlers.spikeGesture.postMessage(value);
          const caseID=()=>location.pathname.split('/').pop()||'';
          const opaque=value=>typeof value==='string'?(value.startsWith('data:')?'data:':value.startsWith('blob:')?'blob:':value):null;
          addEventListener('contextmenu',event=>{
            const path=event.composedPath().slice(0,8);
            let media=null,link=null;
            for(const node of path){
              if(!node||!node.tagName)continue;
              const tag=node.tagName.toUpperCase();
              if(!media&&['IMG','VIDEO','AUDIO','SOURCE'].includes(tag))media=node;
              if(!link&&tag==='A')link=node;
            }
            const target=media||event.target;
            send({eventType:'contextmenu',isTrusted:event.isTrusted,caseID:caseID(),tagName:target&&target.tagName||'UNKNOWN',
              currentSrc:opaque(media&&media.currentSrc||null),src:opaque(media&&media.getAttribute('src')||null),
              linkHref:opaque(link&&link.href||null),frameURL:location.href,frameOrigin:location.origin});
          },true);
          \(diagnosticListeners)
        })();
        """
    }
}

/// Sends bounded fixture observations without cookies or response bodies.
@MainActor
private final class InlineMediaReporter {
    private let endpoint: URL
    private let session: URLSession
    private let recorderToken: String?
    private let pressID: String?
    private var pendingRequests: [Task<Bool, Never>] = []

    init(baseURL: URL, pressID: String?) {
        endpoint = baseURL.appending(path: "/__spike/event")
        recorderToken = ProcessInfo.processInfo.environment["SPIKE_RECORDER_TOKEN"]
        self.pressID = pressID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func record(kind: String, fields: [String: String]) {
        var eventFields = fields
        if let pressID {
            eventFields["pressID"] = pressID
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["kind": kind, "fields": eventFields]) else {
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let recorderToken {
            request.setValue(recorderToken, forHTTPHeaderField: "X-Spike-Recorder-Token")
        }
        pendingRequests.append(Task { [session] in
            guard let (_, response) = try? await session.data(for: request) else {
                return false
            }

            return (response as? HTTPURLResponse)?.statusCode == 200
        })
    }

    func flush() async -> Bool {
        var delivered = true
        while !pendingRequests.isEmpty {
            let requests = pendingRequests
            pendingRequests.removeAll()
            for request in requests {
                delivered = await request.value && delivered
            }
        }
        return delivered
    }
}
