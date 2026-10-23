# Icon family implementation plan

Status: **Design decisions agreed (Q1–Q12). Awaiting final owner confirmation before implementation.**

Source decisions: [ADR-0001](../../adr/0001-preserve-icon-family-design.md). Terminology: [CONTEXT.md](../../../CONTEXT.md). Primary external product work item: [GitHub issue #54](https://github.com/danielbyon/media-vault/issues/54), reserved for runtime icon selection.

## Goal and constraints

Implement nine faithful editable icon identities (Primary, Development, Mineral, Indigo, Instrument, Grid, Compass, Calculator, Calculator Glass) and three explicitly authored system appearances (Default, Dark, Tinted) for each. The unaltered supplied 1536×1024 RGBA PNG is the reference authority; preserve its SHA-256 **92dc5f23741c424d5eceb3c308a041b73ad17a2140fc7b3631cd93f866073975** in the repository alongside it. The source image must be copied from the user's uploaded file—not substituted with previously reconstructed or newly generated imagery.

Reconstruct at production fidelity from hybrid layered masters (vector geometry, controlled lighting/raster effects). Store editable masters, deterministic exporters and output asset catalogs in version control. No authoring dependency may run during ordinary Xcode builds or CI. Preserve original silhouettes, aperture, interweaving, highlights, palette, and distinctive differences between the seven Pro alternatives. Tinted artwork is grayscale; user tint and Clear presentation are system-owned. Review actual installed rendering on device.

Pro icon files may be bundled and registered but **must not become selectable** in this task: no icon picker, entitlement policy, icon-setting API invocation, persistence, backup changes, or decoy behavior changes. Keep all runtime/source symbols brand-neutral.

## Implementation delivery model

Create a **new isolated worktree and a single feature branch** from verified current origin/main; preserve any existing dirty primary checkout. Open **one draft PR** for the feature, using commits/evidence for the stages below. The existing design-documentation branch does not constitute a separate implementation PR. Carry approved decisions and files forward without overwriting newer main changes.

Each stage records exact input/output hashes, reproducibility instructions, and review evidence. Owner approval is explicit at Stage 1 and Stage 2; absence of an answer means STOP. After technical verification, request acceptance before merge. No autonomous background work and no automatic merge.

### Stage 1 — Primary icon artwork (Owner visual approval gate 1)

1. Add unmodified canonical showcase to `docs/design/icon-family/approved-showcase.png` with verified hash and provenance.
2. Choose a hybrid editable master format and deterministic export method by evaluating a faithful primary icon prototype. Document toolchain/version, master layers, regeneration commands, output hashes, and exclusions from Xcode's normal build.
3. Reconstruct the Core Tight—Circle primary, with four interwoven optical-glass segments and its central circular aperture. Preserve refraction and geometry without superficial reinterpretation.
4. Author Default, Dark, and luminance-focused grayscale Tinted treatment. Produce labeled side-by-side comparisons to the original board, 1024px previews, and device-scale small-icon sheets, including high-contrast backgrounds.
5. Submit primary artwork and evidence for user review. **Stop until explicitly approved.** Feedback prompts correction/re-review instead of proceeding.

### Stage 2 — Family artwork (Owner visual approval gate 2)

1. With the approved primary geometry as baseline, construct Mineral, Indigo, Instrument, Grid, Compass, Calculator, Calculator Glass, and the distinct Development design (DEV badge). Retain reference-specific visual geometry; share master components where useful but do not force unrelated utility/calculator icons to use the primary ring.
2. Author each identity's Default, Dark and grayscale Tinted appearances: nine identities × three assets = **27 authored appearances**.
3. Generate a family contact sheet and each appearance at 1024px and representative small launch-icon sizes. Check transparent/opaque composition, edge safety, label legibility, grayscale contrast, and expected tint behavior without hard-coded user color.
4. Record deterministic build/export verification and hashes; user reviews every icon/appearance, not just the primary. **Stop until explicitly approved.**

### Stage 3 — Xcode integration

1. Check compatibility with the installed Xcode 27 environment; evaluate `.appiconset` versus layered `.icon`/Icon Composer where applicable. Use deterministic checked-in exports and a platform-supported asset catalog; don't assume one packaging form without a test build.
2. Configure release Primary icon versus Debug Development icon through xcconfigs/build settings and/or project target settings. Release includes exactly seven Pro alternate identities and not the Development asset; Debug uses Development as primary and includes exactly the same seven alternates, not an additional selectable release Default.
3. Register alternate icon names at build time; let Xcode synthesize Info.plist icon metadata. Avoid hand-authoring generated `CFBundleIcons` or broad include-all-app-icons flags that could leak the Debug icon into Release.
4. Check generated products for primary and alternate mappings, unexpected icon names, Dev leakage, bundle size, and appropriate asset compilation for iOS and iPadOS. The configuration must not trigger any runtime selection by itself.
5. Preserve calculator decoy unbranded, all existing vault authentication/lock flows, and privacy/entitlement boundaries. No new app UI in this stage.

### Stage 4 — Qualification and completion

1. Verify each asset exactly matches its master exporter outputs; rerun exporter and compare deterministic hashes; check pixel dimensions, colorspace/alpha, file completeness, and all 27 appearance mappings.
2. Run clean Debug and Release builds, relevant test/lint gates and regression checks; inspect compiled `Info.plist` and archive/resource manifests for correct primary/alternate icon registration. Avoid changes to unrelated test hosts.
3. Inspect actual iPhone and iPad Home Screen presentations: light, dark, tinted, and clear system modes (the last two with multiple background/tint combinations). Test the Default and Dev icons at small sizes and badge legibility. If alternate icons aren't user-selectable, use a bounded test-only preview/inspection mechanism that cannot ship in Release; do not implement production icon-selection UI or bypass Pro gating.
4. Review screenshot evidence against original board and both visual approvals; confirm no material geometry/refraction drift. Perform independent standards/spec review and resolve in-scope issues.
5. Report commit SHAs, reproducible commands, artifact hashes, tests, device/OS details, and any qualification that remains unverified. The PR stays **draft/unmerged** until accepted; never equate preview verification with physical installation.

## Acceptance invariants

- Release primary = Core Tight—Circle; Debug primary = recognizable ring plus distinct DEV treatment. No Dev icon in Release.
- Exactly seven prepackaged Pro alternates in both builds; no picker, new entitlement policy, API to switch icons, or backup/persistence modification.
- 27 intentional authored appearances, with grayscale tinted variants and system-controlled tinting/clear behavior.
- All nine icon identities preserve their approved original board character; no blurry upscale offered as an editable source reconstruction.
- Source, masters, script, generated assets, and evidence are durable; ordinary app build has no additional graphics-tool dependency.
- Owner approval gate 1 precedes family finalization; approval gate 2 precedes production integration; completed physical QA and final review precede merge.
- One draft PR, one implementation worktree branch, zero changes to any dirty primary checkout.

## Out of scope

Issue #54 picker, entitlement gating/revocation, device-local selection persistence, backup behavior for icon preference, and alternate-icon UX snapshots; cosmetic changes to app interior; branding the decoy; unrelated project/CI refactoring; unauthorized modifications to other Xcode targets.

## Implementation-specific questions for the agent, not new product decisions

Resolve the exact hybrid source file format/tooling only after demonstrating export parity of the prototype. Verify the current Apple toolchain's correct icon-asset packaging, alternate-name generation and test strategy rather than assuming APIs from older versions. Surface true contradictions with evidence instead of silently extending scope.
