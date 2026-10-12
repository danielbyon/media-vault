---
status: accepted
date: 2026-10-12
---

# Separate browser downloads and Save to Vault, converging at protected receipts

Ordinary WebKit downloads and deliberate Save to Vault are distinct user intents with different transport and lifecycle requirements. They must not be forced through one replay transport or produce a second permanent media store. When a supported media acquisition is explicitly accepted, its app-controlled protected receipt enters the existing single MediaLibrary ingestion journal only after authenticated access; a browser download alone never becomes a canonical asset.

## Selected paths

- **Ordinary download (issue #42):** Use WKDownload and WKDownloadDelegate associated with the originating visible WKWebView. Retain WebKit's own navigation/download semantics, then hand completed files to an operation-owned transient scratch area for appropriate preview/share/discard. Non-media never enters MediaLibrary. Do not create a permanent Downloads library, automatically archive downloads, or claim full authenticated/POST/blob parity before testing the actual origin-webview delegate flow.
- **Explicit Save to Vault (issue #43):** A genuine user action must identify a supported resource first. For the independently demonstrated narrow subset—anonymous, idempotent HTTP(S) GET of an accessible direct resource—an app-owned background URLSession transport may receive bytes. Production HTTPS is the default; HTTP is allowed only to local development fixtures. No manual Cookie/Authorization, POST replay, browser-header reconstruction, response-triggered single-use replay, blob/data URL extraction, DRM bypass, DOM harvesting, or assumed redirect equivalence. Background URLSession's automatic redirects preclude promising per-hop interception; disallow cases requiring such protection, and reject unsafe terminal outcomes. Authentication-dependent or otherwise unsupported saves must fail visibly rather than silently downgrading to an unsafe transport.
- **Protected acquisition receipt (issue #17):** Before reporting receipt acceptance, transfer-complete bytes must be copied from system temporary storage into a separately owned .completeUnlessOpen receipt area using a protection-safe file creation/streaming protocol. Persist only opaque IDs, byte count and digest in recovery metadata; ensure atomic publication and idempotent orphan handling. Do not open the .complete vault SQLite while locked. Actual MediaLibrary reconciliation after authentication must use the existing issue-#13 journal (received through complete), original-byte validation, duplicate/quota/decision policies, .complete canonical resource storage, atomic asset visibility, and durable post-commit receipt cleanup. A test-only @testable journal insert is not an acceptable production interface.

## Intent and profile semantics

A user explicitly saving from Ephemeral browsing intentionally creates a durable acquisition outside ephemeral tab/history/cookie persistence. That receipt must not preserve the browsing profile's cookies, tab URLs, or sensitive metadata in app-owned manifests. System-owned URLSession task state may nevertheless retain the request URL while the explicit operation runs; this must be disclosed and evaluated during privacy review. Switching profiles or locking must not reinterpret a transfer under a new browser store or allow an unauthenticated canonical commit.

UIKit's public WKContextMenuElementInfo.linkURL may support link-specific actions, but it does **not** identify unlinked inline image/video source URLs. The long-press selection requirement in #43 remains gated on a supported, genuine user-selection mechanism and user-visible eligibility. Direct-media-page controls also require iPhone/iPad hit-testing validation. The implementation must not silently narrow or close #43 while those acceptance requirements remain unmet.

## Qualification gates

- **Before completing #42:** Test origin-WKWebView attachment, non-displayable response, page-generated blob, cookie-authenticated download, redirects, destination, cancellation/progress, non-media share/preview, temporary cleanup, and lock behavior. These are not proven by the companion replay spike.
- **Before production #17:** Complete session privacy/lock prerequisite #9; demonstrate a real locked fresh-process receipt and post-unlock journal intake, device canonical .complete protection, background timeout/resume semantics, genuine system relaunch separately from test-harness launch, and idempotent failure/cleanup. A physical iPhone has demonstrated protected receipt creation during a confirmed lock interval, not these remaining scenarios. Treat user force-quit as a distinct platform lifecycle.
- **Before completing #43:** Demonstrate a real user-selection affordance, transport eligibility/failure UI, receipt-to-single-journal intake, media validation/quota/duplicate behavior, and device lifecycle; align issue #43 dependencies with #17 and #42. Do not claim video canonical import from a receipt-only MP4 result.
- **Before shipping:** Verify backup-exclusion requests, metadata and diagnostics redaction, Persistent-Private/Ephemeral privacy, and no accepted-media loss or partially visible asset after interruption.

**Decision status:** Accepted interface and ownership design, with these explicitly blocking production gates. See docs/research/browser-architecture-evidence-and-decision.md and docs/adr/0001-retain-wkwebview-visible-browser.md.
