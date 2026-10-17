//
//  BrowserDownloadSceneRegistryTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import BrowserFeature

@Suite("Download scene authorization")
@MainActor
struct BrowserDownloadSceneRegistryTests {
    @Test("No hosting registrations deny admission even with authentication")
    func emptyRegistryDenies() {
        let registry = BrowserDownloadSceneRegistry(authenticated: { true })
        #expect(!registry.isAuthorized)
    }

    @Test("Every hosting window must remain active and duplicate inactivity is deduplicated")
    func allScenesAndOrdering() {
        let registry = BrowserDownloadSceneRegistry(authenticated: { true })
        let first = UUID()
        let second = UUID()
        registry.register(first, active: true)
        registry.register(second, active: true)
        #expect(registry.isAuthorized)
        let deactivated = registry.setActive(false, for: first)
        #expect(deactivated)
        #expect(!registry.isAuthorized)
        let duplicate = registry.setActive(false, for: first)
        #expect(!duplicate)
        let otherActivation = registry.setActive(true, for: second)
        #expect(!otherActivation)
        #expect(!registry.isAuthorized)
        let reactivated = registry.setActive(true, for: first)
        #expect(reactivated)
        #expect(registry.isAuthorized)
    }

    @Test("Authentication is read live before an observer delivers its invalidation")
    func liveAuthentication() {
        var authenticated = true
        let registry = BrowserDownloadSceneRegistry(authenticated: { authenticated })
        registry.register(UUID(), active: true)
        #expect(registry.isAuthorized)
        authenticated = false
        #expect(!registry.isAuthorized)
    }

    @Test("Disconnect and replacement registration do not impose permanent denial")
    func registrationLifetime() {
        let registry = BrowserDownloadSceneRegistry(authenticated: { true })
        let retired = UUID()
        registry.register(retired, active: false)
        registry.unregister(retired)
        #expect(!registry.isAuthorized)
        registry.register(UUID(), active: true)
        #expect(registry.isAuthorized)
        let staleActivation = registry.setActive(true, for: retired)
        #expect(!staleActivation)
        #expect(registry.isAuthorized)
    }

    @Test("Reactivation cannot release an unresolved revoked native operation")
    func unresolvedRevocationRetainsAdmission() {
        var lifetime = BrowserDownloadPresentationLifetime()
        let admitted = lifetime.begin()
        #expect(admitted)
        lifetime.revoke()
        let prematureAbsence = lifetime.confirmAbsence(isAbsent: true)
        #expect(!prematureAbsence)
        let overlap = lifetime.begin()
        #expect(!overlap)
        lifetime.complete()
        #expect(lifetime.revoked)
        let dismissed = lifetime.requestDismissal(isPresented: true)
        #expect(dismissed)
        let duplicate = lifetime.requestDismissal(isPresented: true)
        #expect(!duplicate)
        let stillPresented = lifetime.confirmAbsence(isAbsent: false)
        #expect(!stillPresented)
        #expect(lifetime.admitted)
        let absent = lifetime.confirmAbsence(isAbsent: true)
        #expect(absent)
        #expect(!lifetime.admitted)
        #expect(!lifetime.revoked)
    }

    @Test("Activity completion pending absence does not suppress inactivity dismissal")
    func completionThenInactivityRequestsDismissal() {
        var lifetime = BrowserDownloadPresentationLifetime()
        _ = lifetime.begin()
        lifetime.complete()
        lifetime.activityEnded()
        #expect(lifetime.dismissalPending)
        #expect(!lifetime.dismissalRequested)
        lifetime.revoke()
        let requested = lifetime.requestDismissal(isPresented: true)
        #expect(requested)
        #expect(lifetime.dismissalRequested)
        #expect(lifetime.revoked)
    }

    @Test("Normal completion requires confirmed absence before a second native admission")
    func completionAndSecondAdmission() {
        var lifetime = BrowserDownloadPresentationLifetime()
        _ = lifetime.begin()
        lifetime.complete()
        lifetime.activityEnded()
        let early = lifetime.begin()
        #expect(!early)
        let uncertain = lifetime.confirmAbsence(isAbsent: false)
        #expect(!uncertain)
        let absent = lifetime.confirmAbsence(isAbsent: true)
        #expect(absent)
        let second = lifetime.begin()
        #expect(second)
        #expect(!lifetime.completed)
        #expect(!lifetime.dismissalRequested)
    }

    @Test("A SwiftUI update or stale layout callback cannot release a root cover")
    func rootLayoutRequiresEvidence() {
        var render = BrowserDownloadRootRenderState()
        render.update(token: testRootRenderToken(true), liveToken: testRootRenderToken(true))
        let previousRevision = render.revision
        #expect(!render.canReleaseCover(sceneActive: true, nativeAdmissionHeld: false))
        render.update(token: testRootRenderToken(false), liveToken: testRootRenderToken(false))
        render.confirm(
            revision: previousRevision,
            token: render.token ?? testRootRenderToken(false),
            liveToken: testRootRenderToken(false),
            rootAttached: true,
            modalsAbsent: true,
            layoutCommitted: true,
        )
        #expect(!render.confirmed)
        render.confirm(
            revision: render.revision,
            token: render.token ?? testRootRenderToken(false),
            liveToken: testRootRenderToken(false),
            rootAttached: true,
            modalsAbsent: true,
            layoutCommitted: false,
        )
        #expect(!render.confirmed)
        render.confirm(
            revision: render.revision,
            token: render.token ?? testRootRenderToken(false),
            liveToken: testRootRenderToken(false),
            rootAttached: true,
            modalsAbsent: false,
            layoutCommitted: true,
        )
        #expect(!render.confirmed)
    }

    @Test("Safe credential rendering releases cover independently of download cleanup recovery")
    func credentialSurfaceCanRecover() {
        var render = BrowserDownloadRootRenderState()
        render.update(token: testRootRenderToken(false), liveToken: testRootRenderToken(false))
        render.confirm(
            revision: render.revision,
            token: render.token ?? testRootRenderToken(false),
            liveToken: testRootRenderToken(true),
            rootAttached: true,
            modalsAbsent: true,
            layoutCommitted: true,
        )
        #expect(!render.confirmed)
        render.confirm(
            revision: render.revision,
            token: render.token ?? testRootRenderToken(false),
            liveToken: testRootRenderToken(false),
            rootAttached: true,
            modalsAbsent: true,
            layoutCommitted: true,
        )
        #expect(render.canReleaseCover(sceneActive: true, nativeAdmissionHeld: false))
        #expect(!render.canReleaseCover(sceneActive: true, nativeAdmissionHeld: true))
        #expect(!render.canReleaseCover(sceneActive: false, nativeAdmissionHeld: false))
    }

    @Test("Unavailable presenters are rejected while unresolved native lifetimes remain barriers")
    func unavailablePresenterDoesNotReplaceUnresolvedController() {
        var lifetime = BrowserDownloadPresentationLifetime()
        #expect(lifetime.admissionDecision(presenterAvailable: false) == .rejectUnavailablePresenter)
        _ = lifetime.begin()
        #expect(lifetime.admissionDecision(presenterAvailable: false) == .waitForAbsence)
        lifetime.revoke()
        lifetime.complete()
        let uncertain = lifetime.confirmAbsence(isAbsent: false)
        #expect(!uncertain)
        #expect(lifetime.admissionDecision(presenterAvailable: true) == .waitForAbsence)
        let absent = lifetime.confirmAbsence(isAbsent: true)
        #expect(absent)
        #expect(lifetime.admissionDecision(presenterAvailable: true) == .present)
    }

    @Test("Authentication change after body evaluation rejects the old surface at reconciliation")
    func staleBodyEvaluationCannotBecomeCurrentSurface() {
        var render = BrowserDownloadRootRenderState()
        let evaluated = testRootRenderToken(true, generation: 5, surface: "authenticated")
        let current = testRootRenderToken(false, generation: 6, surface: "locked")
        let accepted = render.update(token: evaluated, liveToken: current)
        #expect(!accepted)
        render.confirm(
            revision: render.revision,
            token: evaluated,
            liveToken: current,
            rootAttached: true,
            modalsAbsent: true,
            layoutCommitted: true,
        )
        #expect(!render.canReleaseCover(sceneActive: true, nativeAdmissionHeld: false))
        let replacement = render.update(token: current, liveToken: current)
        #expect(replacement)
        render.confirm(
            revision: render.revision,
            token: current,
            liveToken: current,
            rootAttached: true,
            modalsAbsent: true,
            layoutCommitted: true,
        )
        #expect(render.canReleaseCover(sceneActive: true, nativeAdmissionHeld: false))
    }

    @Test("An authentication round trip cannot reuse old body evidence with the same live boolean")
    func privacyGenerationRejectsRoundTrip() {
        var render = BrowserDownloadRootRenderState()
        let evaluated = testRootRenderToken(true, generation: 5)
        let current = testRootRenderToken(true, generation: 6)
        let accepted = render.update(token: evaluated, liveToken: current)
        #expect(!accepted)
        #expect(!render.confirmed)
    }

    @Test("Authentication change between reconciliation and layout completion rejects confirmation")
    func changedAuthenticationRejectsLayoutCompletion() {
        var render = BrowserDownloadRootRenderState()
        let evaluated = testRootRenderToken(true, generation: 5)
        render.update(token: evaluated, liveToken: evaluated)
        let current = testRootRenderToken(false, generation: 6)
        render.confirm(
            revision: render.revision,
            token: evaluated,
            liveToken: current,
            rootAttached: true,
            modalsAbsent: true,
            layoutCommitted: true,
        )
        #expect(!render.confirmed)
    }

    @Test("Same-authentication surface replacement rejects an obsolete root layout completion")
    func surfaceIdentityRejectsOldLayout() {
        var render = BrowserDownloadRootRenderState()
        let setup = testRootRenderToken(false, surface: "setup")
        let authentication = testRootRenderToken(false, surface: "authentication")
        render.update(token: setup, liveToken: setup)
        let previousRevision = render.revision
        render.update(token: authentication, liveToken: authentication)
        render.confirm(
            revision: previousRevision,
            token: setup,
            liveToken: authentication,
            rootAttached: true,
            modalsAbsent: true,
            layoutCommitted: true,
        )
        #expect(!render.confirmed)
    }
}

/// Tokens carry only immutable root-selection evidence; no native or filesystem state enters them.
private func testRootRenderToken(
    _ authenticated: Bool,
    generation: UInt64 = 0,
    surface: String = "root",
) -> BrowserDownloadRootRenderToken {
    .init(surfaceID: surface, authenticated: authenticated, privacyGeneration: generation)
}
