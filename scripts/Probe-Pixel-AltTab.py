#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "Pillow",
#   "numpy",
#   "scipy",
# ]
# ///
"""
Pixel-based grid detection for the Win11 Alt+Tab switcher.

Captures the foreground window (expected to be XamlExplorerHostIslandWindow)
via PIL ImageGrab — a pure screen read that does not touch UIA/MSAA, so it
cannot poison the XAML alt-tab host the way the accessibility probes did.

The XamlExplorerHostIslandWindow is fullscreen on Win11. The grid panel
itself is opaque, but the surround between the panel and the screen edges
is transparent. On this hardware the panel ends up nearly fullscreen, so
in practice corner-pixel sampling lands on whatever is *visible at the
corner* — sometimes desktop, sometimes leakage. The two-stage algorithm
below tolerates both.

Algorithm:
  1. find_panel — sample the four screen corners; median = desktop
     reference. Pixels differing from desktop form a mask whose largest
     connected component bbox is the panel rect (often nearly the whole
     screen on this Win11 build).
  2. find_tile_blobs — inside the panel rect, sample panel-bg colour
     from a thin inset just inside the border (no tile reaches the
     panel edge). Mask pixels that differ from panel-bg, light closing
     to fill aliased-edge speckle, connected components → tile rects.
     `max_area_frac` drops the alt-tab UI chrome blob (rounded corners,
     inter-tile shading, drop-shadow ring all weld into one component
     with a panel-spanning bbox).
  3. Cluster tiles by cy → rows. Within each row, sort by cx.

All pixel processing is done on a 2× downsampled image, then rects are
scaled back. Tiles are hundreds of pixels wide; full resolution is
overkill.

MODES
  --demo     Open Alt+Tab ourselves after a 3s countdown, analyze, release Alt.
             Useful for end-to-end testing.
  (default)  Expect Alt+Tab to already be open in the foreground; analyze and
             exit. This is the production mode AHK will invoke.

USAGE (uv, recommended — reads inline deps above):
    uv run Probe-Pixel-AltTab.py --demo

The final stdout line is parseable:
    GRID rows=R perRow=A,B,... total=N
"""

import argparse
import ctypes
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageGrab
from scipy.ndimage import binary_closing, find_objects, label as cc_label


VK_MENU = 0x12
VK_TAB = 0x09
KEYEVENTF_KEYUP = 0x0002

ALT_TAB_CLASS = "XamlExplorerHostIslandWindow"

DOWNSAMPLE = 2


def make_dpi_aware():
    """Opt into per-monitor DPI awareness so GetWindowRect and ImageGrab
    agree on a coordinate system.

    Without this, on a non-100% display, GetWindowRect returns logical
    (DPI-scaled) coords while ImageGrab(all_screens=True) reads physical
    pixels. The mismatch crops the capture at the right/bottom on a
    fullscreen window like XamlExplorerHostIslandWindow.

    Tries Per-Monitor v2 → v1 → system-wide, in that order. Each call
    is a no-op once the process is already DPI-aware.
    """
    try:
        if ctypes.windll.user32.SetProcessDpiAwarenessContext(-4):
            return
    except (AttributeError, OSError):
        pass
    try:
        if ctypes.windll.shcore.SetProcessDpiAwareness(2) == 0:
            return
    except (AttributeError, OSError):
        pass
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except (AttributeError, OSError):
        pass


def alt_tab_press():
    user32 = ctypes.windll.user32
    user32.keybd_event(VK_MENU, 0, 0, 0)
    user32.keybd_event(VK_TAB, 0, 0, 0)
    user32.keybd_event(VK_TAB, 0, KEYEVENTF_KEYUP, 0)


def alt_release():
    ctypes.windll.user32.keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0)


def get_class_name(hwnd):
    buf = ctypes.create_unicode_buffer(256)
    ctypes.windll.user32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def get_window_rect(hwnd):
    rect = (ctypes.c_long * 4)()
    ctypes.windll.user32.GetWindowRect(hwnd, rect)
    return rect[0], rect[1], rect[2], rect[3]


def find_panel(rgb, corner_size=12, tol=20):
    """Locate the alt-tab panel bbox.

    Sample the four screen corners as the desktop reference (median across
    all four to be robust to one wonky corner). Mask = pixels that differ
    from desktop by more than `tol`. Largest connected component is the
    panel.

    Returns (x0, y0, x1, y1) inclusive, or None.
    """
    s = corner_size
    rgb_i = rgb.astype(np.int16)
    corners = np.concatenate([
        rgb_i[:s, :s].reshape(-1, 3),
        rgb_i[:s, -s:].reshape(-1, 3),
        rgb_i[-s:, :s].reshape(-1, 3),
        rgb_i[-s:, -s:].reshape(-1, 3),
    ])
    desktop = np.median(corners, axis=0)
    diff = np.sqrt(((rgb_i - desktop) ** 2).sum(axis=2))
    mask = diff > tol

    labels, n = cc_label(mask)
    if n == 0:
        return None
    sizes = np.bincount(labels.ravel())
    sizes[0] = 0
    panel_label = int(sizes.argmax())
    if sizes[panel_label] == 0:
        return None
    ys, xs = np.where(labels == panel_label)
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def find_tile_blobs(panel_rgb, border_inset=4, tol=22,
                    min_area_frac=0.005, max_area_frac=0.5,
                    min_aspect=0.6, max_aspect=3.0):
    """Find tile blobs inside the panel.

    Sample panel-bg colour from a thin inset just inside the panel border
    (no tile reaches the panel edge). Mask pixels that differ from it, then
    light 8-connected closing fills aliased-edge speckle inside tiles
    without bridging the inter-tile gaps.

    `max_area_frac` drops the alt-tab UI chrome blob: rounded panel corners,
    inter-tile shading, drop-shadow ring all connect into one component
    whose bbox spans nearly the whole panel. Real tiles are well under
    50% of panel area; the chrome blob is ~95%.
    """
    rgb_i = panel_rgb.astype(np.int16)
    H, W = rgb_i.shape[:2]
    s = border_inset
    border = np.concatenate([
        rgb_i[:s, :].reshape(-1, 3),
        rgb_i[-s:, :].reshape(-1, 3),
        rgb_i[:, :s].reshape(-1, 3),
        rgb_i[:, -s:].reshape(-1, 3),
    ])
    bg = np.median(border, axis=0)
    diff = np.sqrt(((rgb_i - bg) ** 2).sum(axis=2))
    mask = diff > tol
    mask = binary_closing(mask, structure=np.ones((3, 3)), iterations=2)

    labels, _n = cc_label(mask)
    bbs = find_objects(labels)

    panel_area = H * W
    min_area = max(500, int(panel_area * min_area_frac))
    max_area = int(panel_area * max_area_frac)
    blobs = []
    for i, sl in enumerate(bbs, start=1):
        if sl is None:
            continue
        sy, sx = sl
        y0, y1 = int(sy.start), int(sy.stop)
        x0, x1 = int(sx.start), int(sx.stop)
        area = int((labels[sl] == i).sum())
        if area < min_area or area > max_area:
            continue
        tw, th = x1 - x0, y1 - y0
        ar = tw / max(th, 1)
        if ar < min_aspect or ar > max_aspect:
            continue
        blobs.append({
            "x0": x0, "y0": y0, "x1": x1, "y1": y1,
            "w": tw, "h": th, "area": area,
        })
    return blobs, mask


def scale_blobs(blobs, scale, offset):
    """Translate panel-local blob rects to screen coords and undo downsample."""
    ox, oy = offset
    out = []
    for b in blobs:
        x0 = (b["x0"] + ox) * scale
        y0 = (b["y0"] + oy) * scale
        x1 = (b["x1"] + ox) * scale
        y1 = (b["y1"] + oy) * scale
        out.append({
            "x0": x0, "y0": y0, "x1": x1, "y1": y1,
            "cx": (x0 + x1) // 2, "cy": (y0 + y1) // 2,
            "w": x1 - x0, "h": y1 - y0,
            "area": b["area"] * scale * scale,
        })
    return out


def cluster_rows(tiles, tol_frac=0.5):
    """Group tiles into rows by cy similarity. Within each row, sort by cx."""
    if not tiles:
        return []
    median_h = sorted(t["h"] for t in tiles)[len(tiles) // 2]
    tol = tol_frac * median_h
    s = sorted(tiles, key=lambda t: t["cy"])
    rows = [[s[0]]]
    for t in s[1:]:
        if abs(t["cy"] - rows[-1][0]["cy"]) <= tol:
            rows[-1].append(t)
        else:
            rows.append([t])
    for row in rows:
        row.sort(key=lambda t: t["cx"])
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--demo", action="store_true",
                        help="Send Alt+Tab ourselves (3s countdown) before analysis.")
    parser.add_argument("--save", default="alttab_capture.png",
                        help="Path to save the annotated capture (empty to skip).")
    args = parser.parse_args()

    make_dpi_aware()

    if args.demo:
        print("Pressing Alt+Tab in 3s — focus a normal window, then wait.")
        time.sleep(3)
        alt_tab_press()
        # 400ms lets the XAML host finish its fade-in animation. Captures
        # taken sooner show partial alpha on tiles, which fragments the mask.
        time.sleep(0.4)

    hwnd = ctypes.windll.user32.GetForegroundWindow()
    cls = get_class_name(hwnd) if hwnd else ""
    if cls != ALT_TAB_CLASS:
        if args.demo:
            alt_release()
        print(f"Foreground is not the alt-tab switcher (class={cls!r}). "
              f"Expected {ALT_TAB_CLASS!r}.")
        sys.exit(1)

    left, top, right, bot = get_window_rect(hwnd)
    img = ImageGrab.grab(bbox=(left, top, right, bot), all_screens=True)
    if args.demo:
        alt_release()

    print(f"Window rect   : ({left},{top})-({right},{bot})")

    if DOWNSAMPLE > 1:
        small = img.resize((img.size[0] // DOWNSAMPLE,
                            img.size[1] // DOWNSAMPLE), Image.BILINEAR)
    else:
        small = img
    arr = np.array(small)
    if arr.shape[2] == 4:
        arr = arr[:, :, :3]

    panel = find_panel(arr)
    if panel is None:
        print("Could not locate alt-tab panel (no region differs from desktop).")
        sys.exit(2)
    px0, py0, px1, py1 = panel
    print(f"Panel rect    : ({px0 * DOWNSAMPLE},{py0 * DOWNSAMPLE})-"
          f"({px1 * DOWNSAMPLE},{py1 * DOWNSAMPLE})")

    panel_arr = arr[py0:py1 + 1, px0:px1 + 1]
    blobs, tile_mask = find_tile_blobs(panel_arr)
    tiles = scale_blobs(blobs, DOWNSAMPLE, (px0, py0))
    rows = cluster_rows(tiles)
    per_row = [len(r) for r in rows]
    total = sum(per_row)

    if args.save:
        Image.fromarray((tile_mask * 255).astype(np.uint8)).save(
            Path(__file__).parent / "alttab_panelmask.png")
        print(f"Saved mask    : alttab_panelmask.png")

        out = Path(__file__).parent / args.save
        dbg = img.copy()
        draw = ImageDraw.Draw(dbg)
        if tiles:
            pad = 8
            tx0 = min(t["x0"] for t in tiles) - pad
            ty0 = min(t["y0"] for t in tiles) - pad
            tx1 = max(t["x1"] for t in tiles) + pad
            ty1 = max(t["y1"] for t in tiles) + pad
            draw.rectangle((tx0, ty0, tx1 - 1, ty1 - 1),
                           outline=(255, 128, 0), width=2)
        row_colors = [(0, 255, 0), (0, 200, 255), (255, 200, 0),
                      (255, 0, 255), (0, 255, 255)]
        for ri, row in enumerate(rows):
            color = row_colors[ri % len(row_colors)]
            for t in row:
                draw.rectangle((t["x0"], t["y0"], t["x1"] - 1, t["y1"] - 1),
                               outline=color, width=3)
        dbg.save(out)
        print(f"Saved capture : {out.name} ({img.size[0]}x{img.size[1]})")

    print(f"Tiles         : {total}")
    print(f"Rows          : {len(rows)}")
    print(f"Per-row tiles : {per_row}")
    if rows:
        print("Tile rects (screen coords):")
        for ri, row in enumerate(rows):
            for ci, t in enumerate(row):
                print(f"  [{ri},{ci}]  ({t['x0']},{t['y0']})-({t['x1']},{t['y1']})  "
                      f"{t['w']}x{t['h']}")
    print("-" * 40)
    print(f"GRID rows={len(rows)} "
          f"perRow={','.join(map(str, per_row))} "
          f"total={total}")


if __name__ == "__main__":
    main()
