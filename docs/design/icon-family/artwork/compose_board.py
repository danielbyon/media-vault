"""Render the labeled Folaro icon-family contact sheet. Read the generated 1024-pixel renders from the sibling `png` directory, then write the composite and smaller preview PNGs beside this script. Running this file regenerates those two presentation images; it does not modify the source SVGs or app asset catalog."""

from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import numpy as np
P=Path(__file__).parent;W,H=2600,1840
font='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf';bold='/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
def F(size,b=False):
 """Load the regular or bold font face at the requested point size."""
 return ImageFont.truetype(bold if b else font,size)
y,x=np.mgrid[0:H,0:W];fall=np.exp(-((x-400)**2/(W*.65)**2+(y-30)**2/(H*.8)**2));bg=np.zeros((H,W,3),dtype=np.uint8)
for c,(base,delta) in enumerate([(5,19),(12,27),(18,36)]):bg[:,:,c]=base+delta*fall
board=Image.fromarray(bg);d=ImageDraw.Draw(board)
white='#eef6ff';muted='#a6bacd';faint='#71899e'
def text(s,xy,size=25,color=white,center=False,b=False):
 """Draw a text label at the supplied position. When `center` is true, measure the label and center it horizontally around the x coordinate."""
 if center:
  box=d.textbbox((0,0),s,font=F(size,b));xy=(xy[0]-(box[2]-box[0])/2,xy[1])
 d.text(xy,s,font=F(size,b),fill=color)
def tile(identity,app,x,y,size):
 """Read one generated identity/appearance PNG, fit it into a rounded tile, paste it onto the contact sheet, and draw the tile outline."""
 im=Image.open(P/'png'/f'{identity}-{app}.png').convert('RGB').resize((size,size),Image.Resampling.LANCZOS)
 mask=Image.new('L',(size,size));ImageDraw.Draw(mask).rounded_rectangle((0,0,size-1,size-1),radius=size*.2,fill=255)
 board.paste(im,(int(x),int(y)),mask)
 d.rounded_rectangle((x,y,x+size-1,y+size-1),radius=size*.2,outline='#526d86',width=1)
text('Folaro',(88,35),112,b=True);text('I C O N   F A M I L Y',(100,160),26,muted)
text('PRIVATE  /  SECURE  /  BEAUTIFUL',(1800,70),25,muted)
text('Core Tight — optical glass',(1800,112),31)
text('Family review • Default / Dark / Tinted',(1800,159),23,muted)
d.line((80,211,2520,211),fill=faint,width=1)
text('PRIMARY ICON (FREE)',(95,235),23,muted);text('BRAND VARIANTS (PRO)',(740,235),23,muted);text('DEVELOPMENT BUILD',(2010,235),23,muted)
labels={'Default':('Default','Core Tight — Circle'),'Mineral':('Mineral','Clean. Light. Refined.'),'Indigo':('Indigo','Bold. Deep. Timeless.'),'Folaro-Dev':('Folaro Dev','Same geometry. Distinct treatment.'),'Instrument':('Instrument','Focus. Measure. Control.'),'Grid':('Grid','Organize. Manage. Do more.'),'Compass':('Compass','Navigate. Explore. Aspire.'),'Calculator':('Calculator','Familiar. Discreet. Effective.'),'Calculator-Glass':('Calculator Glass','Premium. Modern. Understated.')}
for i,identity in enumerate(['Default','Mineral','Indigo','Folaro-Dev']):
 cx=350+i*635;tile(identity,'Default',cx-200,283,400)
 name,tag=labels[identity];text(name,(cx,706),35,center=True);text(tag,(cx,753),24,muted,center=True)
 for j,app in enumerate(['Default','Dark','Tinted']):
  tx=cx-229+j*174;tile(identity,app,tx,808,110);text(app,(tx+55,931),21,muted,center=True)
for xx in [665,1935]:d.line((xx,235,xx,965),fill='#3c5264',width=1)
d.line((80,1000,2520,1000),fill=faint,width=1)
text('GENERIC UTILITY VARIANTS (PRO)',(90,1028),23,muted);text('CALCULATOR VARIANTS (PRO)',(1620,1028),23,muted)
for i,identity in enumerate(['Instrument','Grid','Compass','Calculator','Calculator-Glass']):
 cx=300+i*500;tile(identity,'Default',cx-160,1084,320)
 name,tag=labels[identity];text(name,(cx,1426),30,center=True);text(tag,(cx,1468),21,muted,center=True)
 for j,app in enumerate(['Default','Dark','Tinted']):
  tx=cx-176+j*128;tile(identity,app,tx,1530,96);text(app,(tx+48,1644),19,muted,center=True)
d.line((1550,1028,1550,1700),fill='#3c5264',width=1)
text('F O L A R O   /   I C O N   F A M I L Y   /   R E V I E W',(90,1764),20,faint)
text('9 identities  •  27 authored appearances  •  Tinted artwork is grayscale for native system tinting',(1250,1764),21,muted)
text('Shared Core Tight geometry tentatively approved. Family artwork pending visual approval.',(90,1798),19,muted)
board.save(P/'Folaro-Icon-Family-Composite.png')
board.resize((1560,1104),Image.Resampling.LANCZOS).save(P/'Folaro-Icon-Family-Preview.png')
print('Composite saved: 2600 x 1840; preview: 1560 x 1104.')
