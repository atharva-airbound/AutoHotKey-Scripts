# Alt+Tab Grid Layout Detection

## Why We Need It

`MouseXB1-WindowSwipe.ahk` implements a touchpad-style window-switcher gesture: the lower side button opens Alt+Tab, mouse motion translates into arrow keys to navigate the switcher grid, releasing the button commits.

The script currently has no concept of where the grid edges are. Swiping past the rightmost tile rolls over to the next row, so continuous horizontal mouse motion produces vertical jumps in selection. To fix this we need, at gesture start:

- Number of rows
- Tiles per row (last row may be partial)
- Ideally: the row/col of the currently selected tile

With that, the gesture script can clamp arrow output at edges instead of letting the switcher wrap.

## Why Window-Count-Based Assumptions Don't Work

The Win11 Alt+Tab grid reflows non-trivially when window count changes. Observed on this machine:

| Windows | Layout      |
|---------|-------------|
| 11      | (6, 5)      |
| 12      | (4, 4, 4)   |

Adding one window changed both row count and column count. The layout algorithm appears to target a near-square grid (adjusted for tile aspect ratio), so any static `cols = N` is wrong much of the time. Reverse-engineering Microsoft's exact formula is possible but fragile — it would break on any Win11 update that retunes it.

So the layout has to be **read at runtime**, not computed.

## Approaches Tried

### 1. `GetAltTabInfo` (user32)
Probe: `Probe-GetAltTabInfo.ahk`. Single DllCall returning an `ALTTABINFO` struct (cItems, cColumns, cRows, iColFocus, iRowFocus). The dream API.

**Result: returns 0.** The API was designed for the classic (pre-Win10) Alt+Tab window (`#32771`); it isn't wired up to Win11's `XamlExplorerHostIslandWindow`.

### 2. UIA (UI Automation)
Probe: `Probe-UIA-AltTab.ahk`. Uses Descolada's UIA-v2 to walk the switcher's automation tree and find tile-like elements.

**Result: works exactly once per host lifetime, then breaks the switcher.** Subsequent F8 presses return 1 tile. Restarting the AHK script does not fix it — the corruption lives on the host's side, not in our process. Killing `explorer.exe` restores it for exactly one more invocation.

Things that did **not** fix it:
- Removing the recursive `DumpTree` (suspected of being the heavy/recursive call that broke things). Even a single `FindAll({Type: "ListItem"})` poisons subsequent invocations.

So even one UIA touch is fatal for the next gesture.

### 3. MSAA (Microsoft Active Accessibility)
Probe: `Probe-MSAA-AltTab.ahk`. Two flavors tried:

- **Raw vtable calls via `ComCall`** — crashed at `get_accRole` (vtable index 13) with "Invalid memory read/write".
- **IDispatch via `ComObjFromPtr`** — crashed inside `ComObjFromPtr` itself (which presumably calls QueryInterface on the pointer).

In both, `AccessibleObjectFromWindow` returns S_OK with a non-null pointer, but the pointer crashes on first real use. On Win11, XAML controls expose UIA natively and `oleacc` bridges them to provide MSAA — so MSAA goes through the same fragile provider. Same fundamental dead end as UIA.

## What We're Implementing Next: Pixel Detection

Capture the alt-tab window's pixels once at gesture start (after `{Alt Down}{Tab}` plus a settle delay) and derive the grid by image analysis. Pixel reads don't go through any accessibility provider, so they cannot poison the switcher.

Two candidate strategies:

1. **Color-transition scan.** Sample the gap-background color (e.g., a pixel near the window edge), then walk horizontal lines across the switcher counting `gap → tile → gap` transitions to derive tiles-per-row. Repeat with vertical lines for rows. Theme-agnostic because the gap color is sampled live.
2. **Selection-highlight anchoring.** Find the accent-colored border of the currently-selected tile, use it to anchor tile width/height, then probe at fixed strides to map the rest of the grid. Bonus: gives us the current selection's (row, col) for free.

Approximate cost: 50–150ms, once, at gesture start. After that the gesture script clamps arrow keys against the cached `(rows, perRowCounts, currentRow, currentCol)` with zero per-poll overhead.

Starting with strategy 1 (transition scan); strategy 2 is a fallback if transition detection turns out to be ambiguous.

## File Map

| File                          | Status            |
|-------------------------------|-------------------|
| `Probe-GetAltTabInfo.ahk`     | Confirmed: returns 0 on this Win11 build |
| `Probe-UIA-AltTab.ahk`        | Confirmed: poisons switcher after one use |
| `Probe-MSAA-AltTab.ahk`       | Confirmed: crashes on first real call |
| `MouseXB1-WindowSwipe.ahk`    | Production gesture script — needs edge-clamping |
| (next) `Probe-Pixel-AltTab.ahk` | TBD: pixel-based grid detection |
