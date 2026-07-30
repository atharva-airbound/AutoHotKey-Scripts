#Requires AutoHotkey v2.0

; A_LineFile, not A_ScriptDir: inside an #Include, A_ScriptDir is the MAIN
; script's directory, so %A_ScriptDir%\AltTabGrid.ahk resolves correctly when
; this file is run directly but looks for it beside Startup.ahk when included
; from there. A_LineFile is always this file.
#Include %A_LineFile%\..\AltTabGrid.ahk

; Lower side button: Alt+Tab window-switcher gesture.
; Press-and-hold opens Alt+Tab; mouse movement navigates the grid
; (Δx → Left/Right, Δy → Up/Down); release commits the selection.
;
; ─── Edge clamping ───────────────────────────────────────────────
; Without a grid model, swiping past the rightmost tile makes the switcher wrap
; onto the next row, so continuous horizontal motion produces vertical jumps.
; AltTabGrid.ahk reads the real layout at runtime (it cannot be computed or
; cached — tile width tracks window aspect ratio, so layout depends on which
; windows are open, not how many). Arrows that would wrap are suppressed.
;
; Detection cannot be instant: the switcher has to fade in before it can be
; rendered, and PrintWindow plus the scan costs 90-140ms, so the grid is not
; known until roughly 350ms after button-down. Rather than fire arrows blind
; during that window — which would let exactly the wrapping bug through, just
; more rarely — motion is accumulated and arrows are QUEUED until the grid
; lands, then replayed through the clamp.
;
; Holding has a second benefit: because nothing has been sent yet when
; detection completes, the selection is still wherever Alt+Tab put it. So if
; the focus-ring read fails, the starting cell is known rather than guessed.

; ─── Mode selection ───────────────────────────────────────────────
; "decay"     — distance accumulator, but the accumulator decays when
;               movement drops below a per-poll deadzone (kills overshoot).
; "velocity"  — no accumulator; fires an arrow at a rate that scales with
;               current speed. Stops firing the instant the hand stops.
; "nonlinear" — distance accumulator with deadzone + a flick shortcut:
;               a single fast per-poll delta fires immediately.
; "sticky"    — hysteresis: high threshold to break free, low threshold once
;               "moving". Idle period re-arms the high threshold.
mode := "velocity"

; Vertical motion is dampened so swiping up/down requires proportionally more
; movement than left/right, matching the screen's aspect ratio. Auto-derived
; from the primary screen; override manually if you want a different feel.
verticalFactor := A_ScreenWidth / A_ScreenHeight

; ─── Tunables: "decay" ────────────────────────────────────────────
A_threshold  := 200   ; px of accumulated motion per arrow keypress
A_deadzone   := 3     ; per-poll |Δ| below this counts as "still"
A_decayRate  := 0.5   ; accumulator multiplier each still poll (0 = instant drain)

; ─── Tunables: "velocity" ─────────────────────────────────────────
B_speedMin      := 5   ; per-poll |Δ| below this emits nothing
B_speedRef      := 20  ; per-poll |Δ| at which cooldown is minimized
B_baseCooldown  := 120 ; ms between arrows when speed == speedMin
B_minCooldown   := 30  ; ms between arrows when speed >= speedRef

; ─── Tunables: "nonlinear" ────────────────────────────────────────
C_threshold  := 200   ; same as A_threshold
C_deadzone   := 3     ; per-poll |Δ| below this is ignored entirely
C_flickDelta := 40    ; per-poll |Δ| at/above this fires an arrow immediately

; ─── Tunables: edge clamping ──────────────────────────────────────
; Retry delay, NOT an upfront settle. The first render is attempted the instant
; the switcher window exists, because measurement (Probe-Timing-AltTab.ahk)
; showed detection already returns the correct layout at t+0 with the panel
; background settled at #f3f3f3 — the fade completes before the window becomes
; findable. An upfront wait here is pure added latency on every gesture, and
; the hold before arrows are released is perceptible.
;
; The delay still matters on failure: a cold or slow invocation could be
; findable before it is painted, and rendering mid-fade returns a
; part-transparent panel whose tile contrast is too low to scan.
E_retryMs := 120
; Detection attempts before giving up and running unclamped. Falling back to
; the old wrapping behaviour is much better than a gesture that stops working.
E_maxTries := 3

; ─── Tunables: "sticky" ───────────────────────────────────────────
D_activate    := 120    ; px to accumulate before FIRST arrow (the "break-free" barrier)
D_continue    := 80    ; px per arrow once moving
D_idleTimeout := 200   ; ms of stillness before the barrier re-arms
D_deadzone    := 2     ; per-poll |Δ| counted as "motion" for idle detection

XButton1::{
    global mode, verticalFactor
    CoordMode "Mouse", "Screen"

    ; If foreground is hung, synthetic input gets swallowed. Nudge focus loose first.
    fgHwnd := WinActive("A")
    if (fgHwnd && DllCall("user32\IsHungAppWindow", "Ptr", fgHwnd)) {
        try WinActivate "ahk_class Shell_TrayWnd"
        Sleep 30
    }

    Send "{Alt Down}{Tab}"

    MouseGetPos(&lastX, &lastY)
    state := Map("accumX", 0.0, "accumY", 0.0, "nextFire", 0, "active", false,
                 "lastMove", A_TickCount,
                 "grid", "", "ready", false, "row", 0, "col", 0,
                 "queue", [], "detectAt", 0, "tries", 0)

    while GetKeyState("XButton1", "P") {
        ; Blocks for ~100ms on the attempt that actually renders. Harmless:
        ; deltas come from absolute cursor positions, so a sampling gap is one
        ; large delta rather than lost motion.
        if (!state["ready"])
            TryDetectGrid(state)

        MouseGetPos(&curX, &curY)
        dx := curX - lastX
        dy := (curY - lastY) / verticalFactor
        lastX := curX
        lastY := curY

        switch mode {
            case "decay":     ProcessDecay(dx, dy, state)
            case "velocity":  ProcessVelocity(dx, dy, state)
            case "nonlinear": ProcessNonlinear(dx, dy, state)
            case "sticky":    ProcessSticky(dx, dy, state)
        }

        Sleep 10
    }

    ; A gesture shorter than the detection window still has to commit whatever
    ; the user swiped, so flush before releasing Alt.
    if (!state["ready"] && state["queue"].Length)
        FlushArrowQueue(state)

    Send "{Alt Up}"
}

; ─── Grid detection and clamping ──────────────────────────────────

TryDetectGrid(state) {
    global ATG_CLASS, E_retryMs, E_maxTries

    if (!state["detectAt"]) {
        ; Render immediately on first sighting - no upfront settle.
        if WinExist("ahk_class " ATG_CLASS)
            state["detectAt"] := A_TickCount
        return
    }
    if (A_TickCount < state["detectAt"])
        return

    state["tries"] += 1
    grid := AltTabDetectGrid()
    if (grid) {
        state["grid"] := grid
        if (grid["selRow"] > 0) {
            state["row"] := grid["selRow"]
            state["col"] := grid["selCol"]
        } else {
            ; Ring not found. No arrows have been sent yet, so the selection is
            ; still where Alt+Tab left it: the second tile of the first row.
            state["row"] := 1
            state["col"] := Min(2, grid["tiles"][1].Length)
        }
    } else if (state["tries"] < E_maxTries) {
        state["detectAt"] := A_TickCount + E_retryMs
        return
    }

    ; Ready even on total failure - state["grid"] stays "" and arrows go out
    ; unclamped, i.e. the original behaviour.
    state["ready"] := true
    FlushArrowQueue(state)
}

; Every arrow in this script goes through here. Before the grid is known they
; queue; afterwards they are clamped against it.
EmitArrow(state, dir) {
    if (!state["ready"]) {
        state["queue"].Push(dir)
        return
    }
    SendArrowClamped(state, dir)
}

SendArrowClamped(state, dir) {
    grid := state["grid"]
    if (!grid) {
        Send "{" dir "}"
        return
    }
    next := AltTabStep(grid, state["row"], state["col"], dir)
    if (next = "")
        return                      ; at an edge: suppress rather than wrap
    state["row"] := next[1]
    state["col"] := next[2]
    Send "{" dir "}"
}

FlushArrowQueue(state) {
    for _, dir in state["queue"]
        SendArrowClamped(state, dir)
    state["queue"] := []
}

ProcessDecay(dx, dy, state) {
    global A_threshold, A_deadzone, A_decayRate
    state["accumX"] += dx
    state["accumY"] += dy
    if (Abs(dx) < A_deadzone)
        state["accumX"] *= A_decayRate
    if (Abs(dy) < A_deadzone)
        state["accumY"] *= A_decayRate
    EmitFromAccum(state, A_threshold)
}

ProcessVelocity(dx, dy, state) {
    global B_speedMin, B_speedRef, B_baseCooldown, B_minCooldown
    speed := Sqrt(dx*dx + dy*dy)
    if (speed < B_speedMin)
        return
    if (A_TickCount < state["nextFire"])
        return

    if (Abs(dx) >= Abs(dy))
        EmitArrow(state, (dx > 0) ? "Right" : "Left")
    else
        EmitArrow(state, (dy > 0) ? "Down" : "Up")

    t := (speed - B_speedMin) / (B_speedRef - B_speedMin)
    if (t > 1)
        t := 1
    cooldown := B_baseCooldown - t * (B_baseCooldown - B_minCooldown)
    state["nextFire"] := A_TickCount + cooldown
}

ProcessNonlinear(dx, dy, state) {
    global C_threshold, C_deadzone, C_flickDelta

    if (Abs(dx) >= C_deadzone)
        state["accumX"] += dx
    if (Abs(dy) >= C_deadzone)
        state["accumY"] += dy

    if (dx >= C_flickDelta) {
        EmitArrow(state, "Right")
        state["accumX"] := 0
    } else if (dx <= -C_flickDelta) {
        EmitArrow(state, "Left")
        state["accumX"] := 0
    }
    if (dy >= C_flickDelta) {
        EmitArrow(state, "Down")
        state["accumY"] := 0
    } else if (dy <= -C_flickDelta) {
        EmitArrow(state, "Up")
        state["accumY"] := 0
    }

    EmitFromAccum(state, C_threshold)
}

ProcessSticky(dx, dy, state) {
    global D_activate, D_continue, D_idleTimeout, D_deadzone

    state["accumX"] += dx
    state["accumY"] += dy

    if (Abs(dx) >= D_deadzone || Abs(dy) >= D_deadzone)
        state["lastMove"] := A_TickCount

    ; Re-arm barrier after a period of stillness
    if (state["active"] && A_TickCount - state["lastMove"] > D_idleTimeout) {
        state["active"] := false
        state["accumX"] := 0
        state["accumY"] := 0
    }

    ; Emit one arrow at a time; threshold depends on whether we've "broken free"
    loop {
        threshold := state["active"] ? D_continue : D_activate
        if (state["accumX"] >= threshold) {
            EmitArrow(state, "Right")
            state["accumX"] -= threshold
            state["active"] := true
        } else if (state["accumX"] <= -threshold) {
            EmitArrow(state, "Left")
            state["accumX"] += threshold
            state["active"] := true
        } else if (state["accumY"] >= threshold) {
            EmitArrow(state, "Down")
            state["accumY"] -= threshold
            state["active"] := true
        } else if (state["accumY"] <= -threshold) {
            EmitArrow(state, "Up")
            state["accumY"] += threshold
            state["active"] := true
        } else {
            break
        }
    }
}

EmitFromAccum(state, threshold) {
    while (state["accumX"] >= threshold) {
        EmitArrow(state, "Right")
        state["accumX"] -= threshold
    }
    while (state["accumX"] <= -threshold) {
        EmitArrow(state, "Left")
        state["accumX"] += threshold
    }
    while (state["accumY"] >= threshold) {
        EmitArrow(state, "Down")
        state["accumY"] -= threshold
    }
    while (state["accumY"] <= -threshold) {
        EmitArrow(state, "Up")
        state["accumY"] += threshold
    }
}
