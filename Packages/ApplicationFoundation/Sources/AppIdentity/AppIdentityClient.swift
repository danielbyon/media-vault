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
      }
    )
  }

  public static var testValue: Self {
    Self(displayName: { "Test Application" })
  }
}

public extension DependencyValues {
  /// The localized runtime identity dependency.
  var appIdentity: AppIdentityClient {
    get { self[AppIdentityClient.self] }
    set { self[AppIdentityClient.self] = newValue }
  }
}
