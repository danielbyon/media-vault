"""Generate the nine Folaro icon-family identities and their Default, Dark, and Tinted treatments. The shared v12 master and appearance SVG sources are read from this directory; generated SVGs and 1024-pixel PNG renders are written to the sibling `svg` and `png` directories. Run this regeneration script before composing or validating the contact sheet."""

from pathlib import Path
import xml.etree.ElementTree as ET
import colorsys,copy,math,subprocess,json,hashlib
from concurrent.futures import ThreadPoolExecutor
P=Path(__file__).parent;N='http://www.w3.org/2000/svg';ET.register_namespace('',N);ET.register_namespace('xlink','http://www.w3.org/1999/xlink')
BASE=P/'source/Core-Tight-Tentatively-Approved-v12.svg'
IDENTITIES=['Default','Mineral','Indigo','Folaro-Dev','Instrument','Grid','Compass','Calculator','Calculator-Glass'];APPEARANCES=['Default','Dark','Tinted']
DEFS='''<defs>
<radialGradient id="bg" cx=".15" cy=".04" r="1.1"><stop stop-color="#2a425d"/><stop offset=".5" stop-color="#111f2d"/><stop offset="1" stop-color="#050c13"/></radialGradient>
<linearGradient id="metal" x1=".12" y1="0" x2=".85" y2="1"><stop stop-color="#f3f8ff"/><stop offset=".16" stop-color="#b4c8e7"/><stop offset=".36" stop-color="#45658a"/><stop offset=".54" stop-color="#233951"/><stop offset=".75" stop-color="#bac9e3"/><stop offset=".91" stop-color="#edf5ff"/><stop offset="1" stop-color="#5d789a"/></linearGradient>
<linearGradient id="blue" x1=".05" y1=".15" x2=".8" y2=".9"><stop stop-color="#9cffff"/><stop offset=".15" stop-color="#00d8ff"/><stop offset=".38" stop-color="#007eff"/><stop offset=".64" stop-color="#0036c3"/><stop offset=".85" stop-color="#03a7f6"/><stop offset="1" stop-color="#96ffff"/></linearGradient>
<radialGradient id="face" cx=".25" cy=".15" r=".95"><stop stop-color="#526a86"/><stop offset=".35" stop-color="#293e58"/><stop offset=".8" stop-color="#0b1726"/><stop offset="1" stop-color="#030a13"/></radialGradient>
<linearGradient id="knob" x1=".05" y1="0" x2=".85" y2="1"><stop stop-color="#c9dbeb"/><stop offset=".18" stop-color="#61758b"/><stop offset=".42" stop-color="#293847"/><stop offset=".62" stop-color="#0d1822"/><stop offset=".9" stop-color="#24384c"/><stop offset="1" stop-color="#617b98"/></linearGradient>
<radialGradient id="tile-blue" cx=".25" cy=".15" r="1"><stop stop-color="#b8e5ff"/><stop offset=".15" stop-color="#5086b0"/><stop offset=".5" stop-color="#1d5079"/><stop offset=".8" stop-color="#113456"/><stop offset="1" stop-color="#7faad4"/></radialGradient>
<linearGradient id="tile-silver" x1=".1" y1="0" x2=".8" y2="1"><stop stop-color="#f4faff"/><stop offset=".24" stop-color="#b4cce7"/><stop offset=".52" stop-color="#849dbe"/><stop offset=".8" stop-color="#e0edff"/><stop offset="1" stop-color="#ffffff"/></linearGradient>
<radialGradient id="tile-electric" cx=".2" cy=".12" r="1.1"><stop stop-color="#bcffff"/><stop offset=".18" stop-color="#1797ff"/><stop offset=".46" stop-color="#0041ff"/><stop offset=".7" stop-color="#006dea"/><stop offset=".9" stop-color="#00d3ff"/><stop offset="1" stop-color="#aaffff"/></radialGradient>
<radialGradient id="tile-dark" cx=".2" cy=".1" r="1"><stop stop-color="#b5c7db"/><stop offset=".2" stop-color="#536d89"/><stop offset=".5" stop-color="#202e42"/><stop offset=".8" stop-color="#121d2d"/><stop offset="1" stop-color="#7a91af"/></radialGradient>
<radialGradient id="button" cx=".3" cy="0" r="1.1"><stop stop-color="#657484"/><stop offset=".5" stop-color="#394450"/><stop offset="1" stop-color="#151e29"/></radialGradient>
<radialGradient id="orange" cx=".3" cy=".1" r="1"><stop stop-color="#ffe1a9"/><stop offset=".2" stop-color="#ffad3d"/><stop offset=".6" stop-color="#ff7900"/><stop offset="1" stop-color="#bc4300"/></radialGradient>
<radialGradient id="glass-blue" cx=".28" cy=".17" r=".85"><stop stop-color="#b2e8ff" stop-opacity=".8"/><stop offset=".23" stop-color="#608fbc" stop-opacity=".72"/><stop offset=".6" stop-color="#1c4f89" stop-opacity=".6"/><stop offset="1" stop-color="#81bbf4" stop-opacity=".83"/></radialGradient>
<radialGradient id="specular"><stop stop-color="#ffffff" stop-opacity=".65"/><stop offset=".4" stop-color="#c5e7ff" stop-opacity=".2"/><stop offset="1" stop-color="#a1dbff" stop-opacity="0"/></radialGradient>
<filter id="shadow" x="-.4" y="-.4" width="1.8" height="1.8"><feGaussianBlur in="SourceAlpha" stdDeviation="14" result="blur"/><feOffset in="blur" dx="0" dy="15" result="offset"/><feComponentTransfer in="offset" result="shadow-alpha"><feFuncA type="linear" slope=".6"/></feComponentTransfer><feMerge><feMergeNode in="shadow-alpha"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
<filter id="soft"><feGaussianBlur stdDeviation="5"/></filter>
</defs>'''
def symbol(kind,cx,cy,size=45,color='#eef7ff'):
 """Return SVG markup for a simple line symbol positioned by center, size, and color."""
 z=size/2
 s=f'<g fill="none" stroke="{color}" stroke-width="14" stroke-linecap="round">'
 if kind=='+':s+=f'<path d="M{cx-z} {cy} H{cx+z} M{cx} {cy-z} V{cy+z}"/>'
 if kind=='-':s+=f'<path d="M{cx-z} {cy} H{cx+z}"/>'
 if kind=='x':s+=f'<path d="M{cx-z*.8} {cy-z*.8} L{cx+z*.8} {cy+z*.8} M{cx+z*.8} {cy-z*.8} L{cx-z*.8} {cy+z*.8}"/>'
 if kind=='=':s+=f'<path d="M{cx-z} {cy-13} H{cx+z} M{cx-z} {cy+13} H{cx+z}"/>'
 return s+'</g>'
def utility(identity):
 """Build the SVG artwork for one utility-family identity."""
 s=['<svg xmlns="'+N+'" width="1024" height="1024" viewBox="0 0 1024 1024"><title>Folaro '+identity+'</title>',DEFS,'<rect width="1024" height="1024" fill="url(#bg)"/>']
 if identity in ['Instrument','Compass']:
  s+=['<circle cx="512" cy="512" r="382" fill="url(#metal)" stroke="#daeaff" stroke-width="2" filter="url(#shadow)"/>','<circle cx="512" cy="512" r="314" fill="url(#face)" stroke="#0d1723" stroke-width="9"/>','<circle cx="512" cy="512" r="308" fill="none" stroke="#7189a5" stroke-width="2"/>']
  if identity=='Instrument':s+=['<path d="M203 735 A382 382 0 0 1 563 133 L553 201 A314 314 0 0 0 258 695 Z" fill="url(#blue)" stroke="#96f6ff" stroke-width="2"/>']
  for i in range(20):
   a=(i*18-90)*math.pi/180;r1=269 if i%5 else 253;r2=291
   s+=[f'<path d="M{512+r1*math.cos(a):.3f} {512+r1*math.sin(a):.3f} L{512+r2*math.cos(a):.3f} {512+r2*math.sin(a):.3f}" stroke="'+('#72cfff' if identity=='Instrument' and i>10 else '#d6e5f6')+'" stroke-width="'+('7' if i%5==0 else '4')+'" opacity=".86"/>']
  if identity=='Instrument':s+=['<circle cx="512" cy="512" r="177" fill="url(#knob)" stroke="#b9c9db" stroke-width="5" filter="url(#shadow)"/>','<ellipse cx="466" cy="423" rx="105" ry="47" transform="rotate(-35 466 423)" fill="url(#specular)"/>']
  else:s+=['<g filter="url(#shadow)"><path d="M700 334 L550 711 L483 543 L330 506 Z" fill="url(#blue)" stroke="#a0ddff" stroke-width="2"/><path d="M700 334 L483 543 L550 711 L556 496 Z" fill="#0053ee" opacity=".85"/><path d="M700 334 L330 506 L483 543 Z" fill="#75e8ff" opacity=".65"/></g>']
 if identity=='Grid':
  for (x,y,g) in [(180,180,'tile-blue'),(532,180,'tile-silver'),(180,532,'tile-electric'),(532,532,'tile-dark')]:
   s +=[f'<rect x="{x}" y="{y}" width="312" height="312" rx="88" fill="url(#{g})" stroke="#ccedff" stroke-width="3" filter="url(#shadow)"/>',f'<rect x="{x+9}" y="{y+9}" width="294" height="294" rx="80" fill="none" stroke="#ffffff" stroke-opacity=".16" stroke-width="6"/>',f'<ellipse cx="{x+97}" cy="{y+49}" rx="110" ry="35" fill="url(#specular)"/>']
 if identity=='Calculator':
  s+=['<rect x="142" y="124" width="740" height="288" rx="116" fill="url(#metal)" filter="url(#shadow)"/>','<rect x="155" y="137" width="714" height="262" rx="105" fill="#0a1119"/>','<rect x="169" y="150" width="686" height="234" rx="94" fill="url(#knob)" stroke="#708396" stroke-width="2"/>','<rect x="190" y="163" width="640" height="200" rx="82" fill="#080f17" opacity=".6"/>','<ellipse cx="763" cy="267" rx="39" ry="67" fill="none" stroke="#eff6ff" stroke-width="12"/>']
  for x,y,g,k in [(142,462,'button','+'),(532,462,'button','-'),(142,675,'button','x'),(532,675,'orange','=')]:
   s+=[f'<rect x="{x}" y="{y}" width="350" height="174" rx="87" fill="url(#{g})" stroke="#a4b4c4" stroke-width="2" filter="url(#shadow)"/>',symbol(k,x+175,y+87,87)]
 if identity=='Calculator-Glass':
  s+=['<ellipse cx="733" cy="777" rx="295" ry="285" fill="#694967" opacity=".22" filter="url(#soft)"/>']
  for x,y,g,k in [(307,307,'glass-blue','+'),(717,307,'glass-blue','-'),(307,717,'glass-blue','x'),(717,717,'orange','=')]:
   s+=[f'<circle cx="{x}" cy="{y}" r="188" fill="url(#{g})" stroke="#b6deff" stroke-width="3" filter="url(#shadow)"/>',f'<circle cx="{x}" cy="{y}" r="179" fill="none" stroke="#ffffff" stroke-opacity=".15" stroke-width="7"/>',f'<ellipse cx="{x-40}" cy="{y-106}" rx="115" ry="45" fill="url(#specular)"/>',symbol(k,x,y,109)]
 s+=['</svg>'];return ET.fromstring(''.join(s))
def recolor(root,fn,skipbg=False):
 """Apply a color transformation to SVG fill and stroke attributes, optionally leaving background fills unchanged."""
 for n in root.iter():
  if skipbg and n.get('id')=='bg':continue
  for k,v in list(n.attrib.items()):
   if len(v)==7 and v.startswith('#'):
    try:rgb=tuple(int(v[i:i+2],16)/255 for i in (1,3,5))
    except ValueError:continue
    n.set(k,'#'+''.join(f'{max(0,min(255,round(c*255))):02x}' for c in fn(rgb)))
def profile(rgb,name):
 """Convert an RGB color to the requested material profile, including the Mineral and Indigo treatments."""
 h,l,s=colorsys.rgb_to_hls(*rgb)
 if name=='Mineral':
  if s>.35 and l<.8:h=.57;s*=.58;l=.31+.63*l
 elif name=='Indigo':
  if s>.35:h=.637 if h>.58 else .6;l*=.76;s=min(1,s*1.05)
 return colorsys.hls_to_rgb(h,l,s)
def appearance(rgb,name):
 """Convert an RGB color to the requested appearance treatment, including Dark and grayscale Tinted output."""
 h,l,s=colorsys.rgb_to_hls(*rgb)
 if name=='Tinted':
  y=.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2];return(y,y,y)
 if name=='Dark':return colorsys.hls_to_rgb(h,l*(.78 if l<.7 else .9),s*.95)
 return rgb
def build():
 """Generate each identity and appearance SVG, then render the corresponding 1024-pixel PNG files."""
 (P / "svg").mkdir(parents=True, exist_ok=True)
 (P / "png").mkdir(parents=True, exist_ok=True)
 outputs=[]
 for ident in IDENTITIES:
  root=ET.parse(BASE).getroot() if ident in IDENTITIES[:4] else utility(ident)
  if ident in ['Mineral','Indigo']:
   # Only material groups recolor: graphite is shared with the primary.
   bg=root.find('.//*[@id="bg"]');saved=copy.deepcopy(bg)
   recolor(root,lambda rgb:profile(rgb,ident));bg[:]=saved[:]
  if ident=='Folaro-Dev':
   root.append(ET.fromstring('<g xmlns="'+N+'" id="development-badge"><defs><linearGradient id="badge" x1="0" y1="0" x2=".6" y2="1"><stop stop-color="#fbffff"/><stop offset=".5" stop-color="#bddbff"/><stop offset="1" stop-color="#709ac6"/></linearGradient></defs><rect x="685" y="781" width="255" height="122" rx="60" fill="url(#badge)" stroke="#e5f8ff" stroke-width="3"/><g transform="translate(751.8415 820.4) scale(1.35)" fill="none" stroke="#102338" stroke-width="5" stroke-linejoin="round" id="development-lettering"><path d="M0 0 V32 H10 C30 32 30 0 10 0 Z M38 0 V32 M38 0 H59 M38 15 H56 M38 32 H59 M68 0 L79 32 L90 0"/></g></g>'))
  for app in APPEARANCES:
   r=copy.deepcopy(root)
   if app!='Default':recolor(r,lambda rgb:appearance(rgb,app))
   name=ident+'-'+app
   r.find('{'+N+'}title').text='Folaro '+ident+' — '+app+' appearance; review candidate'
   path=P/'svg'/f'{name}.svg';ET.indent(r);ET.ElementTree(r).write(path,encoding='utf-8',xml_declaration=True)
   outputs.append((path,P/'png'/f'{name}.png'))
 def render(pair):
  a,b=pair;subprocess.run(['inkscape',str(a),'--export-filename='+str(b),'--export-width=1024'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 for pair in outputs:render(pair)
 print('Rendered',len(outputs),'SVG / PNG appearance pairs.')
if __name__=='__main__':build()
