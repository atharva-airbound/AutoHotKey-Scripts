#Requires AutoHotkey v2.0

; Lower side button: Alt+Tab window-switcher gesture.
; Press-and-hold opens Alt+Tab; mouse movement navigates the grid
; (Δx → Left/Right, Δy → Up/Down); release commits the selection.

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
    state := Map("accumX", 0.0, "accumY", 0.0, "nextFire", 0, "active", false, "lastMove", A_TickCount)

    while GetKeyState("XButton1", "P") {
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

    Send "{Alt Up}"
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
        Send (dx > 0) ? "{Right}" : "{Left}"
    else
        Send (dy > 0) ? "{Down}" : "{Up}"

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
        Send "{Right}"
        state["accumX"] := 0
    } else if (dx <= -C_flickDelta) {
        Send "{Left}"
        state["accumX"] := 0
    }
    if (dy >= C_flickDelta) {
        Send "{Down}"
        state["accumY"] := 0
    } else if (dy <= -C_flickDelta) {
        Send "{Up}"
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
            Send "{Right}"
            state["accumX"] -= threshold
            state["active"] := true
        } else if (state["accumX"] <= -threshold) {
            Send "{Left}"
            state["accumX"] += threshold
            state["active"] := true
        } else if (state["accumY"] >= threshold) {
            Send "{Down}"
            state["accumY"] -= threshold
            state["active"] := true
        } else if (state["accumY"] <= -threshold) {
            Send "{Up}"
            state["accumY"] += threshold
            state["active"] := true
        } else {
            break
        }
    }
}

EmitFromAccum(state, threshold) {
    while (state["accumX"] >= threshold) {
        Send "{Right}"
        state["accumX"] -= threshold
    }
    while (state["accumX"] <= -threshold) {
        Send "{Left}"
        state["accumX"] += threshold
    }
    while (state["accumY"] >= threshold) {
        Send "{Down}"
        state["accumY"] -= threshold
    }
    while (state["accumY"] <= -threshold) {
        Send "{Up}"
        state["accumY"] += threshold
    }
}
