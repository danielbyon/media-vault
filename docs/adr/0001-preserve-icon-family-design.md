# Preserve the approved icon family through faithful, editable artwork

Status: Q1–Q12 product decisions accepted; amended execution plan awaits final owner review, with both owner visual gates mandatory.

## Context

The approved concept showcase is a small raster design reference rather than a production-resolution source asset. The product needs a recognizably faithful primary icon, seven premium alternatives, and a distinctly marked development icon. Its consumer-facing visual identity belongs at the release/configuration boundary rather than in the private-media domain.

## Settled decisions (October 22, 2026)

1. **Reconstruct, do not upscale (Q1=A).** Rebuild the approved designs faithfully from editable, production-resolution masters using the original submitted showcase as the visual authority. The showcase is not a production render, and reconstruction must not be represented as recovery of the original full-resolution source. Reject generated inventions that materially change composition, overlapping segments, material highlights, or palette. Primary geometry: four interwoven optical-glass segments, small circular aperture, controlled rotational asymmetry.
2. **Full icon family (Q2=B).** Prepare all nine identities: Primary (Default/Core Tight — Circle), Mineral, Indigo, Instrument, Grid, Compass, Calculator, Calculator Glass, and Development. Internal asset/runtime identifiers stay role-based; these concept names describe visual approval references, not domain-facing source terminology.
3. **Artwork fidelity over extra effects (Q3=A).** Preserve the approved glass, refraction, highlights, and proportions. Use platform-provided appearance handling only where it does not materially reinterpret the visual design.
4. **Register, but do not expose Pro selection (Q4=A).** Include/register the seven premium alternates as built app icon resources. Do **not** add a selection UI, call runtime icon-selection APIs, build entitlement/persistence rules, or change the active icon in this slice. Issue #54 owns the user-facing selection and entitlement behavior. Bundling an asset is not the same as making it selectable.
5. **Version-controlled, reproducible artwork (Q5=A).** Check in editable master files, deterministic export tooling, and production-ready exports. The ordinary app build consumes checked-in exports; graphics authoring tools must not become an Xcode build or CI prerequisite. Retain design-reference provenance and enough instructions to regenerate exports.
6. **System-native appearances (Q6=A).** Author intentional Default, Dark, and grayscale Tinted appearances for every identity (nine identities × three authored appearances = 27 assets). The operating system may generate Clear presentations; no assumption that authored color survives system tinting. Shape and aperture remain recognizable through all appearances.
7. **Two design approval gates (Q7=A).** Review and approve the reconstructed Primary Icon (all appearances, multiple icon sizes, original-board comparison) **before** propagating its geometry to the family. Then review and approve all nine identities/appearances as a family before calling app integration visually complete. No arbitrary visual reinterpretations are pre-approved by these decisions.

## Supporting platform facts and engineering implications

- Xcode's asset-catalog build settings can register the primary icon and a selected list of alternate icon sets (`ASSETCATALOG_COMPILER_APPICON_NAME`, `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`). Xcode generates the corresponding `CFBundleIcons` keys; implementation should not hand-edit those keys in Info.plist. Source: Apple, "Configuring your app to use alternate app icons" and "Build settings reference".
- Explicit asset-catalog appearance slots accept Default/Any, Dark, and Tinted images, with Tinted authored in grayscale. Source: Apple, "Configuring your app icon using an asset catalog".
- The project already has separate release and development application identities configured via xcconfigs; keep the recognizable Primary design for the Release app and a distinguishable Development Icon for the Debug app. Debug build badge is part of icon imagery; preserve legibility at small sizes.
- Apple can generate Clear appearances automatically. This decision does not promise custom-authored Clear files and does not exempt any appearance from visual QA. Source: Apple Human Interface Guidelines, "App icons", June 2026 revision.

## Rejected alternatives, their failure modes, and invariants

- **Enlarging crops of the showcase:** insufficient source pixels lead to blurry material seams, invented details, and inconsistent exports.
- **Letting native glass effects redesign the artwork:** changes the optical highlight/refraction language that made the original design recognizable.
- **Primary-and-Development only:** leaves approved alternates unprepared and causes design drift when issue #54 is implemented.
- **Implementing the icon picker immediately:** broadens a bounded graphics/integration effort into entitlement, revocation, backup exclusion, and preference persistence work prematurely.
- **External-only editable masters:** breaks reproducibility when files or applications are unavailable to future maintainers.
- **Hard-coding showcase's blue/silver appearance in system Tinted:** conflicts with user-selected tinting and produces unpredictable contrast.
- **One unreviewed nine-icon generation pass:** propagates a Primary geometry mistake to every dependent variant.

Invariants: no changes to calculator decoy branding or behavior; icon selection independent of decoy; no Pro selection bypass; no consumer marketing name in internal module/type/domain identifiers; original reference board remains the design authority.

## Additional decisions settled October 22, 2026 (Q8–Q11)

8. **Hybrid layered masters (Q8=A).** Use editable vector geometry for the icon forms plus controlled gradient, lighting, and raster material passes where useful. Keep the assets and deterministic export tooling in source control; compare their rendered appearance against the original board. Choose the particular authoring tool based on a successful Primary Icon prototype, not convenience alone. Builds must consume pre-exported artifacts without requiring that tool in CI.
9. **Configuration-specific icon inclusion (Q9=A).** Release primary = the approved Primary Icon; Debug primary = the Development Icon. Both include the same seven premium Alternate Icons. Never place the Development Icon in the release product, and do not expose the release primary as an additional Debug alternate. Other target bundles are not part of this icon task.
10. **Canonical reference board in repository (Q10=A).** Check in the *unaltered* uploaded showcase under an icon-design reference directory, not merely a crop, regenerated visual approximation, or transient conversation link. Preserve its provenance and byte identity:
    - Original image title is visible in the reference artwork. Use the neutral repository path below; do not propagate the consumer brand into domain documentation or source identifiers.
    - Image dimensions: 1536 × 1024; PNG RGBA.
    - Verified SHA-256: `92dc5f23741c424d5eceb3c308a041b73ad17a2140fc7b3631cd93f866073975`.
    - Suggested check-in path: `docs/design/icon-family/approved-showcase.png`, separate from domain-spec terminology. Verify byte-for-byte hash after copying; do not substitute prior reconstructed assets.
11. **Full visual qualification (Q11=A).** Check all authored identity×appearance combinations at 1024px and representative actual Home Screen sizes, with light/dark/tinted/clear modes and contrasting backgrounds. Require real-device evidence on iPhone and iPad before final acceptance. Run deterministic size/format/assets/build checks as technical acceptance, but do not confuse those with human approval of visual fidelity. The DEV badge must remain identifiable at small sizes without changing the approved primary geometry.

## Implementation boundaries established by Apple documentation

- Xcode builds the primary icon from `ASSETCATALOG_COMPILER_APPICON_NAME` and includes declared alternates from `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`. It writes `CFBundleIcons`/alternate entries; do not edit those keys manually. https://developer.apple.com/documentation/xcode/configuring-your-app-to-use-alternate-app-icons
- Asset catalogs support iOS/iPadOS Any/Default, Dark and grayscale Tinted artwork; clear/tinted final presentation requires on-device review. https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- Icon Composer can preview default/dark/mono appearances and native effects, but it is an authoring choice, not an excuse to alter the approved design. https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer

12. **Single implementation branch and draft PR with mandatory stops (Q12=A).** Create one isolated implementation branch and one draft PR, using the latest verified `origin/main` while preserving the primary checkout. Stage 1 (reconstructed Primary Icon) must stop for owner visual approval before Stage 2; Stage 2 (all nine icon identities, three authored appearances each) must stop for owner visual approval before Stage 3 (Xcode integration). Only Stage 4 may close engineering validation. Keep review evidence on the same PR; commits at gates are allowed, but absence of approval is a blocker, not permission to continue. Do not merge until all approvals, tests, and iPhone/iPad physical visual qualification pass.

## Execution amendments incorporated October 23, 2026

These are **engineering feasibility and evidence clarifications**, not changes to the approved Q1–Q12 product decisions. The reviewed starting point is commit 231d431c29acee1da74cbde53700491866657a02; the new single implementation branch was created from verified remote main 6e01909b2c7c1ef23df4a06f531114db0c1803c2. Preserve newer main changes during local worktree setup, keep the existing checkout untouched, and reuse the reviewed design documentation without silently losing rationale.

1. **Move feasibility left (Stage 1).** Before locking in the hybrid source/export format, build a disposable Xcode 27 prototype project with one primary icon and one temporary alternate, both using provisional Default/Dark/Tinted appearances. Reuse the Primary artwork rather than beginning the seven alternates or Development artwork before Gate 1. Keep the compiled device product and inspect generated primary/alternate metadata, appearance mappings and resources. Rationale: discovering an incompatible asset package after nine icons are authored causes avoidable rework and can undermine the visual gates. A failed probe is a Stage 1 blocker.
2. **Production App target isolation (Stage 3).** Scope icon build settings and resource membership solely to the App target. Existing Debug and Release xcconfigs are project-level and must not receive app-icon settings that transitively alter test targets and hosts. Verify resolved per-target settings, PBX resource membership and actual target payloads. Rationale: preventing test host/icon collisions is part of correctness, not cosmetic cleanup.
3. **Physical validation without switching API (Stage 4).** Qualify **every one of the nine icon identities** as a *primary* icon using disposable separately signed apps installed on physical iPhone and iPad, in all relevant Home Screen appearance modes. Independently inspect the **seven registered shipping alternate identities** in exact production Debug/Release products. Do not invoke runtime icon-selection APIs or describe disposable primary inspection as proof of runtime alternate switching; issue #54 owns that test and behavior.
4. **Retain and inspect actual products (Stage 4).** Keep the exact Debug and Release generic-device App.app builds and .xcarchives until generated Info.plist keys (including CFBundleIcons~ipad where emitted), seven alternate-name sets, development-resource exclusion, compiled appearance resources, build settings and full resource manifests have been inspected and saved with hashes. A green CI check alone cannot establish those release-specific properties. Rationale: build success does not imply correct icon registration or packaging isolation.
5. **Verify original source and count distinct concepts.** The unaltered user-provided reference PNG was independently verified as **1536×1024 RGBA PNG (2,177,931 bytes)**, SHA-256 **92dc5f23741c424d5eceb3c308a041b73ad17a2140fc7b3631cd93f866073975**. Before any reconstruction, verify the exact available original again and verify its unchanged repository copy; fail closed if missing or mismatched. There are **27 authored appearances across nine source identities**, **eight configured identities in each build** (Primary/Development + seven alternates), and toolchain-dependent **compiled resource/rendition-file counts**. Never treat these numbers as interchangeable.

**Gate invariants preserved:** Owner Gate 1 must approve Primary artwork before any family artwork; Gate 2 must approve the entire family before production App integration. No automatic promotion through either gate, no runtime icon selection, and no merge before physical qualification.

## Implementation plan and verification constraints

See [the staged icon-family implementation plan](../design/icon-family/implementation-plan.md), maintained on the design documentation branch until incorporated into the implementation branch. The existing documentation branch is **not** a second implementation PR.

- Use `ASSETCATALOG_COMPILER_APPICON_NAME` and an explicit seven-name list in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` **only at the App target's build configuration**, not in project-level Debug/Release xcconfigs. Prohibit `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS=YES`; prove by retained product inspection that the Development Icon is absent from Release.
- Confirm Xcode 27 packaging feasibility during Stage 1 with the disposable Primary-plus-temporary-alternate probe before finalizing the export pipeline; then reuse the proven method for all icons. Do not hand-edit generated `CFBundleIcons` keys. Retain test and production artifacts for inspection.
- Validate three separate concerns: source-reference provenance, faithful editable production renders, and actual installed Home Screen appearance. Asset-hash validation cannot substitute for human visual review.
- Retain all existing decoy, entitlement, privacy, and runtime navigation behavior without changes. Issue #54 will make the bundled Pro icon identities selectable in a later task.
