#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["Pillow", "numpy", "scipy"]
# ///
"""Derive the Alt+Tab grid layout from a PrintWindow render.

Runs offline against a capture directory made by Probe-Capture-AltTab.py, so
the detector can be iterated without re-triggering the switcher.

WHY THIS REPLACES THE find_panel / connected-components APPROACH

Probe-Pixel-AltTab.py worked from a screen grab and had to guess which pixels
belonged to the panel by comparing against a "desktop reference" sampled from
the four screen corners. That is unsound on a multi-monitor setup (the corners
straddle two displays) and it made every downstream threshold depend on
whatever happened to be on the desktop. It then labelled connected components
and filtered them by area and aspect - which cannot reject the panel's chrome
ring, because a thin ring has small area but a panel-spanning bbox. Observed
failure: a 1494x656 "tile" that split a 2-row grid into rows 0 and 2.

PrintWindow(PW_RENDERFULLCONTENT) removes the guesswork: DWM redraws only the
host window, leaving premultiplied black everywhere it paints nothing. Panel
vs not-panel is then exact, with no colour reference and no desktop influence.

LAYOUT MODEL

Do not assume a fixed pitch. Tile WIDTH varies per window (it tracks thumbnail
aspect ratio) and the final row is centred, not left-aligned. Only row height
is uniform. So:

  1. panel rect  = bbox of the largest non-black component of the render
  2. panel_bg    = the solid fill colour, taken as the modal colour of the panel
  3. row bands   = runs in the row-wise density of "differs from panel_bg"
  4. tiles       = runs in the column-wise density, computed PER ROW BAND
  5. selection   = the tile whose border ring carries the saturated accent

Step 5 matters as much as the counts: clamping needs to know where the
selection currently IS, which the earlier probe never extracted.

USAGE
    uv run Probe-Grid-AltTab.py                 # newest capture
    uv run Probe-Grid-AltTab.py alttab-corpus/001
    uv run Probe-Grid-AltTab.py --all           # every capture, summary only
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import label as cc_label

CORPUS = Path(__file__).parent / "alttab-corpus"

# The render is a synthetic DWM redraw, not a photo: solid fills are bitwise
# constant, so these tolerances can be tight.
#
# BG_TOL has a hard ceiling: panel fill is #f3f3f3 and tile fill is white, only
# 12 levels apart. A tolerance at or above that makes the white body of a tile
# read as background, so runs collapse onto the dark parts of each thumbnail
# and tile widths come out badly short. It must sit below 12 while staying
# above the tile drop shadow, which is a couple of levels off the panel fill.
BLACK_TOL = 8          # channel value at or below this counts as "unpainted"
BG_TOL = 6             # distance from panel_bg before a pixel counts as content
ROW_MIN_DENSITY = 0.02  # fraction of a scanline that must be content
COL_MIN_DENSITY = 0.02
ROW_MIN_PX = 40        # ignore runs thinner than a plausible tile
COL_MIN_PX = 60


def runs(mask, min_len):
    """Contiguous True runs in a 1-D boolean array, as [start, stop) pairs."""
    padded = np.concatenate([[False], mask, [False]])
    edges = np.diff(padded.astype(np.int8))
    starts = np.flatnonzero(edges == 1)
    stops = np.flatnonzero(edges == -1)
    return [(int(a), int(b)) for a, b in zip(starts, stops) if b - a >= min_len]


def find_panel(rgb):
    """Bbox of the painted panel: largest non-black connected component.

    A dark thumbnail inside the panel is also near-black, but it is enclosed by
    the panel's light fill, so the panel is a single component and its bbox is
    unaffected.
    """
    painted = (rgb > BLACK_TOL).any(axis=2)
    if not painted.any():
        return None
    labels, n = cc_label(painted)
    if n == 0:
        return None
    sizes = np.bincount(labels.ravel())
    sizes[0] = 0
    ys, xs = np.where(labels == int(sizes.argmax()))
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def modal_colour(rgb):
    """Most common exact colour - the panel's solid fill."""
    flat = rgb.reshape(-1, 3).astype(np.uint32)
    keys = (flat[:, 0] << 16) | (flat[:, 1] << 8) | flat[:, 2]
    key = np.bincount(keys).argmax()
    return np.array([(key >> 16) & 255, (key >> 8) & 255, key & 255], dtype=np.int16)


def saturation(rgb):
    a = rgb.astype(np.int16)
    return a.max(axis=2) - a.min(axis=2)


def find_selection(panel_rgb, tiles, reach=12, sat_min=25):
    """Index of the selected tile, by accent-coloured focus ring.

    The ring is drawn OUTSIDE the tile - measured at ~10px out, #1d6978 on this
    machine, separated from the tile fill by a band of panel grey. Everything
    else outside a tile is panel fill, which is pure grey.

    So score each tile by the fraction of strongly saturated pixels strictly
    outside its bbox. Measured on capture 001: the selected tile scores 0.326
    and every other tile scores exactly 0.000.

    Sampling anywhere INSIDE the tile ruins this - a VS Code thumbnail scores
    0.119 and a RealFlight thumbnail 0.578 on saturation alone, which is what
    made earlier versions pick the wrong tile. Staying strictly outside makes
    thumbnail contamination structurally impossible rather than merely unlikely.
    """
    sat = saturation(panel_rgb)
    H, W = sat.shape
    scores = []
    for (x0, y0, x1, y1) in tiles:
        ax0, ay0 = max(0, x0 - reach), max(0, y0 - reach)
        ax1, ay1 = min(W, x1 + reach), min(H, y1 + reach)
        yy, xx = np.mgrid[ay0:ay1, ax0:ax1]
        # Signed distance inward from the tile rect; negative is outside it.
        dist = np.minimum.reduce([xx - x0, x1 - 1 - xx, yy - y0, y1 - 1 - yy])
        outside = sat[ay0:ay1, ax0:ax1][dist < 0]
        scores.append(float((outside > sat_min).mean()) if outside.size else 0.0)

    if not scores:
        return None, scores
    best = int(np.argmax(scores))
    runner_up = sorted(scores)[-2] if len(scores) > 1 else 0.0
    # Margins are enormous in practice (0.33 vs 0.00), so a strict test costs
    # nothing and reports None rather than guessing if the ring is ever absent.
    if scores[best] < 0.05 or scores[best] < runner_up * 4.0:
        return None, scores
    return best, scores


def analyse(slot=None, verbose=True, render_path=None, label=None):
    """Analyse one render.

    `render_path` bypasses the corpus so this can be pointed at the BMP that
    AltTabGrid.ahk dumps. Running both detectors over byte-identical input is
    the only way to tell an AHK porting bug apart from the two runs having seen
    different moments - the AHK version is a reimplementation, not a
    translation, because full-image density would take 2.4s in AHK.
    """
    render = Path(render_path) if render_path else (slot / "render_full.png")
    name = label or (render.name if render_path else slot.name)
    if not render.exists():
        print(f"{name}: no render at {render}")
        return None
    rgb = np.array(Image.open(render).convert("RGB"))

    panel = find_panel(rgb)
    if panel is None:
        print(f"{name}: render painted nothing")
        return None
    px0, py0, px1, py1 = panel
    prgb = rgb[py0:py1 + 1, px0:px1 + 1]

    bg = modal_colour(prgb)
    content = np.abs(prgb.astype(np.int16) - bg).max(axis=2) > BG_TOL

    row_density = content.mean(axis=1)
    bands = runs(row_density > ROW_MIN_DENSITY, ROW_MIN_PX)

    grid = []
    for (ya, yb) in bands:
        col_density = content[ya:yb].mean(axis=0)
        cols = runs(col_density > COL_MIN_DENSITY, COL_MIN_PX)
        if cols:
            grid.append([(a, ya, b, yb) for (a, b) in cols])

    flat = [t for row in grid for t in row]
    sel, scores = find_selection(prgb, flat)

    per_row = [len(r) for r in grid]
    sel_rc = None
    if sel is not None:
        i = sel
        for ri, row in enumerate(grid):
            if i < len(row):
                sel_rc = (ri, i)
                break
            i -= len(row)

    if verbose:
        meta = {}
        if slot and (slot / "meta.json").exists():
            meta = json.loads((slot / "meta.json").read_text())
        print(f"=== {name}  {meta.get('note') or '(no note)'} ===")
        if meta:
            print(f"  host rect  : {meta['window_rect']}")
        print(f"  panel rect : ({px0},{py0})-({px1},{py1})  "
              f"{px1-px0+1}x{py1-py0+1}")
        print(f"  panel bg   : #{bg[0]:02x}{bg[1]:02x}{bg[2]:02x}")
        print(f"  row bands  : {bands}")
        for ri, row in enumerate(grid):
            widths = [t[2] - t[0] for t in row]
            print(f"    row {ri}: {len(row)} tiles  widths={widths}")
        print(f"  accent scores: {[round(s, 1) for s in scores]}")
        print(f"  selection  : {sel_rc}")

        dbg = Image.fromarray(rgb).convert("RGB")
        d = ImageDraw.Draw(dbg)
        d.rectangle((px0, py0, px1, py1), outline=(255, 128, 0), width=2)
        for ri, row in enumerate(grid):
            for ci, (x0, y0, x1, y1) in enumerate(row):
                hit = sel_rc == (ri, ci)
                d.rectangle((x0 + px0, y0 + py0, x1 + px0, y1 + py0),
                            outline=(255, 0, 0) if hit else (0, 220, 0),
                            width=4 if hit else 2)
        dbg_path = render.parent / (render.stem + "-detected.png")
        dbg.save(dbg_path)
        print(f"  annotated  : {dbg_path}")

    print(f"GRID {name} rows={len(grid)} "
          f"perRow={','.join(map(str, per_row))} "
          f"total={sum(per_row)} sel={sel_rc}")
    return {"rows": len(grid), "per_row": per_row, "sel": sel_rc}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("slot", nargs="?", help="Capture dir (default: newest).")
    ap.add_argument("--all", action="store_true", help="Analyse every capture.")
    ap.add_argument("--render", help="Analyse a render file directly, e.g. the "
                                     "atg-render.bmp dumped by AltTabGrid.ahk.")
    args = ap.parse_args()

    if args.render:
        analyse(render_path=args.render)
        return

    slots = sorted(p for p in CORPUS.iterdir() if p.is_dir()) if CORPUS.exists() else []
    if not slots:
        print(f"No captures in {CORPUS}. Run Probe-Capture-AltTab.py first.")
        sys.exit(1)

    if args.all:
        for s in slots:
            analyse(s, verbose=False)
    else:
        analyse(Path(args.slot) if args.slot else slots[-1])


if __name__ == "__main__":
    main()
