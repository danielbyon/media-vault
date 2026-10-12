//
//  BridgeMessageDecoder.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Identifies the public content world that delivered a WebKit script message.
public enum MessageContentWorld: Equatable, Sendable {
    /// Isolated world reserved for the app-installed gesture listener.
    case defaultClient
    /// World shared with the website's own scripts.
    case page
    /// Any other content world that the experiment does not recognize.
    case other
}

/// Metadata supplied by WebKit outside the page-controlled message body.
public struct NativeMessageMetadata: Equatable, Sendable {
    /// Content world reported by WebKit, outside the message body.
    public let contentWorld: MessageContentWorld
    /// Whether WebKit identifies the sender as the top frame.
    public let isMainFrame: Bool
    /// Scheme, host, and port from WebKit's security origin.
    public let securityOrigin: String
    /// WebKit's request URL for the sending frame, when available.
    public let requestURL: URL?

    /// Constructs a record from WebKit-owned message metadata.
    public init(contentWorld: MessageContentWorld, isMainFrame: Bool, securityOrigin: String, requestURL: URL?) {
        self.contentWorld = contentWorld
        self.isMainFrame = isMainFrame
        self.securityOrigin = securityOrigin
        self.requestURL = requestURL
    }
}

/// Event kinds observed by the disposable bridge.
public enum GestureEventType: String, Equatable, Sendable {
    /// Context-menu activation, the only event allowed to carry a source.
    case contextmenu
    /// Pointer delivery diagnostic, without resource data.
    case pointerdown
    /// Touch delivery diagnostic, without resource data.
    case touchstart
}

/// One accepted gesture observation; URL fields are page-controlled candidates.
public struct GestureObservation: Equatable, Sendable {
    /// Type of browser event that produced this observation.
    public let eventType: GestureEventType
    /// Activated element's HTML tag name.
    public let tagName: String
    /// Resolved `currentSrc` from the activated media element.
    public let currentSourceURL: URL?
    /// Resolved `src` attribute from the activated media element.
    public let sourceAttributeURL: URL?
    /// Preferred selected resource candidate, using `currentSrc` first.
    public let mediaURL: URL?
    /// Scheme marker for a redacted `blob:` or `data:` resource.
    public let mediaScheme: String?
    /// Enclosing link destination, separate from the selected media.
    public let linkURL: URL?
    /// Frame URL reported by page script; never used as a trusted URL base.
    public let pageFrameURL: String
    /// Frame origin reported by page script; never used for authorization.
    public let pageFrameOrigin: String
    /// Frame metadata provided by WebKit rather than by page script.
    public let native: NativeMessageMetadata
}

/// Reasons that a script message did not become an experiment observation.
public enum BridgeDecodeResult: Equatable, Sendable {
    /// A bounded observation with untrusted URL candidates.
    case accepted(GestureObservation)
    /// A reason why the message could not be used as an observation.
    case rejected(String)
}

/// Validates a single page message without turning it into transfer authority.
public enum BridgeMessageDecoder {
    /// Decode one message against the active fixture and WebKit frame metadata.
    ///
    /// The result is research evidence, not permission to fetch or save bytes.
    public static func decode(
        _ body: Any,
        native: NativeMessageMetadata,
        activeCaseID: String?,
    ) -> BridgeDecodeResult {
        guard native.contentWorld == .defaultClient else {
            return .rejected("wrong-content-world")
        }
        guard let activeCaseID else {
            return .rejected("stale-navigation")
        }
        guard let values = body as? [String: Any],
              Set(values.keys).isSubset(of: allowedKeys),
              let eventName = values["eventType"] as? String,
              let eventType = GestureEventType(rawValue: eventName),
              let isTrusted = values["isTrusted"] as? Bool,
              let caseID = boundedString(values["caseID"], maximum: 80),
              let tagName = boundedString(values["tagName"], maximum: 32),
              let pageFrameURL = boundedString(values["frameURL"], maximum: 4_096),
              let pageFrameOrigin = boundedString(values["frameOrigin"], maximum: 2_048),
              let currentSrc = optionalString(values["currentSrc"], maximum: 4_096),
              let src = optionalString(values["src"], maximum: 4_096),
              let linkHref = optionalString(values["linkHref"], maximum: 4_096)
        else {
            return .rejected("malformed-message")
        }
        guard let requestURL = native.requestURL else {
            return .rejected("native-frame-request-unavailable")
        }
        guard caseID == activeCaseID,
              requestMatchesCase(requestURL, securityOrigin: native.securityOrigin, caseID: activeCaseID)
        else {
            return .rejected("stale-navigation")
        }
        guard isTrusted else {
            return .rejected("synthetic-event")
        }

        if eventType != .contextmenu, currentSrc != nil || src != nil || linkHref != nil {
            return .rejected("malformed-message")
        }
        let normalizedTag = tagName.uppercased()
        if currentSrc != nil || src != nil,
           !["IMG", "VIDEO", "AUDIO", "SOURCE"].contains(normalizedTag) {
            return .rejected("malformed-message")
        }

        let current = resolvedSource(currentSrc, frameURL: requestURL)
        let attribute = resolvedSource(src, frameURL: requestURL)
        let link = resolvedSource(linkHref, frameURL: requestURL)
        let selected = current ?? attribute
        let observation = GestureObservation(
            eventType: eventType,
            tagName: normalizedTag,
            currentSourceURL: current?.url,
            sourceAttributeURL: attribute?.url,
            mediaURL: selected?.url,
            mediaScheme: selected?.scheme,
            linkURL: link?.url,
            pageFrameURL: pageFrameURL,
            pageFrameOrigin: pageFrameOrigin,
            native: native,
        )
        return .accepted(observation)
    }

    private static let allowedKeys: Set = [
        "eventType",
        "isTrusted",
        "caseID",
        "tagName",
        "currentSrc",
        "src",
        "linkHref",
        "frameURL",
        "frameOrigin",
    ]

    private static func boundedString(_ value: Any?, maximum: Int) -> String? {
        guard let stringValue = value as? String,
              !stringValue.isEmpty,
              stringValue.utf8.count <= maximum
        else {
            return nil
        }

        return stringValue
    }

    /// A double optional distinguishes an absent field from a malformed value.
    private static func optionalString(_ value: Any?, maximum: Int) -> String?? {
        if value == nil || value is NSNull {
            return .some(nil)
        }
        guard let stringValue = value as? String, stringValue.utf8.count <= maximum else {
            return nil
        }

        return .some(stringValue.isEmpty ? nil : stringValue)
    }

    /// Accept only case frames whose URL and native origin both belong to the local fixture server.
    private static func requestMatchesCase(_ requestURL: URL, securityOrigin: String, caseID: String) -> Bool {
        guard let scheme = requestURL.scheme?.lowercased(),
              scheme == "http",
              let host = requestURL.host?.lowercased(),
              ["127.0.0.1", "localhost"].contains(host),
              requestURL.port == 18_755,
              let senderOrigin = URLComponents(string: securityOrigin),
              senderOrigin.scheme?.lowercased() == scheme,
              senderOrigin.host?.lowercased() == host,
              senderOrigin.port == requestURL.port,
              senderOrigin.user == nil,
              senderOrigin.password == nil,
              senderOrigin.path.isEmpty || senderOrigin.path == "/",
              senderOrigin.query == nil,
              senderOrigin.fragment == nil
        else {
            return false
        }

        return requestURL.path == "/case/\(caseID)" || requestURL.path == "/frame/\(caseID)"
    }

    private static func resolvedSource(_ raw: String?, frameURL: URL?) -> (url: URL?, scheme: String)? {
        guard let raw else {
            return nil
        }

        if raw == "data:" || raw == "blob:" {
            return (nil, String(raw.dropLast()))
        }
        guard let url = URL(string: raw, relativeTo: frameURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil
        else {
            return nil
        }

        return (url, scheme)
    }
}
