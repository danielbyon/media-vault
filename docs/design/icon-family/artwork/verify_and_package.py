"""Validate generated Folaro artwork before packaging it. This command expects SVG sources and rendered PNGs under `svg` and `png`, checks the appearance inventory, dimensions, opacity, tinted-channel values, shared geometry, primary-render equality, and reference-board hash, then rewrites `manifest.json` and this README and creates `../Folaro-Icon-Family-Review.zip`. Running it changes files; run it only when regeneration and packaging are intended."""

from pathlib import Path
from PIL import Image,ImageChops
import xml.etree.ElementTree as ET
import hashlib,json,zipfile,shutil
P=Path(__file__).parent
identities=['Default','Mineral','Indigo','Folaro-Dev','Instrument','Grid','Compass','Calculator','Calculator-Glass'];appearances=['Default','Dark','Tinted']
base=ET.parse(P/'source/Core-Tight-Tentatively-Approved-v12.svg').getroot()
basepaths={n.get('id'):n.get('d') for n in base.iter() if n.get('id') and n.get('d')}
records=[]
for identity in identities:
 for appearance in appearances:
  name=identity+'-'+appearance;svg=P/'svg'/f'{name}.svg';png=P/'png'/f'{name}.png'
  root=ET.parse(svg).getroot();ids=[n.get('id') for n in root.iter() if n.get('id')];assert len(ids)==len(set(ids))
  assert not any(n.tag.endswith('image') for n in root.iter())
  if identity in identities[:4]:
   for key,d in basepaths.items():assert root.find('.//*[@id="'+key+'"]').get('d')==d,(identity,appearance,key)
  im=Image.open(png);im.load();assert im.size==(1024,1024)
  if im.mode=='RGBA':assert im.getextrema()[3]==(255,255)
  rgb=im.convert('RGB');assert any(hi-lo>30 for lo,hi in rgb.getextrema())
  if appearance=='Tinted':
   r,g,b=rgb.split();assert ImageChops.difference(r,g).getbbox() is None and ImageChops.difference(g,b).getbbox() is None
  records.append({'identity':identity,'appearance':appearance,'svg':str(svg.relative_to(P)),'svg_sha256':hashlib.sha256(svg.read_bytes()).hexdigest(),'png':str(png.relative_to(P)),'png_sha256':hashlib.sha256(png.read_bytes()).hexdigest()})
original=Image.open(P/'source/Core-Tight-Tentatively-Approved-v12.png').convert('RGBA');primary=Image.open(P/'png/Default-Default.png').convert('RGBA');assert ImageChops.difference(original,primary).getbbox() is None
ref=P/'source/Original-Reference-Board.png';assert hashlib.sha256(ref.read_bytes()).hexdigest()=='92dc5f23741c424d5eceb3c308a041b73ad17a2140fc7b3631cd93f866073975'
(P/'manifest.json').write_text(json.dumps({'status':'family visual review candidate','shared_geometry':'tentatively approved v12','identities':9,'authored_appearances':27,'image_dimensions':[1024,1024],'grayscale_tinted_verified':True,'primary_pixel_identical_to_v12':True,'appearance_inventory':records},indent=2))
(P/'README.md').write_text("""# Folaro icon family — visual review candidate

## Source and generated files

The checked-in artwork sources are the 27 editable appearance SVGs in `svg/`, the shared master SVG and reference board in `source/`, the artwork manifest, and the composite and preview boards. The app’s shipping icon PNGs are checked in only under `App/Resources/Assets.xcassets/<appiconset>/`; the artwork directory does not duplicate those 27 files.

`render_family.py` generates `svg/*.svg` and `png/*.png` on demand. The SVG outputs replace the checked-in generated SVGs in the working copy. The 27 `png/*.png` outputs are temporary regeneration artifacts and are not checked in here. `verify_and_package.py` includes them in the ZIP it creates; those generated copies are package outputs, not checked-in artwork sources. `compose_board.py` reads those generated PNGs and regenerates the checked-in `Folaro-Icon-Family-Composite.png` and `Folaro-Icon-Family-Preview.png` presentation boards.

Each `manifest.json` appearance entry names its expected generated SVG and PNG paths and records their SHA-256 hashes. The `png` path is relative to this artwork directory. Its basename maps to the same-named PNG in the corresponding shipping asset set: `Folaro-Dev` maps to `AppIcon-FolaroDev.appiconset`, `Calculator-Glass` to `AppIcon-CalculatorGlass.appiconset`, and every other identity to `AppIcon-<identity>.appiconset`. For example, `png/Default-Default.png` corresponds to `App/Resources/Assets.xcassets/AppIcon-Default.appiconset/Default-Default.png`, and its `png_sha256` is expected to match that file. The regeneration validator hashes generated PNGs but does not read the asset catalog; compare the recorded hash with the catalog file separately when checking byte identity. The manifest describes generated output and does not require a second checked-in PNG copy.

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
""")
archive=P.parent/'Folaro-Icon-Family-Review.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
 for f in sorted(P.rglob('*')):
  if f.is_file():z.write(f,str(f.relative_to(P)))
print(json.dumps({'identities':9,'svg':27,'png':27,'validation':'passed','archive_bytes':archive.stat().st_size,'composite':str(P/'Folaro-Icon-Family-Composite.png')}))
