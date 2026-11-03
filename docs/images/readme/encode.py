"""Encode the original render.mjs diagram frames as a compact 12-second GIF.

Usage: python encode.py /path/to/frames
Requires Pillow. No screenshots or product images are modified.
"""
from pathlib import Path
import sys
from PIL import Image

assets = Path(__file__).resolve().parent
frames_dir = Path(sys.argv[1])
palette = Image.open(assets / 'recursive-world.png').convert('RGB').quantize(colors=96)
frames = [Image.open(p).convert('RGB').quantize(palette=palette, dither=Image.Dither.NONE)
          for p in sorted(frames_dir.glob('frame-*.png'))]
assert len(frames) == 120, 'Expected 120 diagram frames from render.mjs'
frames[0].save(assets / 'recursive-world.gif', save_all=True, append_images=frames[1:],
               duration=100, loop=0, optimize=True, disposal=1)
palette = Image.open(assets / 'recursive-world-mobile.png').convert('RGB').quantize(colors=96)
frames = [Image.open(p).convert('RGB').quantize(palette=palette, dither=Image.Dither.NONE)
          for p in sorted((frames_dir / 'mobile').glob('frame-*.png'))]
assert len(frames) == 120
frames[0].save(assets / 'recursive-world-mobile.gif', save_all=True, append_images=frames[1:],
               duration=100, loop=0, optimize=True, disposal=1)
