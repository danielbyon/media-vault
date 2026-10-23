# Icon family implementation plan

Status: **Q1–Q12 accepted. Five execution amendments incorporated; owner artwork approval gates 1 and 2 remain mandatory.**

Source decisions: [ADR-0001](../../adr/0001-preserve-icon-family-design.md). Terminology: [CONTEXT.md](../../../CONTEXT.md). Primary external product work item: [GitHub issue #54](https://github.com/danielbyon/media-vault/issues/54), reserved for runtime icon selection.

**Reviewed starting point:** documentation commit 231d431c29acee1da74cbde53700491866657a02. This implementation branch was established from verified remote main 6e01909b2c7c1ef23df4a06f531114db0c1803c2. Re-fetch origin/main before creating the local implementation worktree, verify both heads, and safely reconcile any newer main changes; do not replace a newer file with an older document.

## Goal and constraints

Implement nine faithful editable icon identities (Primary, Development, Mineral, Indigo, Instrument, Grid, Compass, Calculator, Calculator Glass) and three explicitly authored system appearances (Default, Dark, Tinted) for each. The unaltered supplied 1536×1024 RGBA PNG (2,177,931 bytes) is the reference authority; preserve its SHA-256 **92dc5f23741c424d5eceb3c308a041b73ad17a2140fc7b3631cd93f866073975** in the repository alongside it. The source image must be copied from the user's uploaded file—not substituted with previously reconstructed or newly generated imagery. **Before reconstruction, verify the exact original PNG, its dimensions/color format and this SHA-256, then copy it unchanged to docs/design/icon-family/approved-showcase.png and verify the copied hash. Missing/mismatched source is a blocker.**

**Inventory semantics:** Nine source identities times three authored appearances equals **27 authored source appearances**. Each shipping configuration registers **eight identities**: Release Primary plus seven Pro alternates, or Debug Development plus the same seven Pro alternates. Xcode may compile several appearances into one Assets.car or other rendition files; compiled resource-file counts do not equal, and must not be inferred from, either number. Prove these three facts independently.

Reconstruct at production fidelity from hybrid layered masters (vector geometry, controlled lighting/raster effects). Store editable masters, deterministic exporters and output asset catalogs in version control. No authoring dependency may run during ordinary Xcode builds or CI. Preserve original silhouettes, aperture, interweaving, highlights, palette, and distinctive differences between the seven Pro alternatives. Tinted artwork is grayscale; user tint and Clear presentation are system-owned. Review actual installed rendering on device.

Pro icon files may be bundled and registered but **must not become selectable** in this task: no icon picker, entitlement policy, icon-setting API invocation, persistence, backup changes, or decoy behavior changes. Keep all runtime/source symbols brand-neutral.

## Implementation delivery model

Create an **isolated local worktree for the single branch codex/icon-family-production-assets**, based on verified current origin/main. The GitHub branch was created at 6e01909b2c7c1ef23df4a06f531114db0c1803c2; fetch remote heads and resolve any origin/main advancement before local worktree creation. Preserve every dirty path in the primary checkout and existing worktrees. Carry the reviewed CONTEXT.md, ADR-0001 and implementation-plan.md forward from commit 231d431c29acee1da74cbde53700491866657a02 with these amendments; never overwrite newer main changes. Open **one draft PR**, using staged commits/evidence. The earlier design-documentation branch is not a separate implementation PR.

Each stage records exact input/output hashes, reproducibility instructions, and review evidence. Owner approval is explicit at Stage 1 and Stage 2; absence of an answer means STOP. After technical verification, request acceptance before merge. No autonomous background work and no automatic merge.

### Stage 1 — Primary artwork and disposable Xcode 27 packaging probe (Owner visual approval gate 1)

1. **Verify reference before reconstruction.** Obtain the exact original uploaded PNG (1536 × 1024 RGBA); calculate its SHA-256, require an exact match to **92dc5f23741c424d5eceb3c308a041b73ad17a2140fc7b3631cd93f866073975**, and check in the unchanged file at docs/design/icon-family/approved-showcase.png. Rehash the repository copy and record provenance. If missing or mismatched, STOP; do not substitute crops, older generated packs or synthesized imagery.
2. **Prototype only the Primary Icon.** Reconstruct the four interwoven segments, central circular aperture and optical-glass layering as an editable hybrid master. Produce provisional Default, Dark and grayscale Tinted renders suitable for testing packaging. Do not produce Mineral, Indigo, Instrument, Grid, Compass, Calculator, Calculator Glass or Development artwork before Gate 1.
3. **Probe packaging before committing to the export/master pipeline.** In a **disposable** Xcode 27 project/target or isolated project copy that cannot leak into the shipping App, build a generic-iOS-device product containing the prototype as its primary icon **and one temporary alternate** (reuse provisional Primary artwork for the alternate if useful). Explicitly author Default, Dark and Tinted appearances for both identities. Evaluate candidate asset packaging (.appiconset and/or .icon/other supported form), compile it, and inspect retained generated Info.plist primary/alternate keys, appearance mappings, compiled assets and resource manifest. Record Xcode version, exact command, output product path, content hashes and observed metadata. An invalid or uninspectable primary/alternate or missing appearance is a packaging-feasibility failure: fix and rerun **in Stage 1**, not Stage 3.
4. **Then choose/finalize production masters and exporters.** Only after the packaging probe succeeds, select the hybrid source format, reproducible gradient/raster lighting passes and deterministic output pipeline. Commit editable Primary master, exporter configuration/tool versions, reproducible instructions, rendered source outputs and checksums. Normal builds and CI consume checked-in exports and do not execute creative/authoring tools.
5. **Owner Gate 1.** Present Default/Dark/Tinted Primary prototype against the unmodified original board, at full 1024px and representative small Home Screen sizes and backgrounds, together with the successful packaging probe evidence. **STOP until the owner explicitly approves the Primary Icon.** Technical packaging success never substitutes for visual approval. Any correction repeats review before family work.

### Stage 2 — Family artwork (Owner visual approval gate 2)

1. With the approved primary geometry as baseline, construct Mineral, Indigo, Instrument, Grid, Compass, Calculator, Calculator Glass, and the distinct Development design (DEV badge). Retain reference-specific visual geometry; share master components where useful but do not force unrelated utility/calculator icons to use the primary ring.
2. Author each identity's Default, Dark and grayscale Tinted appearances: nine identities × three assets = **27 authored appearances**.
3. Generate a family contact sheet and each appearance at 1024px and representative small launch-icon sizes. Check transparent/opaque composition, edge safety, label legibility, grayscale contrast, and expected tint behavior without hard-coded user color.
4. Record deterministic build/export verification and hashes; user reviews every icon/appearance, not just the primary. **Stop until explicitly approved.**

### Stage 3 — Production App-target-only Xcode integration (after owner Gate 2)

1. Use the Xcode 27 asset packaging method proven in Stage 1; re-evaluate only if production reveals a documented, material contradiction. **Do not defer feasibility testing to this stage.**
2. Scope icon build settings **to the App PBXNativeTarget**, per Debug/Release configuration. Existing Debug/Release xcconfigs are project-level; do **not** place App icon keys there where test hosts/bundles inherit them. Use the App target's build settings or target-only xcconfig references. Verify the resolved icon settings for the App target **and for every other Xcode target**, covering hosted test apps, UI test hosts and test bundles.
3. Scope asset-catalog/resource membership **to the App target only**; merely seeing an asset in the Xcode navigator does not prove correct membership. Verify target resource-phase membership and inspect product payloads for accidental duplication in unrelated test targets or host bundles.
4. Release primary = Core Tight—Circle; Debug primary = Development with DEV treatment. Each gets exactly seven registered Pro alternates, so **eight configured identities** in each configuration; there are still **27 authored appearance assets** in the full source family. Compile-time asset/resource counts may differ from both. Ensure Release contains **neither Development icon registration nor its artwork/resources**; do not rely only on hiding its plist entry. Do not include all app icon assets indiscriminately or expose Release Primary as an extra Debug alternate.
5. Let Xcode generate primary/alternate icon metadata, including iPad-specific metadata if emitted, rather than hand-editing CFBundleIcons in Info.plist. Confirm actual Debug/Release built products, resolved build settings and explicit resource inventory. **Do not add a picker, call any runtime icon-selection API, change entitlements/persistence/backup behavior or modify the calculator decoy.**

### Stage 4 — Qualification and completion

1. **Source and export verification.** Regenerate from versioned masters and compare output hashes; validate the source inventory of **27 authored appearances** (nine identities × Default/Dark/grayscale Tinted), dimensions, formats, alpha/colorspace and geometry. Do not equate this count to eight configured identities per binary or to compiled resource-file counts.
2. **Retained Debug/Release device builds and archives.** Execute and log the explicit build/archive commands defined below. Preserve the **exact unsigned device-build App.app copies and both xcarchives**, corresponding full build logs, resolved per-target build settings, generated plist dumps, asset catalog/rendition information and complete resource manifests until inspection is recorded. For each Debug/Release device build and archive, verify CFBundleIcons, the CFBundleIcons~ipad dictionary when emitted, exact seven alternate identifiers, appearance mapping, unexpected entries, resource membership and actual Release Development-icon exclusion. Check the Development image is **not physically present** in the Release payload. A successful existing CI run **alone** is never sufficient evidence for these checks.
3. **Physical verification of every identity on iPhone and iPad, without runtime switching APIs.** Construct **disposable, separately identified signed inspection apps** that temporarily install each of the **nine source identities as the primary icon**; install and observe each on a physical iPhone **and** iPad. Capture light, dark, tinted and Clear Home Screen appearances under contrasting wallpapers/tints, at actual icon scale. Verify each design against the reference and the DEV badge's readability. These inspections establish **visual qualification only**; they do **not** test runtime alternate switching, user selection or Pro entitlement gating. Issue #54 owns those behaviors. **Separately** verify all seven shipping alternate registrations from the retained production builds/archives and compiled asset mappings.
4. **Review.** Confirm owner approval Gate 1 preceded all family artwork and Gate 2 preceded production integration. Compare device screenshots against the approved board, run targeted/full tests, strict lint and build gates, and obtain independent Standards and Spec reviews. Resolve in-scope defects without modifying unrelated targets or privacy/decoy behavior.
5. **Closeout evidence.** Report source master and generated SHA-256s, resolved Xcode settings, original reference identity, retained product/archive locations and hashes, Debug/Release primary/alternate metadata, exclusion proofs, physical device/OS/screenshots, test results, review findings and anything inconclusive. Keep the **single** PR draft/unmerged until accepted. Never describe disposable primary-icon inspection as runtime alternate switching validation.

## Retained qualification commands

The following is a required **inspection-only device build/archive procedure** for the implementation worktree; do not run in the dirty primary checkout. The Xcode 27 disposable packaging probe in Stage 1 must use the same retention principles for its Primary prototype and temporary alternate. These commands intentionally preserve every exact device build and archive output in a run-specific directory. Record the current Git SHA, selected Xcode, all target settings and raw logs before making product-level claims. Signing-disabled device products cannot be installed; use **separate properly signed disposable inspection builds** for physical iPhone/iPad visual qualification.

~~~bash
set -euo pipefail
QA_ROOT="$PWD/.build/icon-family-qualification/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$QA_ROOT/logs" "$QA_ROOT/products" "$QA_ROOT/archives" "$QA_ROOT/reports"
git rev-parse HEAD > "$QA_ROOT/reports/HEAD.txt"
xcodebuild -version > "$QA_ROOT/reports/xcode-version.txt"
xcodebuild -list -json -project App.xcodeproj > "$QA_ROOT/reports/targets.json"

for CONFIG in Debug Release; do
  DERIVED="$QA_ROOT/derived/$CONFIG"
  ARCHIVE="$QA_ROOT/archives/$CONFIG.xcarchive"

  # Inspect EVERY target, not only App. jq is a qualification-only tool.
  command -v jq >/dev/null
  TARGET_INDEX=0
  while IFS= read -r TARGET; do
    printf '%s: %s\n' "$TARGET_INDEX" "$TARGET" \
      >> "$QA_ROOT/reports/$CONFIG-target-index.txt"
    xcodebuild -project App.xcodeproj -target "$TARGET" \
      -configuration "$CONFIG" -showBuildSettings -json \
      > "$QA_ROOT/reports/$CONFIG-target-$TARGET_INDEX-build-settings.json"
    TARGET_INDEX=$((TARGET_INDEX + 1))
  done < <(jq -r '.project.targets[]' "$QA_ROOT/reports/targets.json")
  test "$TARGET_INDEX" -gt 0

  xcodebuild -workspace App.xcworkspace -scheme App \
    -configuration "$CONFIG" -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build \
    > "$QA_ROOT/logs/$CONFIG-device-build.log" 2>&1

  DEVICE_APP="$DERIVED/Build/Products/$CONFIG-iphoneos/App.app"
  test -d "$DEVICE_APP"
  mkdir -p "$QA_ROOT/products/$CONFIG"
  ditto "$DEVICE_APP" "$QA_ROOT/products/$CONFIG/App.app"

  xcodebuild -workspace App.xcworkspace -scheme App \
    -configuration "$CONFIG" -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO archive \
    > "$QA_ROOT/logs/$CONFIG-archive.log" 2>&1

  ARCHIVE_APP="$ARCHIVE/Products/Applications/App.app"
  test -d "$ARCHIVE_APP"

  for PRODUCT in device archive; do
    if [ "$PRODUCT" = device ]; then
      APP="$QA_ROOT/products/$CONFIG/App.app"
    else
      APP="$ARCHIVE_APP"
    fi
    LABEL="$CONFIG-$PRODUCT"
    plutil -p "$APP/Info.plist" > "$QA_ROOT/reports/$LABEL-Info.plist.txt"
    if [ -f "$APP/Assets.car" ]; then
      xcrun --sdk iphoneos assetutil --info "$APP/Assets.car" \
        > "$QA_ROOT/reports/$LABEL-asset-renditions.json"
    else
      printf 'Assets.car absent: inspect actual alternate compiled packaging\n' \
        > "$QA_ROOT/reports/$LABEL-asset-renditions.txt"
    fi
    find "$APP" -type f -print | LC_ALL=C sort \
      > "$QA_ROOT/reports/$LABEL-resource-files.txt"
    while IFS= read -r FILE; do
      shasum -a 256 "$FILE"
    done < "$QA_ROOT/reports/$LABEL-resource-files.txt" \
      > "$QA_ROOT/reports/$LABEL-resource-hashes.txt"
  done
done
~~~

**Mandatory follow-through before cleanup:** For **each Xcode project target**, obtain resolved settings using the target list in targets.json and the same xcodebuild -project/-target/-configuration/-showBuildSettings -json command shape; save every report and assess icon-key and resource ownership, not merely the App output. Preserve a copy of App.xcodeproj/project.pbxproj or a byte-identical project-file hash for resource-phase audit. Cross-reference the compiled Info.plist keys CFBundleIcons and (if generated) CFBundleIcons~ipad, the CFBundleAlternateIcons name set, compiled assets/renditions, the exact seven Pro alternates, and complete file-hash manifests. Prove the Release product has **neither Development registration nor its compiled artwork** using the verified Stage 1/3 packaging method. Do not infer source-family asset counts from compiled files. Preserve the exact .app copies, .xcarchive bundles, logs, target-settings JSON and reports until inspection and review are complete.

If an unsigned device archive is blocked by the current signing/toolchain setup, keep the failure log and rerun with legitimate signing settings that yield an inspectable archive. Do **not** waive the required archive inspection, replace evidence with a simulator build, infer success from CI, or delete the failed/successful product before recording its identity.

## Acceptance invariants

- Release primary = Core Tight—Circle; Debug primary = recognizable ring plus distinct DEV treatment. No Dev icon in Release.
- Exactly seven prepackaged Pro alternates in both builds; no picker, new entitlement policy, API to switch icons, or backup/persistence modification.
- **27 authored source appearances** across nine identities, **eight configured icon identities** per Debug/Release binary, and independently inspected compiled resource-file counts (not asserted equal to either number); grayscale Tinted artwork, system-controlled tint/clear behavior.
- All nine icon identities preserve their approved original board character; no blurry upscale offered as an editable source reconstruction.
- Source, masters, script, generated assets, and evidence are durable; ordinary app build has no additional graphics-tool dependency.
- Xcode 27 disposable **Primary plus temporary alternate** packaging/build probe passes in Stage 1 before export pipeline selection. Owner visual Gate 1 precedes **all** family artwork; visual Gate 2 precedes production App integration. Physical QA of **every identity on both iPhone and iPad** and independent review precede merge.
- One draft PR, one implementation worktree/branch based on verified current origin/main, zero changes to any dirty primary checkout; **App-target-only** icon settings/resources. Keep and inspect exact Debug/Release device/archive products before cleanup.

## Out of scope

Issue #54 picker, entitlement gating/revocation, device-local selection persistence, backup behavior for icon preference, and alternate-icon UX snapshots; cosmetic changes to app interior; branding the decoy; unrelated project/CI refactoring; unauthorized modifications to other Xcode targets.

## Implementation-specific questions for the agent, not new product decisions

Resolve the exact hybrid source file format/tooling **after the disposable Stage 1 Xcode 27 packaging feasibility probe**, not during production integration. Verify authored appearance mappings and actual generated metadata for the temporary alternate. Run the production build/archive retention procedure below and physical per-identity primary-install inspections without runtime selection API calls. Surface real Apple-platform contradictions with evidence instead of silently extending scope.
