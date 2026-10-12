#Requires AutoHotkey v2.0

; Read the Win11 Alt+Tab grid layout at runtime.
;
; MouseXB1-WindowSwipe.ahk needs to know where the grid edges are so it can stop
; a horizontal swipe from wrapping onto the next row. The layout cannot be
; computed or cached: tile WIDTH tracks each window's thumbnail aspect ratio, so
; the switcher packs variable-width tiles into rows and the layout depends on the
; set of open window sizes, not on how many windows there are. It has to be read
; fresh every gesture. See ALT-TAB-LAYOUT-DETECTION.md for the approaches that
; failed first (GetAltTabInfo, UIA, MSAA, screen-grab pixel analysis).
;
; HOW
;   PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT) asks DWM to redraw only the
;   switcher into a bitmap we own. Everything it does not paint comes back
;   black, so the panel is isolated with no desktop content behind it and no
;   colour reference or threshold needed to find it. Being a GDI/DWM path it
;   never opens an accessibility provider, so unlike the UIA and MSAA probes it
;   cannot poison the switcher for the next invocation.
;
; WHY LINE SAMPLING
;   AHK's NumGet costs ~1.5us, so the sample count is the entire performance
;   story. Measured on this machine over a 1455x1044 window:
;       ~11.7k samples (line sampling)  18 ms
;       ~95k   samples (stride-4 grid) 125 ms
;       ~1.5M  samples (every pixel)  2438 ms
;   With PrintWindow itself at ~31ms, only line sampling fits the budget: the
;   first arrow key fires roughly 100-200ms after the gesture starts. So this
;   finds row bands with a few vertical scans, then tile runs with a few
;   horizontal scans per band, rather than building a full-image density map the
;   way the Python reference detector does.

; Panel fill is #f3f3f3 and tile fill is white - only 12 levels apart. A
; tolerance at or above that makes the body of a tile read as background and
; tile runs collapse onto the dark parts of each thumbnail. Stay below 12, and
; above the tile drop shadow which is a couple of levels off the panel fill.
ATG_BG_TOL := 6
ATG_BLACK_TOL := 8      ; channel value at or below this counts as unpainted
ATG_SAT_MIN := 25       ; saturation marking the accent-coloured focus ring
ATG_MIN_ROW_PX := 40    ; ignore row bands thinner than a plausible tile
ATG_MIN_TILE_PX := 60

; Column scan resolution. A column counts as a gap only if it is background for
; the WHOLE band height, which costs a full y-scan per gap column but exits on
; the first hit for tile columns - and tile columns are the large majority, so
; the average cost stays near one sample per column.
ATG_TILE_XSTEP := 4     ; gaps are 20-40px wide, so 4 resolves them comfortably
ATG_TILE_YSTEP := 6

; Stride for sampling the panel fill colour. ~2200 samples over a full-size
; panel, about 3ms, and the fill wins the vote by a wide margin (645 of 2211
; on a dense 4,4,3 layout).
ATG_BG_SAMPLE_STEP := 24

ATG_CLASS := "XamlExplorerHostIslandWindow"

; ─── Pixel access ─────────────────────────────────────────────────────
; A 32bpp BI_RGB DIB stores bytes B,G,R,A, so a little-endian UInt read is
; 0xAARRGGBB and masking off alpha leaves 0xRRGGBB.

ATG_Pixel(pBits, stride, x, y) {
    return NumGet(pBits, y * stride + x * 4, "UInt") & 0xFFFFFF
}

ATG_Differs(rgb, bg, tol) {
    dr := Abs(((rgb >> 16) & 0xFF) - ((bg >> 16) & 0xFF))
    dg := Abs(((rgb >> 8) & 0xFF) - ((bg >> 8) & 0xFF))
    db := Abs((rgb & 0xFF) - (bg & 0xFF))
    return (dr > tol || dg > tol || db > tol)
}

ATG_Saturation(rgb) {
    r := (rgb >> 16) & 0xFF, g := (rgb >> 8) & 0xFF, b := rgb & 0xFF
    return Max(r, g, b) - Min(r, g, b)
}

; Write the DIB out as a 32bpp BMP. biHeight is negative to keep the top-down
; row order the DIB already uses, which PIL reads correctly.
ATG_DumpBMP(pBits, w, h, path) {
    imgSize := w * h * 4
    hdr := Buffer(54, 0)
    NumPut("UShort", 0x4D42, hdr, 0)          ; "BM"
    NumPut("UInt", 54 + imgSize, hdr, 2)
    NumPut("UInt", 54, hdr, 10)               ; offset to pixel data
    NumPut("UInt", 40, hdr, 14)
    NumPut("Int", w, hdr, 18)
    NumPut("Int", -h, hdr, 22)
    NumPut("UShort", 1, hdr, 26)
    NumPut("UShort", 32, hdr, 28)
    NumPut("UInt", 0, hdr, 30)                ; BI_RGB
    NumPut("UInt", imgSize, hdr, 34)

    try FileDelete path
    f := FileOpen(path, "w")
    if (!f)
        return
    f.RawWrite(hdr, 54)
    f.RawWrite(pBits, imgSize)
    f.Close()
}

; Most frequent colour on a sparse grid over the given rect - the panel fill.
; Votes are pooled across near-identical shades: the acrylic panel (transparency
; on) is noisy, #5b5b5b-#606060, and split that way it lost the exact-colour
; vote to the white of the thumbnails, collapsing the grid to one tile.
ATG_ModalColour(pBits, stride, x0, y0, x1, y1, step) {
    global ATG_BG_TOL
    counts := Map()
    y := y0
    while (y <= y1) {
        x := x0
        while (x <= x1) {
            c := ATG_Pixel(pBits, stride, x, y)
            counts[c] := counts.Has(c) ? counts[c] + 1 : 1
            x += step
        }
        y += step
    }
    best := 0, bestColour := 0
    for c, n in counts {
        if (n * 20 < best)
            continue                ; can't win; skips the long tail cheaply
        score := 0
        for d, m in counts
            if !ATG_Differs(d, c, ATG_BG_TOL // 2)
                score += m
        if (score > best)
            best := score, bestColour := c
    }
    return bestColour
}

; True if any pixel in [xa, xb] at row y carries the accent ring's saturation.
ATG_RingNear(pBits, stride, w, xa, xb, y) {
    global ATG_SAT_MIN
    x := Max(0, xa), xb := Min(w - 1, xb)
    while (x <= xb) {
        if (ATG_Saturation(ATG_Pixel(pBits, stride, x, y)) > ATG_SAT_MIN)
            return true
        x += 1
    }
    return false
}

ATG_IsPainted(rgb) {
    global ATG_BLACK_TOL
    return (((rgb >> 16) & 0xFF) > ATG_BLACK_TOL
         || ((rgb >> 8) & 0xFF) > ATG_BLACK_TOL
         || (rgb & 0xFF) > ATG_BLACK_TOL)
}

; Contiguous runs of true values in a Map keyed by coordinate, walked from
; `from` to `to` in steps of `step`. Returns [[start, end], ...] in coordinate
; space, dropping runs shorter than minLen.
ATG_Runs(flags, from, to, step, minLen) {
    runs := [], start := -1, last := -1
    i := from
    while (i <= to) {
        on := flags.Has(i) ? flags[i] : false
        if (on) {
            if (start < 0)
                start := i
            last := i
        } else if (start >= 0) {
            if (last - start + 1 >= minLen)
                runs.Push([start, last])
            start := -1
        }
        i += step
    }
    if (start >= 0 && last - start + 1 >= minLen)
        runs.Push([start, last])
    return runs
}

; ─── Detection ────────────────────────────────────────────────────────

; Returns a Map with:
;   rows    - row count
;   perRow  - array of tile counts per row
;   tiles   - array of rows, each an array of Map("x0","x1","y0","y1")
;   selRow, selCol - current selection, or -1 if the focus ring was not found
;   ms      - elapsed milliseconds
; Returns "" if the switcher is not open or the render came back empty.
; `dumpPath`, if given, writes the raw PrintWindow render as a 32bpp BMP. That
; lets the Python reference detector run on byte-identical input, so an AHK/
; Python disagreement can be diagnosed offline instead of by re-triggering the
; switcher and comparing two different moments.
AltTabDetectGrid(hwnd := 0, dumpPath := "") {
    global ATG_CLASS, ATG_BG_TOL, ATG_SAT_MIN, ATG_MIN_ROW_PX, ATG_MIN_TILE_PX
    t0 := A_TickCount

    if (!hwnd)
        hwnd := WinExist("ahk_class " ATG_CLASS)
    if (!hwnd)
        return ""

    rect := Buffer(16, 0)
    if !DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rect)
        return ""
    wx := NumGet(rect, 0, "Int"), wy := NumGet(rect, 4, "Int")
    w := NumGet(rect, 8, "Int") - wx, h := NumGet(rect, 12, "Int") - wy
    if (w <= 0 || h <= 0)
        return ""

    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", w, bi, 4)
    NumPut("Int", -h, bi, 8)              ; negative height => top-down rows
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)
    NumPut("UInt", 0, bi, 16)             ; BI_RGB

    screenDC := DllCall("GetDC", "Ptr", 0, "Ptr")
    memDC := DllCall("gdi32\CreateCompatibleDC", "Ptr", screenDC, "Ptr")
    pBits := 0
    hbm := DllCall("gdi32\CreateDIBSection", "Ptr", memDC, "Ptr", bi, "UInt", 0,
                   "Ptr*", &pBits, "Ptr", 0, "UInt", 0, "Ptr")
    if (!hbm) {
        DllCall("gdi32\DeleteDC", "Ptr", memDC)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", screenDC)
        return ""
    }
    old := DllCall("gdi32\SelectObject", "Ptr", memDC, "Ptr", hbm, "Ptr")

    result := ""
    try {
        DllCall("PrintWindow", "Ptr", hwnd, "Ptr", memDC, "UInt", 0x2, "Int")
        DllCall("gdi32\GdiFlush")
        if (dumpPath != "")
            ATG_DumpBMP(pBits, w, h, dumpPath)
        result := ATG_Analyse(pBits, w * 4, w, h, wx, wy, t0)
    } finally {
        DllCall("gdi32\SelectObject", "Ptr", memDC, "Ptr", old, "Ptr")
        DllCall("gdi32\DeleteObject", "Ptr", hbm)
        DllCall("gdi32\DeleteDC", "Ptr", memDC)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", screenDC)
    }
    return result
}

ATG_Analyse(pBits, stride, w, h, wx, wy, t0) {
    global ATG_BG_TOL, ATG_SAT_MIN, ATG_MIN_ROW_PX, ATG_MIN_TILE_PX
    global ATG_TILE_XSTEP, ATG_TILE_YSTEP

    ; ── Panel bounds ──
    ; The panel is a single opaque rounded rect centred in a fullscreen host, so
    ; the centre lines cross it and miss the rounded corners entirely.
    midY := h // 2
    px0 := -1, px1 := -1
    x := 0
    while (x < w) {
        if ATG_IsPainted(ATG_Pixel(pBits, stride, x, midY)) {
            px0 := x
            break
        }
        x += 4
    }
    x := w - 1
    while (x >= 0) {
        if ATG_IsPainted(ATG_Pixel(pBits, stride, x, midY)) {
            px1 := x
            break
        }
        x -= 4
    }
    if (px0 < 0 || px1 <= px0)
        return ""

    midX := (px0 + px1) // 2
    py0 := -1, py1 := -1
    y := 0
    while (y < h) {
        if ATG_IsPainted(ATG_Pixel(pBits, stride, midX, y)) {
            py0 := y
            break
        }
        y += 4
    }
    y := h - 1
    while (y >= 0) {
        if ATG_IsPainted(ATG_Pixel(pBits, stride, midX, y)) {
            py1 := y
            break
        }
        y -= 4
    }
    if (py0 < 0 || py1 <= py0)
        return ""

    ; ── Panel fill colour ──
    ; Modal colour over a sparse grid, NOT a single sample. Sampling one pixel a
    ; few px below the panel top looked safe but is not: it landed on #FBFBFB, a
    ; lighter highlight along the panel's top edge, instead of the #F3F3F3 fill.
    ; The real fill then differs from "background" by 8 — over ATG_BG_TOL — so
    ; the entire panel reads as content and collapses into a single band and a
    ; single tile. That produced silently wrong layouts, not just a failure.
    bg := ATG_ModalColour(pBits, stride, px0, py0, px1, py1, ATG_BG_SAMPLE_STEP)

    ; ── Row bands ──
    ; OR several vertical scans: rows are centred, so any single x can fall in a
    ; gap for some row, but a spread of them cannot miss every tile in a row.
    colXs := []
    loop 7
        colXs.Push(px0 + ((px1 - px0) * A_Index) // 8)

    rowFlag := Map()
    y := py0
    while (y <= py1) {
        on := false
        for _, sx in colXs {
            if ATG_Differs(ATG_Pixel(pBits, stride, sx, y), bg, ATG_BG_TOL) {
                on := true
                break
            }
        }
        rowFlag[y] := on
        y += 2
    }
    bands := ATG_Runs(rowFlag, py0, py1, 2, ATG_MIN_ROW_PX)
    if (!bands.Length)
        return ""

    ; ── Tiles per band ──
    ; A column is a gap only if it is background all the way down the band.
    ;
    ; Sampling a few scanlines per band is not enough: Windows' own light-theme
    ; window chrome is #f3f3f3, the SAME colour as the panel fill, so a flat
    ; region of a light-themed thumbnail is locally indistinguishable from
    ; background. With 3 scanlines a whole tile went undetected, leaving a 442px
    ; "gap" between tiles in a row whose real gaps are ~30px, and truncating its
    ; neighbour. The Python reference detector is immune because full-image
    ; density only needs 2% of a column to differ.
    ;
    ; Scanning the full height restores that immunity: a tile always has SOME
    ; non-background pixel somewhere in its height (title text, thumbnail detail,
    ; borders), even where it is locally flat.
    tiles := [], perRow := []
    for _, band in bands {
        by0 := band[1], by1 := band[2]
        colFlag := Map()
        x := px0
        while (x <= px1) {
            on := false
            y := by0
            while (y <= by1) {
                if ATG_Differs(ATG_Pixel(pBits, stride, x, y), bg, ATG_BG_TOL) {
                    on := true
                    break
                }
                y += ATG_TILE_YSTEP
            }
            colFlag[x] := on
            x += ATG_TILE_XSTEP
        }
        runs := ATG_Runs(colFlag, px0, px1, ATG_TILE_XSTEP, ATG_MIN_TILE_PX)
        if (!runs.Length)
            continue

        row := []
        for _, r in runs
            row.Push(Map("x0", r[1], "x1", r[2], "y0", by0, "y1", by1))
        tiles.Push(row)
        perRow.Push(row.Length)
    }
    if (!tiles.Length)
        return ""

    ; ── Selection ──
    ; The focus ring is drawn OUTSIDE the tile (~10px out, separated from the
    ; tile fill by panel grey), and everything outside a tile is panel fill,
    ; which is pure grey. So a saturated pixel just left of a tile means that
    ; tile is selected. Sampling INSIDE would be defeated by any colourful
    ; thumbnail - that mistake picked the wrong tile twice during development.
    ; Search outward on both sides, but never past the neighbouring tile: gaps
    ; here measure 20-36px, so a fixed 22px reach reads into the next tile's
    ; thumbnail and its colour scores as a ring. Clamp the reach to the actual
    ; gap, and score every tile rather than taking the first hit, so a stray
    ; saturated pixel loses to a real ring instead of winning by arriving first.
    selRow := -1, selCol := -1
    best := 0, runnerUp := 0
    for ri, row in tiles {
        for ci, t in row {
            leftLimit := (ci > 1) ? row[ci - 1]["x1"] + 2 : px0
            rightLimit := (ci < row.Length) ? row[ci + 1]["x0"] - 2 : px1
            xa := Max(t["x0"] - 20, leftLimit)
            xb := Min(t["x1"] + 20, rightLimit)

            ; Score the two sides separately and take the MINIMUM.
            ;
            ; The ring lies in the gap between tiles, so the neighbours on
            ; either side see it too — measured 46 and 91 saturation on tiles
            ; adjacent to the selected one. Summing both sides made the selected
            ; tile score 6 against a neighbour's 3, which cleared a 2x margin by
            ; exactly zero. But only the selected tile is ringed on BOTH sides;
            ; a neighbour sees it on one side and nothing on the other. The
            ; minimum is therefore ~3 for the selection and 0 for everyone else.
            ;
            ; The ring is a continuous vertical line, so it registers at every
            ; sampled height; a thumbnail speck does not.
            leftHits := 0, rightHits := 0
            loop 3 {
                sy := t["y0"] + ((t["y1"] - t["y0"]) * A_Index) // 4
                leftHits += ATG_RingNear(pBits, stride, w, xa, t["x0"] - 1, sy)
                rightHits += ATG_RingNear(pBits, stride, w, t["x1"] + 1, xb, sy)
            }
            hits := Min(leftHits, rightHits)

            if (hits > best)
                runnerUp := best, best := hits, selRow := ri, selCol := ci
            else if (hits > runnerUp)
                runnerUp := hits
        }
    }
    ; Both sides must carry the ring at 2 of 3 sampled heights.
    if (best < 2 || best = runnerUp)
        selRow := -1, selCol := -1

    return Map(
        "rows", tiles.Length,
        "perRow", perRow,
        "tiles", tiles,
        "selRow", selRow,
        "selCol", selCol,
        "panelX0", px0 + wx, "panelY0", py0 + wy,
        "panelX1", px1 + wx, "panelY1", py1 + wy,
        "ms", A_TickCount - t0)
}

; ─── Navigation model ─────────────────────────────────────────────────

; Given a grid and a current (row, col), return the [row, col] a given arrow
; would land on, or "" if that direction is at an edge and should be suppressed.
;
; Vertical moves cannot assume column index carries across rows: tiles are
; variable width and the last row is centred, so the switcher lands on whichever
; tile overlaps the current x. Match that by x-centre proximity.
AltTabStep(grid, row, col, dir) {
    tiles := grid["tiles"]
    if (row < 1 || row > tiles.Length)
        return ""
    thisRow := tiles[row]

    if (dir = "Left")
        return (col > 1) ? [row, col - 1] : ""
    if (dir = "Right")
        return (col < thisRow.Length) ? [row, col + 1] : ""

    nextRow := (dir = "Up") ? row - 1 : row + 1
    if (nextRow < 1 || nextRow > tiles.Length)
        return ""

    cur := thisRow[col]
    cx := (cur["x0"] + cur["x1"]) // 2
    best := 1, bestDist := -1
    for ci, t in tiles[nextRow] {
        d := Abs(((t["x0"] + t["x1"]) // 2) - cx)
        if (bestDist < 0 || d < bestDist)
            bestDist := d, best := ci
    }
    return [nextRow, best]
}

; ─── Standalone test ──────────────────────────────────────────────────
; Only when run directly, so including this file from Startup.ahk does not
; register a stray F8. Press F8, then hold Alt+Tab; results go to a tooltip.

; AHK v2.0 has no syntax-check switch (/validate is v2.1, and v2.0 treats an
; unknown switch as the script filename and pops up "script file not found").
; Load-time errors are raised before any code runs, so running with this flag
; and /ErrorStdOut is an equivalent check that stays on stdout:
;     AutoHotkey64.exe /ErrorStdOut AltTabGrid.ahk --selftest
for _, a in A_Args {
    if (a = "--selftest") {
        FileAppend "AltTabGrid.ahk loaded clean`n", "*"
        ExitApp 0
    }
}

; Run standalone and it waits for you to hold Alt+Tab, detects once, appends the
; result to atg-test.log and exits. No hotkey to press and none left registered,
; and it sends no synthetic input - same reasoning as Probe-Capture-AltTab.py.
if (A_ScriptFullPath = A_LineFile)
    ATG_Test()

ATG_Test(*) {
    global ATG_CLASS
    log := A_ScriptDir "\atg-test.log"
    ToolTip "AltTabGrid test - hold Alt+Tab now (20s)"

    deadline := A_TickCount + 20000
    hwnd := 0
    while (A_TickCount < deadline) {
        if (hwnd := WinExist("ahk_class " ATG_CLASS))
            break
        Sleep 30
    }
    if (!hwnd) {
        ToolTip()
        FileAppend "[" A_Now "] timed out - switcher never appeared`n", log, "UTF-8"
        ExitApp 1
    }

    Sleep 250                       ; let the fade-in finish before rendering
    dump := A_ScriptDir "\atg-render.bmp"
    grid := AltTabDetectGrid(hwnd, dump)
    ToolTip()
    if (!grid) {
        FileAppend "[" A_Now "] detection failed`n", log, "UTF-8"
        ExitApp 2
    }

    s := Format("[{1}] rows={2} perRow={3} sel=({4},{5}) {6}ms panel=({7},{8})-({9},{10})`n",
                A_Now, grid["rows"], ATG_Join(grid["perRow"], ","),
                grid["selRow"], grid["selCol"], grid["ms"],
                grid["panelX0"], grid["panelY0"], grid["panelX1"], grid["panelY1"])
    for ri, row in grid["tiles"] {
        s .= "    row " ri ":"
        for _, t in row
            s .= " [" t["x0"] "-" t["x1"] "]"
        s .= "`n"
    }
    FileAppend s, log, "UTF-8"
    ExitApp 0
}

ATG_Join(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i > 1 ? sep : "") v
    return out
}
