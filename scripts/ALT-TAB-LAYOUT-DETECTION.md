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

**Window count does not determine the layout at all.** Tile width tracks each window's thumbnail aspect ratio — one measured row is `[367, 273, 363, 365]` px — so the switcher is packing *variable-width* tiles into rows. The layout is a function of the set of window aspect ratios, not of how many windows there are. The same count of windows produces different layouts depending on the sizes of those windows.

This rules out caching as well as computing. An empirical `count → layout` table learned at runtime is just as wrong as a formula, because the key is not the count. The layout has to be **read at runtime, every time**, which puts a hard latency budget on detection: it must complete before the user's first arrow key, roughly 100–200ms after the gesture starts.

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

(This is why the working approach is a DWM render rather than anything that queries the switcher: `PrintWindow` asks DWM to redraw pixels and never opens a provider connection.)

### 3. MSAA (Microsoft Active Accessibility)
Probe: `Probe-MSAA-AltTab.ahk`. Two flavors tried:

- **Raw vtable calls via `ComCall`** — crashed at `get_accRole` (vtable index 13) with "Invalid memory read/write".
- **IDispatch via `ComObjFromPtr`** — crashed inside `ComObjFromPtr` itself (which presumably calls QueryInterface on the pointer).

In both, `AccessibleObjectFromWindow` returns S_OK with a non-null pointer, but the pointer crashes on first real use. On Win11, XAML controls expose UIA natively and `oleacc` bridges them to provide MSAA — so MSAA goes through the same fragile provider. Same fundamental dead end as UIA.

### 4. Pixel detection from a screen grab
Probe: `Probe-Pixel-AltTab.py`. Screenshot the switcher, guess which pixels are panel by comparing against a "desktop reference" sampled from the four screen corners, then label connected components and filter them by area and aspect ratio.

Pixel reads don't go through any accessibility provider, so this cannot poison the switcher — that part held up. The analysis did not.

**Result: unreliable, for two structural reasons.**

- **The desktop reference is unsound.** It samples the four *screen* corners, which on a dual-monitor setup straddles two different desktops. On the machine this was developed on the virtual screen is 3840×1367 across monitors at `[-1920,-287,0,793]` and `[0,0,1920,1080]`, and the switcher renders on whichever monitor has focus. One observed run returned a panel rect of `(28,94)-(1652,1018)` — not the panel. Every threshold downstream then samples "panel background" from desktop pixels.
- **Connected components cannot reject the chrome ring.** The panel's rounded corners, inter-tile shading and drop-shadow weld into one component that has *small area* but a *panel-spanning bbox*, so neither an area filter nor an aspect filter excludes it. Observed: a 1494×656 "tile" that split a 2-row grid into rows 0 and 2, reporting `rows=3 perRow=4,1,4` for what was really `4,4`.

Also tried and rejected: **before/after diffing** the screen across the switcher opening, to isolate the panel as "what changed". On a live desktop it produced 3608 changed components — terminals repainting and browsers re-rendering are indistinguishable from the panel appearing.

## What Works: PrintWindow

`PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)` asks DWM to redraw *only* the host window into a bitmap we own. It is a GDI/DWM path, so like a screen grab it never touches a UIA or MSAA provider and cannot poison the switcher.

Render into a bitmap pre-filled with a magenta sentinel. DWM leaves premultiplied black everywhere it paints nothing, so the panel is isolated on black with **no desktop content behind it at all**. Panel vs not-panel becomes exact — no colour reference, no threshold, and nothing on the desktop can influence it.

Note that `PrintWindow` reports painting 100% of the fullscreen host: it writes black rather than leaving the sentinel. "Not black" is the mask, not "not sentinel".

### Layout model — do not assume a fixed pitch

The render shows two things that break any pitch-based or grid-arithmetic approach:

- **Tile width varies per window**, tracking thumbnail aspect ratio. One measured row: `[367, 273, 363, 365]`. Only row *height* is uniform.
- **The last row is centred**, not left-aligned.

So tiles have to be found as runs, per row, rather than derived from a pitch. Panel fill is `#f3f3f3` and tile fill is white — only 12 levels apart, which puts a hard ceiling on the background tolerance. At `tol=14` the white body of a tile reads as background and runs collapse onto the dark parts of each thumbnail; widths came out as `[235, 270, 131, 360]` for the row above. `tol=6` sits below the 12-level gap and above the tile drop shadow.

### Finding the selection

The focus ring is drawn **outside** the tile — measured ~10px out, `#1d6978` on this machine, with a band of panel grey between ring and tile fill:

```
selected  : 1d6978 1d6978 b1cacf fbfbfb f7f7f7 f3f3f3 ...
unselected: f3f3f3 f3f3f3 f3f3f3 f3f3f3 f3f3f3 f3f3f3 ...
```

Score each tile by the fraction of strongly saturated pixels **strictly outside** its bbox. Everything outside a tile is panel fill, which is pure grey, so the selected tile scores 0.326 and every other tile scores exactly 0.000.

Sampling anywhere *inside* the tile destroys this — thumbnails are saturated (a VS Code thumbnail scores 0.119, a RealFlight one 0.578), and early versions picked the wrong tile because of it. Staying strictly outside makes thumbnail contamination structurally impossible rather than merely unlikely.

## Porting to AHK

The Python detector is the reference; `AltTabGrid.ahk` is the one that runs. It is a reimplementation, not a translation, because `NumGet` costs ~1.5us and the sample count is the whole performance story:

| strategy | samples | time |
|----------|---------|------|
| line sampling | ~11.7k | 18 ms |
| stride-4 grid | ~95k | 125 ms |
| every pixel (what Python does) | ~1.5M | 2438 ms |

Two things the port got wrong, both worth remembering because neither shows up in the corpus:

- **Sampling a few scanlines per band is not enough.** Windows' light-theme window chrome is `#f3f3f3` — the *same* colour as the panel fill — so a flat region of a light-themed thumbnail is locally indistinguishable from background. Three scanlines all voted "background" and a whole tile vanished, leaving a 442px "gap" in a row whose real gaps are ~30px. Fix: a column counts as a gap only if it is background down the *entire* band height. Early exit keeps this cheap, since tile columns hit content immediately and only real gap columns pay the full scan.
- **A fixed outward reach for the focus ring overruns the gap.** Gaps measure 20-36px, so searching 22px either side reads into the neighbouring tile and scores its thumbnail as a ring. Fix: clamp the reach to the actual gap, and score every tile and take the best rather than the first hit.
- **Sampling the panel fill from one pixel is not safe.** Taking it a few px below the panel top at mid-width looked reliable and is not: it landed on `#FBFBFB`, a lighter highlight along the panel's top edge, instead of the `#F3F3F3` fill. The real fill then differs from "background" by 8, over `ATG_BG_TOL`, so the *entire panel* reads as content and collapses to one band and one tile. This surfaced as `sel=(-1,-1)` but was really total detection failure producing a silently wrong layout. Fix: modal colour over a sparse grid (~2200 samples, ~3ms); the fill won 645 of 2211 on a dense `4,4,3` layout.
- **The ring is visible to a tile's neighbours.** It sits in the gap *between* tiles, so the tiles either side of the selection score on it too — 46 and 91 saturation were measured on neighbours. Summing both sides gave the selection 6 against a neighbour's 3, clearing a 2x margin by exactly zero. Fix: score each side separately and take the **minimum**. Only the selected tile is ringed on both sides, so the minimum is ~3 for it and 0 for everyone else.

`AltTabGrid.ahk` dumps its raw render with `ATG_DumpBMP`, and `Probe-Grid-AltTab.py --render <bmp>` analyses it. Running both detectors over byte-identical input is the only way to tell a porting bug from the two runs having seen different moments. Verified agreeing: both report `rows=2 perRow=4,4` and the same selected tile, panel rects within 2px, tile widths within ~7px (the port's 4px x-stride).

## Timing, and why arrows are held

`PrintWindow` costs 90-170ms and there is no cheaper option — plain `PrintWindow` with no flags renders the window entirely black, so `PW_RENDERFULLCONTENT` is mandatory. That is a hard floor, and the first arrow would otherwise fire 100-200ms in.

**There is no fade-in to wait for.** The first implementation waited a guessed 200ms for the panel to finish animating. `Probe-Timing-AltTab.ahk` hammers detection from the instant the switcher window exists and shows that unnecessary:

```
t+ms  centre   detect  took  result
   0  F3F3F3     ok     125  rows=2 perRow=5,4
   0  F5F6F7     ok     172  rows=3 perRow=5,5,4
```

Detection is already correct at `t+0`, with the panel background settled at `#f3f3f3` on the very first sample — the fade completes before the window becomes findable by `WinExist`. That 200ms was pure added latency on every gesture, and the hold is perceptible.

So the first render is attempted immediately, and `E_retryMs` is a *retry* delay rather than an upfront settle: still correct if a cold invocation is ever findable before it is painted (rendering mid-fade returns a part-transparent panel whose tile contrast is too low to scan), but free in the common case.

So `MouseXB1-WindowSwipe.ahk` accumulates motion from t=0 but **queues arrows** until the grid lands, then replays them through the clamp. Firing blind during that window would let the wrapping bug through, just more rarely. Holding also means nothing has been sent when detection completes, so the selection is still where Alt+Tab put it — giving a known-correct starting cell if the focus-ring read ever fails, instead of a guess.

## File Map

| File                          | Status            |
|-------------------------------|-------------------|
| `Probe-GetAltTabInfo.ahk`     | Confirmed: returns 0 on this Win11 build |
| `Probe-UIA-AltTab.ahk`        | Confirmed: poisons switcher after one use |
| `Probe-MSAA-AltTab.ahk`       | Confirmed: crashes on first real call |
| `Probe-Pixel-AltTab.py`       | Superseded: screen-grab analysis, unreliable (see above) |
| `Probe-Capture-AltTab.py`     | Builds the offline capture corpus. Sends no input |
| `Probe-Grid-AltTab.py`        | Reference detector. `--render` analyses an AHK BMP dump |
| `Probe-Timing-AltTab.ahk`     | Measures how soon the switcher is renderable |
| `Probe-Trace-AltTab.ahk`      | Traces selection while you drive; tests the vertical rule |
| `AltTabGrid.ahk`              | Production detector + `AltTabStep` navigation model |
| `MouseXB1-WindowSwipe.ahk`    | Gesture script, now edge-clamped |

## Navigation, as observed

Traced with `Probe-Trace-AltTab.ahk`, which watches the arrow keys with `~` hotkeys so a transition is only used as evidence when exactly one key preceded it. Inferring the direction from the result does not work: on a `4,4,3` layout, `(1,1) -> (3,3)` is `Left` wrapping backwards to the last tile in the grid, not a `Down`.

- **Horizontal wraps in both directions**, row-major, and around the ends of the grid. `Right` at the end of a row goes to the start of the next; `Left` at `(1,1)` goes to the last tile of the last row.
- **`Down` on the last row wraps to the first row.** `AltTabStep` deliberately suppresses this, as it suppresses horizontal wrap — and because suppression means not sending the key at all, the model cannot drift from reality here.
- **Vertical moves land on the nearest tile by x-centre.** Fits 7 of 9 clean single-key transitions, and wins the one case where the two candidate rules disagree: `(2,2) Down -> col 1`, where preserving the column index would have given 2.

Caveat worth keeping: the two misses are both `(2,3) Down`, where the candidates are 190px and 184px from the source centre. A 6px margin, measured on tile bounds quantised to a 4px stride and derived from *content* extents rather than true tile rects — inside measurement error, not a clean refutation. If vertical moves are ever seen to drift, this is the first thing to re-measure, against true tile rects.

## Open

- **Only light theme has been exercised.** The `#f3f3f3` / white pair and the `BG_TOL` ceiling of 12 levels are light-theme values. The tolerance is derived from a sampled background rather than hardcoded, so it may just work, but that is untested.
- **Corpus is one capture**, and every live test so far landed on the primary monitor. More captures across window counts and both monitors would catch layout cases neither detector has seen.

### A note on method

Four separate bugs here were caused by reasoning about the pixels instead of reading them: the panel-fill sample point, the ring reach, the scanline count, and the direction inference. Each looked obviously correct and each was wrong in a way a single measurement would have caught immediately. Both probes exist to make measuring cheaper than guessing — `Probe-Grid-AltTab.py --render` replays a dumped frame offline, and `ATG_DumpBMP` produces one from the live gesture.
- **Only light theme has been exercised.** The `#f3f3f3` / white pair and the `BG_TOL` ceiling of 12 levels are light-theme values; dark theme needs its own measurement. The tolerance is derived from a sampled background rather than hardcoded, so it may just work, but that is untested.
- **Corpus is one capture.** More captures across window counts and both monitors would catch layout cases neither detector has seen.

### On driving the switcher from a probe

`Probe-Capture-AltTab.py` deliberately sends no synthetic input; you hold Alt+Tab and it captures what it finds. Earlier probes pressed Alt+Tab themselves, which caused two problems worth not repeating: a crash between "Alt down" and the cleanup line left Alt logically held, and every run stole focus mid-session. Analysis also wants a still desktop, which a self-driven run cannot guarantee.

Captures land in `alttab-corpus/NNN/` (gitignored — they are full screenshots of whatever was on screen). Detector changes get replayed against the corpus with `Probe-Grid-AltTab.py --all` instead of re-triggering the switcher.
