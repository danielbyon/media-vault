# Folaro icon family — visual review candidate

## Source and generated files

The checked-in artwork sources are the 27 editable appearance SVGs in `svg/`, the shared master SVG and reference board in `source/`, the artwork manifest, and the composite and preview boards. The app’s shipping icon PNGs are checked in only under `App/Resources/Assets.xcassets/<appiconset>/`; the artwork directory does not duplicate those 27 files.

`render_family.py` generates `svg/*.svg` and `png/*.png` on demand. The SVG outputs replace the checked-in generated SVGs in the working copy. The 27 `png/*.png` outputs are temporary regeneration artifacts and are not checked in here. `verify_and_package.py` includes them in the ZIP it creates; those generated copies are package outputs, not checked-in artwork sources. `compose_board.py` reads those generated PNGs and regenerates the checked-in `Folaro-Icon-Family-Composite.png` and `Folaro-Icon-Family-Preview.png` presentation boards.

Each `manifest.json` appearance entry names its expected generated SVG and PNG paths and records their SHA-256 hashes. The `png` path is relative to this artwork directory. Its basename maps to the same-named PNG in the corresponding shipping asset set: `Folaro-Dev` maps to `AppIcon-FolaroDev.appiconset`, `Calculator-Glass` to `AppIcon-CalculatorGlass.appiconset`, and every other identity to `AppIcon-<identity>.appiconset`. For example, `png/Default-Default.png` corresponds to `App/Resources/Assets.xcassets/AppIcon-Default.appiconset/Default-Default.png`, and its `png_sha256` is expected to match that file. The regeneration validator hashes generated PNGs but does not read the asset catalog; compare the recorded hash with the catalog file separately when checking byte identity. The manifest describes generated output and does not require a second checked-in PNG copy.

## Versioned qualification profile

The isolated qualification profile uses Python 3.14.4, Inkscape 1.4 (`e7c3feb1`, 2024-10-09) for macOS arm64, Pillow 12.3.0, NumPy 2.3.5, and the official DejaVu Sans 2.37 regular and bold fonts. The original source package specified these tools by name but did not record an operating system or exact tool versions, so this is a reproducible comparison profile, not verified historical provenance. Keep the original PNG SHA-256 values authoritative: a regenerated hash mismatch remains a mismatch even when decoded pixels are visually close.

## Regeneration

Use Python 3, Pillow, NumPy, and Inkscape. Run commands sequentially from this directory:

1. `python3 render_family.py`
2. `python3 compose_board.py`
3. `python3 verify_and_package.py`

The renderer creates its `svg/` and `png/` output directories when they are absent. `compose_board.py` requires the generated PNGs. The validator expects all generated SVGs and PNGs, rewrites this README and `manifest.json`, and creates `../Folaro-Icon-Family-Review.zip`; run it only in a staging copy when those outputs should not be replaced.

The contact sheet uses DejaVu Sans regular and bold faces. Font lookup checks deterministic Linux and macOS font locations for `DejaVuSans.ttf` and `DejaVuSans-Bold.ttf`. To use files installed elsewhere, set `FOLARO_FONT_REGULAR` and `FOLARO_FONT_BOLD` to their full paths. Missing fonts produce an actionable error; the script does not silently substitute another family. Use the matching DejaVu Sans faces to preserve the reference board’s text geometry. Selecting another font intentionally changes text metrics and may change the board layout.

## Artwork and app configuration

Nine identities—Default, Mineral, Indigo, Folaro Dev, Instrument, Grid, Compass, Calculator, and Calculator Glass—have Default, Dark, and grayscale Tinted appearances. Default, Mineral, Indigo, and Folaro Dev retain identified curves from the tentatively approved v12 master; the other reconstructions and the full family remain visual-review candidates. The composite is a presentation board; exported icon PNGs are square and opaque. Tinted artwork is grayscale for native system tinting.

The app’s primary icon is `AppIcon-FolaroDev` in Debug and `AppIcon-Default` in Release. Other catalog families are not registered as alternate icons and cannot be selected at runtime. Physical-device appearance review and owner approval remain pending.

The validator checks generated inventory, PNG decoding and dimensions, opacity, tinted-channel values, SVG identifiers, shared geometry, primary-render equality, and reference-board provenance. The manifest records source SVG and generated PNG hashes.
