import Dependencies
import Testing

@testable import AppIdentity

@Suite("Application identity")
struct AppIdentityClientTests {
  @Dependency(\.appIdentity.displayName) var displayName

  @Test("The default test adapter is deterministic")
  func testValueIsDeterministic() {
    #expect(AppIdentityClient.testValue.displayName() == "Test Application")
  }

  @Test("The display name is supplied by the injected identity dependency")
  func displayNameUsesInjectedValue() {
    withDependencies {
      $0.appIdentity.displayName = { "Injected Application" }
    } operation: {
      #expect(displayName() == "Injected Application")
    }
  }
}
