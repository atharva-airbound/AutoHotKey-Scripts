#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["Pillow", "numpy"]
# ///
"""Capture the Win11 Alt+Tab switcher for offline grid-detection work.

This script sends NO synthetic input. You open the switcher yourself and hold
Alt; it waits for the host window to appear, captures it, and exits. That
matters for two reasons:

  - Earlier probes drove Alt+Tab themselves. A crash between "Alt down" and the
    cleanup left Alt logically held, and every run stole focus mid-session.
  - Analysis needs a still desktop. Synthetic-input runs captured a live screen
    (terminals repainting, browsers re-rendering), which is why the before/after
    diff produced thousands of spurious changed regions.

Each run saves one numbered capture directory so detector changes can be
replayed against a fixed corpus instead of re-triggering the switcher:

    alttab-corpus/NNN/screen.png        ImageGrab of the host window rect
    alttab-corpus/NNN/render_full.png   PrintWindow + PW_RENDERFULLCONTENT
    alttab-corpus/NNN/render_plain.png  PrintWindow, no flags
    alttab-corpus/NNN/meta.json         rects, monitors, PrintWindow results

The render_*.png files are drawn into a bitmap pre-filled with a magenta
sentinel, so any pixel DWM does not paint stays magenta. If PrintWindow works
on this XAML host, "not sentinel" is an exact panel mask - no colour reference,
no threshold, and immune to whatever is on the desktop behind it.

USAGE
    uv run Probe-Capture-AltTab.py
    uv run Probe-Capture-AltTab.py --note "12 windows"

Then hold Alt+Tab until it prints "captured". Vary the window count between
runs; the layout reflows non-obviously (11 windows -> 6,5 but 12 -> 4,4,4), so
the corpus needs several different counts to be worth anything.
"""

import argparse
import ctypes
import json
import sys
import time
from ctypes import wintypes
from pathlib import Path

import numpy as np
from PIL import Image, ImageGrab

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

ALT_TAB_CLASS = "XamlExplorerHostIslandWindow"
PW_RENDERFULLCONTENT = 0x00000002
DIB_RGB_COLORS = 0
BI_RGB = 0

SENTINEL_BGRA = b"\xff\x00\xff\xff"          # magenta, opaque
SENTINEL_RGB = (255, 0, 255)

CORPUS = Path(__file__).parent / "alttab-corpus"


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG),
                ("biHeight", wintypes.LONG), ("biPlanes", wintypes.WORD),
                ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
                ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
                ("biClrImportant", wintypes.DWORD)]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wintypes.DWORD * 3)]


def _bind():
    """Declare argtypes/restypes for every GDI call used here.

    Without this, ctypes defaults handles to C int and a 64-bit HBITMAP raises
    "int too long to convert" on the next call that consumes it.
    """
    user32.GetDC.restype = wintypes.HDC
    user32.GetDC.argtypes = [wintypes.HWND]
    user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    user32.PrintWindow.restype = wintypes.BOOL
    user32.PrintWindow.argtypes = [wintypes.HWND, wintypes.HDC, wintypes.UINT]

    gdi32.CreateCompatibleDC.restype = wintypes.HDC
    gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
    gdi32.CreateDIBSection.restype = wintypes.HBITMAP
    gdi32.CreateDIBSection.argtypes = [wintypes.HDC, ctypes.POINTER(BITMAPINFO),
                                       wintypes.UINT, ctypes.POINTER(ctypes.c_void_p),
                                       wintypes.HANDLE, wintypes.DWORD]
    gdi32.SelectObject.restype = wintypes.HGDIOBJ
    gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
    gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
    gdi32.DeleteDC.argtypes = [wintypes.HDC]


def dpi_aware():
    """Per-monitor DPI awareness, so GetWindowRect and ImageGrab agree.

    Without it, on a scaled display GetWindowRect returns logical coords while
    ImageGrab reads physical pixels, and the capture is cropped.
    """
    for fn in (lambda: user32.SetProcessDpiAwarenessContext(-4),
               lambda: ctypes.windll.shcore.SetProcessDpiAwareness(2) == 0,
               lambda: user32.SetProcessDPIAware()):
        try:
            if fn():
                return
        except (AttributeError, OSError):
            pass


def get_class_name(hwnd):
    buf = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def enum_monitors():
    """Monitor rects, so the corpus records which display the switcher was on."""
    MONITORENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HANDLE,
                                         wintypes.HDC,
                                         ctypes.POINTER(wintypes.RECT),
                                         wintypes.LPARAM)
    out = []

    def cb(hmon, hdc, lprc, lparam):
        r = lprc.contents
        out.append([r.left, r.top, r.right, r.bottom])
        return True

    user32.EnumDisplayMonitors(None, None, MONITORENUMPROC(cb), 0)
    return out


def print_window(hwnd, w, h, flags):
    """Render hwnd into a top-down 32bpp DIB pre-filled with the sentinel.

    Returns (rgb array, PrintWindow return code).
    """
    screen_dc = user32.GetDC(None)
    mem_dc = gdi32.CreateCompatibleDC(screen_dc)

    bmi = BITMAPINFO()
    bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bmi.bmiHeader.biWidth = w
    bmi.bmiHeader.biHeight = -h              # negative => top-down rows
    bmi.bmiHeader.biPlanes = 1
    bmi.bmiHeader.biBitCount = 32
    bmi.bmiHeader.biCompression = BI_RGB

    bits = ctypes.c_void_p()
    hbmp = gdi32.CreateDIBSection(mem_dc, ctypes.byref(bmi), DIB_RGB_COLORS,
                                  ctypes.byref(bits), None, 0)
    if not hbmp:
        gdi32.DeleteDC(mem_dc)
        user32.ReleaseDC(None, screen_dc)
        raise ctypes.WinError(ctypes.get_last_error())

    try:
        nbytes = w * h * 4
        ctypes.memmove(bits, SENTINEL_BGRA * (w * h), nbytes)

        old = gdi32.SelectObject(mem_dc, hbmp)
        rc = int(user32.PrintWindow(hwnd, mem_dc, flags))
        gdi32.GdiFlush()

        raw = (ctypes.c_ubyte * nbytes).from_address(bits.value)
        arr = np.frombuffer(bytes(raw), dtype=np.uint8).reshape(h, w, 4)
        rgb = arr[:, :, [2, 1, 0]].copy()    # BGRA -> RGB
        gdi32.SelectObject(mem_dc, old)
    finally:
        gdi32.DeleteObject(hbmp)
        gdi32.DeleteDC(mem_dc)
        user32.ReleaseDC(None, screen_dc)
    return rgb, rc


def painted_bbox(rgb):
    """Bbox of pixels PrintWindow actually painted, or None if it painted none."""
    painted = (rgb != np.array(SENTINEL_RGB, dtype=np.uint8)).any(axis=2)
    if not painted.any():
        return None, 0.0
    ys, xs = np.where(painted)
    return ([int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())],
            float(painted.mean()))


def wait_for_switcher(timeout):
    """Poll the foreground window until the switcher shows up."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        hwnd = user32.GetForegroundWindow()
        if hwnd and get_class_name(hwnd) == ALT_TAB_CLASS:
            return hwnd
        time.sleep(0.05)
    return None


def next_slot():
    CORPUS.mkdir(parents=True, exist_ok=True)
    existing = [int(p.name) for p in CORPUS.iterdir()
                if p.is_dir() and p.name.isdigit()]
    slot = CORPUS / f"{max(existing, default=0) + 1:03d}"
    slot.mkdir()
    return slot


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=float, default=30.0,
                    help="Seconds to wait for the switcher (default 30).")
    ap.add_argument("--settle", type=float, default=0.35,
                    help="Delay after it appears, for the fade-in (default 0.35).")
    ap.add_argument("--note", default="",
                    help="Free-text note stored in meta.json, e.g. '12 windows'.")
    args = ap.parse_args()

    _bind()
    dpi_aware()

    print(f"Hold Alt+Tab now - waiting up to {args.timeout:.0f}s for the switcher.")
    hwnd = wait_for_switcher(args.timeout)
    if hwnd is None:
        print("Timed out; the switcher never became foreground.")
        sys.exit(1)

    # The XAML host fades in. Capturing sooner catches partial alpha on the
    # tiles, which fragments any mask built from it.
    time.sleep(args.settle)

    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    box = (rect.left, rect.top, rect.right, rect.bottom)
    w, h = rect.right - rect.left, rect.bottom - rect.top

    screen = np.array(ImageGrab.grab(bbox=box, all_screens=True))[:, :, :3]

    renders = {}
    for name, flags in (("full", PW_RENDERFULLCONTENT), ("plain", 0)):
        try:
            rgb, rc = print_window(hwnd, w, h, flags)
        except OSError as e:
            renders[name] = {"error": str(e)}
            continue
        bbox, frac = painted_bbox(rgb)
        renders[name] = {"rc": rc, "painted_bbox": bbox, "painted_frac": frac,
                         "image": rgb}

    slot = next_slot()
    Image.fromarray(screen).save(slot / "screen.png")
    for name, info in renders.items():
        img = info.pop("image", None)
        if img is not None:
            Image.fromarray(img).save(slot / f"render_{name}.png")

    meta = {
        "note": args.note,
        "window_rect": list(box),
        "window_size": [w, h],
        "monitors": enum_monitors(),
        "virtual_screen": [
            user32.GetSystemMetrics(76), user32.GetSystemMetrics(77),
            user32.GetSystemMetrics(78), user32.GetSystemMetrics(79)],
        "renders": renders,
    }
    (slot / "meta.json").write_text(json.dumps(meta, indent=2))

    print(f"captured -> {slot.relative_to(Path(__file__).parent)}  ({w}x{h})")
    print(f"  host rect : {box}")
    print(f"  monitors  : {meta['monitors']}")
    for name, info in renders.items():
        if "error" in info:
            print(f"  render {name:<5}: FAILED {info['error']}")
        elif info["painted_bbox"] is None:
            print(f"  render {name:<5}: rc={info['rc']} painted nothing "
                  f"(fully transparent)")
        else:
            b = info["painted_bbox"]
            print(f"  render {name:<5}: rc={info['rc']} "
                  f"painted {info['painted_frac']:.1%} bbox={b} "
                  f"{b[2]-b[0]+1}x{b[3]-b[1]+1}")
    print("\nYou can release Alt now.")


if __name__ == "__main__":
    main()
