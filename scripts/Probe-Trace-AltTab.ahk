#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\AltTabGrid.ahk

; Trace the selection as YOU drive the switcher, to settle two open questions.
;
; 1. WHAT DOES Up/Down ACTUALLY DO?
;    AltTabStep models a vertical move as landing on the tile whose x-centre is
;    nearest. That was inferred from geometry, never observed. The competing
;    rule is that the switcher preserves the column INDEX. They agree on a
;    uniform grid and diverge exactly where this gesture needs to be right.
;
; 2. WHY DOES FOCUS-RING DETECTION SOMETIMES FIND NOTHING?
;    One run found the selection on 12 of 12 reads, another on 0 of 12.
;
; WHY THIS VERSION WATCHES THE KEYBOARD
;    v1 guessed the direction from the row index changing, and was wrong: on a
;    4,4,3 layout it logged (1,1) -> (3,3) as "Down", when it is Left wrapping
;    backwards to the last tile in the grid. Horizontal wrapping changes rows
;    too, so direction cannot be inferred from the result. v1 also could not
;    tell one keypress from three collapsed between two reads - detection takes
;    ~110ms, and observed gaps ran to 3s.
;
;    So the arrow keys are observed directly with `~` hotkeys, which log the
;    press and pass it straight through - no synthetic input, nothing swallowed.
;    A transition is only used as evidence when EXACTLY ONE key preceded it.
;
; HOW TO RUN
;    Start it, hold Alt+Tab, and press arrows without releasing Alt. Vary the
;    column you press Down from - the two rules only disagree on some columns.
;    Pause ~0.5s between presses. Ambiguous transitions are logged and skipped,
;    so pressing too fast costs evidence but never corrupts it.

logPath := A_ScriptDir "\atg-trace.log"
dumpPath := A_ScriptDir "\atg-selfail.bmp"

for _, a in A_Args {
    if (a = "--smoke") {
        FileAppend Format("[{1}] smoke: logging path OK`n", A_Now), logPath, "UTF-8"
        ExitApp 0
    }
}

pendingKeys := []
traceT0 := A_TickCount

; `~` passes the key through to the switcher; `*` fires regardless of Alt being
; held. Scoped to the switcher so these do not linger over normal arrow use.
HotIfWinExist "ahk_class " ATG_CLASS
for _, k in ["Up", "Down", "Left", "Right", "Tab"]
    Hotkey "~*" k, OnTraceKey
HotIf

OnTraceKey(hkName) {
    global pendingKeys, traceT0, logPath
    key := RegExReplace(hkName, "^[~*$]+", "")
    pendingKeys.Push(key)
    FileAppend Format("  t+{1} KEY {2}`n", A_TickCount - traceT0, key),
               logPath, "UTF-8"
}

ToolTip "Trace probe - hold Alt+Tab and press arrows (25s)"
deadline := A_TickCount + 25000
hwnd := 0
while (A_TickCount < deadline) {
    if (hwnd := WinExist("ahk_class " ATG_CLASS))
        break
    Sleep 5
}
if (!hwnd) {
    ToolTip()
    FileAppend "[" A_Now "] timed out`n", logPath, "UTF-8"
    ExitApp 1
}

FileAppend "`n[" A_Now "] trace start`n", logPath, "UTF-8"
traceT0 := A_TickCount
pendingKeys := []

prevRow := 0, prevCol := 0, dumped := false, geomLogged := false
loop 250 {
    if !WinExist("ahk_class " ATG_CLASS)
        break

    grid := AltTabDetectGrid(hwnd)
    if (!grid)
        continue

    if (!geomLogged) {
        geomLogged := true
        FileAppend Format("  layout rows={1} perRow={2}`n", grid["rows"],
                          ATG_Join(grid["perRow"], ",")), logPath, "UTF-8"
        for ri, row in grid["tiles"] {
            s := "    row " ri ":"
            for ci, t in row
                s .= Format(" [{1}]{2}-{3}(c{4})", ci, t["x0"], t["x1"],
                            (t["x0"] + t["x1"]) // 2)
            FileAppend s "`n", logPath, "UTF-8"
        }
    }

    r := grid["selRow"], c := grid["selCol"]
    if (r < 1) {
        if (!dumped) {
            dumped := true
            ; Re-render, this time saving it. v1 dumped on the first call before
            ; knowing whether it failed, and captured a perfectly good frame.
            AltTabDetectGrid(hwnd, dumpPath)
            FileAppend Format("  t+{1} SELECTION NOT FOUND - render dumped`n",
                              A_TickCount - traceT0), logPath, "UTF-8"
        }
        continue
    }

    if (r = prevRow && c = prevCol)
        continue

    keys := pendingKeys.Clone()
    pendingKeys := []

    line := Format("  t+{1} ({2},{3})", A_TickCount - traceT0, r, c)
    if (prevRow) {
        from := grid["tiles"][prevRow][prevCol]
        to := grid["tiles"][r][c]
        fcx := (from["x0"] + from["x1"]) // 2
        tcx := (to["x0"] + to["x1"]) // 2
        line .= Format("  from ({1},{2})  cx {3}->{4}  keys=[{5}]",
                       prevRow, prevCol, fcx, tcx, ATG_Join(keys, " "))

        ; Only a single unambiguous vertical press discriminates the two rules.
        if (keys.Length != 1)
            line .= "`n      (ambiguous - " (keys.Length ? "multiple keys" : "no key seen")
                  . ", skipped)"
        else if (keys[1] = "Up" || keys[1] = "Down") {
            pred := AltTabStep(grid, prevRow, prevCol, keys[1])
            nearest := (pred = "") ? "-" : pred[2]
            sameIdx := Min(prevCol, grid["tiles"][r].Length)
            line .= Format("`n      {1}: nearest-centre={2} same-index={3} ACTUAL={4}  => {5}",
                           keys[1], nearest, sameIdx, c,
                           (nearest = c && sameIdx != c) ? "NEAREST-CENTRE"
                         : (sameIdx = c && nearest != c) ? "SAME-INDEX"
                         : (nearest = c && sameIdx = c) ? "both agree (uninformative)"
                         : "NEITHER")
        }
    }
    FileAppend line "`n", logPath, "UTF-8"
    prevRow := r, prevCol := c
}

FileAppend "  trace end`n", logPath, "UTF-8"
ToolTip()
ExitApp 0
