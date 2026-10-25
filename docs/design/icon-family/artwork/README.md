# Folaro icon family — visual review candidate

1. Nine identities, each with Default, Dark and grayscale Tinted appearances: 27 SVG files and 27 opaque 1024 × 1024 PNG renders.
2. Default, Mineral, Indigo and Folaro Dev retain all identified curves from the tentatively approved v12 master. The Default render is pixel-identical to the v12 preview. Mineral and Indigo use material color profiles; Dev adds an editable vector DEV badge.
3. Instrument, Grid, Compass, Calculator and Calculator Glass follow the original reference board. These reconstructions and all appearance treatments await family visual approval.
4. The composite uses rounded tiles for presentation only. Exported PNGs are square with full opaque backgrounds, allowing platform masking later. Grayscale Tinted artwork is intended for native system tinting; it deliberately does not reproduce the board's blue-tinted mockups literally.
5. SVG geometry and material layers are editable. PNGs are target renders. The original reference board and tentatively approved source master are preserved under source/.
6. To regenerate these artwork files, install Python 3, Pillow, NumPy, and Inkscape. From this directory run `python3 render_family.py`, then `python3 compose_board.py`, then `python3 verify_and_package.py`. Run the steps sequentially to avoid incomplete parallel exports. The final command rewrites this README and `manifest.json` and creates `../Folaro-Icon-Family-Review.zip`; run it only when regeneration is intended.
7. The catalog is integrated into Media Vault's App target: Debug uses `AppIcon-FolaroDev` and Release uses `AppIcon-Default`. Alternate registration and runtime switching are not implemented. The family remains a visual-review candidate; physical-device qualification and owner approval are pending.

Validation checks the complete inventory, PNG decoding, dimensions, opacity, grayscale Tinted channels, unique SVG identifiers, unchanged shared curve data and exact primary-render equality. manifest.json records all appearance-file SHA-256 values.
