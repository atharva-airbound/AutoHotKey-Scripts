#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\AltTabGrid.ahk

; How soon after the switcher appears is it actually renderable?
;
; MouseXB1-WindowSwipe.ahk holds arrow keys until the grid is known, and that
; hold is perceptible. Its E_settleMs (200ms) is a guess carried over from the
; offline test, where latency did not matter. This measures the real floor.
;
; Rendering mid-fade is not merely slower, it is wrong: a part-transparent panel
; compresses the panel-vs-tile contrast (normally 12 levels, #f3f3f3 vs white)
; toward zero, so the tile scan starts losing columns. The question is the
; earliest moment detection is both fast AND correct - not just non-empty.
;
; Sends no synthetic input: you hold Alt+Tab, it watches. Same reasoning as
; Probe-Capture-AltTab.py - a probe that drives Alt+Tab itself left Alt stuck
; when it crashed, and stole focus on every run.
;
; Run it, hold Alt+Tab for ~2s, then read atg-timing.log. Do several runs: the
; fade is animation, so the floor varies and one sample proves nothing.

; Not `log`: that collides with the built-in Log() function at global scope.
logPath := A_ScriptDir "\atg-timing.log"
CoordMode "Pixel", "Screen"

; --smoke exercises the logging path and exits. A parse check is not enough
; here: `log` resolving to the built-in Log function is a RUNTIME type error, so
; the script loaded clean and still died mid-run. --selftest cannot cover this
; either, since AltTabGrid.ahk handles that flag from its #Include at the top
; and exits before any code below runs.
for _, a in A_Args {
    if (a = "--smoke") {
        FileAppend Format("[{1}] smoke: logging path OK`n", A_Now), logPath, "UTF-8"
        ExitApp 0
    }
}

ToolTip "Timing probe - hold Alt+Tab now (20s)"
deadline := A_TickCount + 20000
hwnd := 0
while (A_TickCount < deadline) {
    if (hwnd := WinExist("ahk_class " ATG_CLASS))
        break
    Sleep 5                     ; tight poll: t0 accuracy sets the whole scale
}
if (!hwnd) {
    ToolTip()
    FileAppend "[" A_Now "] timed out`n", logPath, "UTF-8"
    ExitApp 1
}

t0 := A_TickCount               ; switcher window first observed
WinGetPos(&wx, &wy, &ww, &wh, hwnd)
cx := wx + ww // 2, cy := wy + wh // 2

FileAppend Format("`n[{1}] switcher {2}x{3} at ({4},{5}), centre ({6},{7})`n",
                  A_Now, ww, wh, wx, wy, cx, cy), logPath, "UTF-8"
FileAppend "  t+ms  centre    detect  took  result`n", logPath, "UTF-8"

; Hammer detection from the moment the window exists. Each attempt costs
; ~100ms, so that is the sampling granularity - which is the resolution that
; matters, since E_settleMs is only worth tuning in ~50ms steps.
lastGood := "", stableSince := 0
loop 12 {
    tBefore := A_TickCount - t0

    ; Cheap fade indicator. The panel is centred in the host window, so the
    ; window centre is inside it; during the fade this value is still moving.
    centre := "??????"
    try centre := Format("{:06X}", PixelGetColor(cx, cy))

    tDetect := A_TickCount
    grid := AltTabDetectGrid(hwnd)
    took := A_TickCount - tDetect

    if (grid) {
        res := Format("rows={1} perRow={2} sel=({3},{4})", grid["rows"],
                      ATG_Join(grid["perRow"], ","), grid["selRow"], grid["selCol"])
        ; Two consecutive identical reads is the real signal. A single success
        ; can still be a mid-fade misread that happens to parse.
        if (res = lastGood && !stableSince)
            stableSince := tBefore
        lastGood := res
    } else {
        res := "FAILED"
        lastGood := "", stableSince := 0
    }

    FileAppend Format("  {1:5}  {2}  {3:6}  {4:4}  {5}`n",
                      tBefore, centre, grid ? "ok" : "fail", took, res),
               logPath, "UTF-8"

    if (!WinExist("ahk_class " ATG_CLASS)) {
        FileAppend "  (switcher closed - released too early)`n", logPath, "UTF-8"
        break
    }
}

FileAppend stableSince
    ? Format("  => first of two matching reads at t+{1}ms`n", stableSince)
    : "  => never produced two matching reads`n", logPath, "UTF-8"

ToolTip()
ExitApp 0
