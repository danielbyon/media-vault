# Folaro app icon asset integration — 2026-10-25

Source: `Folaro-Icon-Family-Review.zip`, SHA-256:
`596dabe942fc6415c9c247c322f7760bfdb1c24e11e09cf904875abf96b55c6a`.

Integration transport package: `Folaro-Asset-Catalog-Integration-70deaac6.zip`, 13,442,403 bytes, SHA-256 `70deaac673eb4da0d49de392d16ef3dbe24dba03a12ca8714e63a26089d35239`. The source hash above identifies the upstream artwork review ZIP; it is distinct from the integration transport package.

The source manifest calls these **family visual review candidates**; adding them to the project does **not** imply completed visual approval or physical iOS/iPadOS qualification. The original 1536×1024 showcase under `source/Original-Reference-Board.png` matches the canonical reference SHA-256 `92dc5f23741c424d5eceb3c308a041b73ad17a2140fc7b3631cd93f866073975`.

- `source/Core-Tight-Tentatively-Approved-v12.svg` preserves the editable geometry master; `svg/*.svg` contain each authored appearance treatment.
- `manifest.json` binds all 27 SVG and 27 PNG appearance hashes; `render_family.py`, `compose_board.py`, and `verify_and_package.py` are source-package regeneration/verification tools. They do **not** run during ordinary Xcode builds.
- The Xcode asset catalog contains nine `.appiconset` groups, each with 1024×1024 PNGs for Default, Dark, and grayscale Tinted appearances.
- Build-time primary app icons: **Debug `AppIcon-FolaroDev`**, **Release `AppIcon-Default`**.
- The seven other `.appiconset` families are catalog authoring inputs only. They are not registered as alternates, selectable at runtime, or included as alternate icons in the generated app bundle. No icon picker or switching API is implemented.
- The Xcode `actool` compiler (not `Info.plist` source editing) supplies the primary icon metadata. The build explicitly uses `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = NO` and an empty `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`.

This is a narrowly scoped integration that supersedes the earlier Stage 3 plan **only for runtime alternate registration**, which is deferred. Do not interpret the unregistered catalog assets as functional runtime icon choices. Compiled Release metadata confirms that only `AppIcon-Default` is included and no DEV artwork is selected. Validate installed appearances on iPhone and iPad before marking production art approved.

Operational note: `verify_and_package.py` is a mutating regeneration command, not read-only validation. It rewrites this directory’s `README.md` and `manifest.json` and creates `../Folaro-Icon-Family-Review.zip`; run it only when regenerating those artifacts is intended.
