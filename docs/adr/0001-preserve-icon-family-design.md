# Preserve the approved icon family through faithful, editable artwork

Status: proposed (remaining art-production, Debug packaging, and acceptance details still require decisions).

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
    - Source upload name: `Folaro Glossy Icon Family Showcase.png` (creative artifact, not a domain identifier).
    - Image dimensions: 1536 × 1024; PNG RGBA.
    - Verified SHA-256: `92dc5f23741c424d5eceb3c308a041b73ad17a2140fc7b3631cd93f866073975`.
    - Suggested check-in path: `docs/design/icon-family/approved-showcase.png`, separate from domain-spec terminology. Verify byte-for-byte hash after copying; do not substitute prior reconstructed assets.
11. **Full visual qualification (Q11=A).** Check all authored identity×appearance combinations at 1024px and representative actual Home Screen sizes, with light/dark/tinted/clear modes and contrasting backgrounds. Require real-device evidence on iPhone and iPad before final acceptance. Run deterministic size/format/assets/build checks as technical acceptance, but do not confuse those with human approval of visual fidelity. The DEV badge must remain identifiable at small sizes without changing the approved primary geometry.

## Implementation boundaries established by Apple documentation

- Xcode builds the primary icon from `ASSETCATALOG_COMPILER_APPICON_NAME` and includes declared alternates from `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`. It writes `CFBundleIcons`/alternate entries; do not edit those keys manually. https://developer.apple.com/documentation/xcode/configuring-your-app-to-use-alternate-app-icons
- Asset catalogs support iOS/iPadOS Any/Default, Dark and grayscale Tinted artwork; clear/tinted final presentation requires on-device review. https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- Icon Composer can preview default/dark/mono appearances and native effects, but it is an authoring choice, not an excuse to alter the approved design. https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer

## Final engineering gates to resolve

- Sequence of source/artwork reviews versus commits/PRs, without bypassing either owner visual approval.
- Implementer to prove Xcode 27 compatibility for the selected asset packaging, especially any differences between `.appiconset` and `.icon` when registering alternate icons.
- Clear distinctions between reference concept imagery, master artwork, exported asset catalog images, and installed runtime icons.
