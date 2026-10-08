//
//  AppHostedUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing

/// Shared serialized parent suite for every app-hosted test suite in this target.
///
/// App-hosted tests mount real UIWindow scenes and drive WebKit contexts owned by
/// BrowserWebKitAdapter.shared. Swift Testing executes tests and suites concurrently by
/// default, so two suites that suspend while waiting for display turns or WebKit callbacks
/// can interleave and observe each other's partially torn-down process-level state.
///
/// Nesting every suite that touches the app-hosted environment beneath this parent and
/// marking the parent `.serialized` makes Swift Testing run the entire subtree one test at
/// a time: sibling child suites cannot execute concurrently with one another. The trait is
/// inherited by nested suites, so a child does not need to repeat it.
///
/// Add new app-hosted suites as nested types in an extension of this type rather than as
/// top-level suites, so the serialization boundary keeps covering them.
@Suite("App-hosted UI tests", .serialized)
struct AppHostedUITests {}
