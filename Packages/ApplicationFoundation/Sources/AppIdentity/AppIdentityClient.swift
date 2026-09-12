//
//  AppIdentityClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import DependenciesMacros
import Foundation

/// Provides the localized display name configured for the running application.
///
/// The interface deliberately exposes only the value currently needed by application code. Bundle
/// identifiers and release branding remain configuration concerns rather than runtime domain data.
@DependencyClient
public struct AppIdentityClient: Sendable {
    /// Returns the localized display name supplied by the current runtime adapter.
    public var displayName: @Sendable () -> String = { "Application" }
}

extension AppIdentityClient: DependencyKey {
    /// The live identity implementation backed by the application bundle.
    public static var liveValue: Self {
        Self(
            displayName: {
                let bundle = Bundle.main
                let localizedInfo = bundle.localizedInfoDictionary
                let info = bundle.infoDictionary

                return (localizedInfo?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleDisplayName"] as? String)
                    ?? (localizedInfo?["CFBundleName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? "Application"
            },
        )
    }

    /// The deterministic identity implementation used by tests unless overridden.
    public static var testValue: Self {
        Self(displayName: { "Test Application" })
    }
}

extension DependencyValues {
    /// The localized runtime identity dependency.
    public var appIdentity: AppIdentityClient {
        get { self[AppIdentityClient.self] }
        set { self[AppIdentityClient.self] = newValue }
    }
}
