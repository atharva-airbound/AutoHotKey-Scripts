#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "uiautomation",
#   "comtypes",
# ]
# ///
"""
Python UIA probe for the Win11 Alt+Tab switcher.

Tests whether a Python client (uiautomation lib, MTA, cache requests) gets
different results than AHK's UIA-v2, which poisoned the XAML alt-tab host
after a single FindAll. Hypotheses being tested:

  1. AHK was running UIA from STA. UIA recommends MTA. Maybe the apartment
     change matters.
  2. Cache requests bundle property fetches into one cross-process call,
     reducing the number of provider touches. Maybe touch *count* (not the
     mere fact of touching) is what poisons the host.

USAGE (uv, recommended — reads inline deps above):
    uv run Probe-UIA-Python.py

USAGE (pip):
    pip install uiautomation comtypes
    python Probe-UIA-Python.py

The script counts down 3 seconds, then sends Alt+Tab and probes the switcher.
Run it twice in a row (within the same explorer.exe lifetime) to test if the
second invocation degrades the way AHK's did.
"""

import ctypes
import sys
import time

# comtypes initializes COM at import time using sys.coinit_flags. Default is
# STA (COINIT_APARTMENTTHREADED = 2). Set MTA (COINIT_MULTITHREADED = 0) here
# *before* uiautomation imports comtypes — UIA's canonical guidance is MTA
# for clients, and AHK was doing STA.
sys.coinit_flags = 0  # COINIT_MULTITHREADED

import uiautomation as auto  # noqa: E402


VK_MENU = 0x12
VK_TAB = 0x09
KEYEVENTF_KEYUP = 0x0002


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


def cluster_by_cy(rects, tolerance=30):
    rects.sort(key=lambda r: r["cy"])
    rows = [[rects[0]]]
    for r in rects[1:]:
        if abs(r["cy"] - rows[-1][0]["cy"]) <= tolerance:
            rows[-1].append(r)
        else:
            rows.append([r])
    return rows


def find_tiles(ctrl):
    """Recursive GetChildren walk, collecting ListItemControl elements only.

    This is the same shape of work as the AHK probe — many cross-process
    touches via GetChildren — so if Python+MTA still poisons the host on
    second invocation, we know touch count isn't the issue and the apartment
    isn't either.
    """
    tiles = []

    def walk(node, depth, max_depth=5):
        if depth > max_depth:
            return
        try:
            children = node.GetChildren()
        except Exception:
            return
        for c in children:
            try:
                if c.ControlTypeName == "ListItemControl":
                    b = c.BoundingRectangle
                    tiles.append({
                        "name": c.Name or "",
                        "l": b.left, "t": b.top, "r": b.right, "b": b.bottom,
                        "cx": (b.left + b.right) // 2,
                        "cy": (b.top + b.bottom) // 2,
                    })
                    # ListItems hold a Close button etc. as children — no
                    # need to descend into them.
                    continue
                walk(c, depth + 1, max_depth)
            except Exception:
                pass

    walk(ctrl, 0)
    return tiles


def main():
    print("Pressing Alt+Tab in 3s — focus a normal window, then wait.")
    time.sleep(3)

    alt_tab_press()
    time.sleep(0.5)

    hwnd = ctypes.windll.user32.GetForegroundWindow()
    if not hwnd:
        alt_release()
        print("No foreground window detected.")
        return

    cls = get_class_name(hwnd)
    print(f"Foreground HWND : {hwnd}")
    print(f"Class           : {cls}")

    try:
        ctrl = auto.ControlFromHandle(hwnd)
    except Exception as e:
        alt_release()
        print(f"ControlFromHandle failed: {e}")
        return

    if ctrl is None:
        alt_release()
        print("ControlFromHandle returned None.")
        return

    tiles = find_tiles(ctrl)

    alt_release()

    print(f"Total tiles     : {len(tiles)}")

    if not tiles:
        return

    rows = cluster_by_cy(tiles)
    max_cols = max(len(r) for r in rows)
    print(f"Rows            : {len(rows)}")
    print(f"Max cols        : {max_cols}")
    print("-" * 32)
    for i, r in enumerate(rows):
        print(f"  Row {i}: {len(r)} tile(s)  (y≈{r[0]['cy']})")
    print("-" * 32)
    print("First few names:")
    for r in tiles[:6]:
        print(f"  - {r['name']!r}")


if __name__ == "__main__":
    main()
