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
(P/'README.md').write_text('''# Folaro icon family — visual review candidate

1. Nine identities, each with Default, Dark and grayscale Tinted appearances: 27 SVG files and 27 opaque 1024 × 1024 PNG renders.
2. Default, Mineral, Indigo and Folaro Dev retain all identified curves from the tentatively approved v12 master. The Default render is pixel-identical to the v12 preview. Mineral and Indigo use material color profiles; Dev adds an editable vector DEV badge.
3. Instrument, Grid, Compass, Calculator and Calculator Glass follow the original reference board. These reconstructions and all appearance treatments await family visual approval.
4. The composite uses rounded tiles for presentation only. Exported PNGs are square with full opaque backgrounds, allowing platform masking later. Grayscale Tinted artwork is intended for native system tinting; it deliberately does not reproduce the board's blue-tinted mockups literally.
5. SVG geometry and material layers are editable. PNGs are target renders. The original reference board and tentatively approved source master are preserved under source/.
6. To regenerate these artwork files, install Python 3, Pillow, NumPy, and Inkscape. From this directory run `python3 render_family.py`, then `python3 compose_board.py`, then `python3 verify_and_package.py`. Run the steps sequentially to avoid incomplete parallel exports. The final command rewrites this README and `manifest.json` and creates `../Folaro-Icon-Family-Review.zip`; run it only when regeneration is intended.
7. The catalog is integrated into Media Vault's App target: Debug uses `AppIcon-FolaroDev` and Release uses `AppIcon-Default`. Alternate registration and runtime switching are not implemented. The family remains a visual-review candidate; physical-device qualification and owner approval are pending.

Validation checks the complete inventory, PNG decoding, dimensions, opacity, grayscale Tinted channels, unique SVG identifiers, unchanged shared curve data and exact primary-render equality. manifest.json records all appearance-file SHA-256 values.
''')
archive=P.parent/'Folaro-Icon-Family-Review.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
 for f in sorted(P.rglob('*')):
  if f.is_file():z.write(f,str(f.relative_to(P)))
print(json.dumps({'identities':9,'svg':27,'png':27,'validation':'passed','archive_bytes':archive.stat().st_size,'composite':str(P/'Folaro-Icon-Family-Composite.png')}))
