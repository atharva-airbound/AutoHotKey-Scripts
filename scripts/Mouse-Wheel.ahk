#Requires AutoHotkey v2.0

; Wheel modifiers using the upper side button (XButton2) and the right button:
;   XB2 + wheel        → fast scroll (5× ticks)
;   XB2 + RB + wheel   → Ctrl+wheel (universal zoom shortcut),
;                        or Alt+wheel when the pointer is over a Firefox window
;   RB + wheel         → horizontal scroll (WheelUp = left, WheelDown = right)
;
; RButton is always intercepted: on release it re-emits a real right-click
; (context menu) ONLY if no scroll happened during the hold. If you scrolled —
; horizontally, or zoomed with XB2 — the click is swallowed so no context menu
; pops up. (Trade-off: every right-click is now synthetic, so right-drag and
; right-button-down gestures in apps/games no longer work while this is loaded.)
;
; XB2 and RB are each tracked with a flag (g_xb2Held / g_rbHeld) set by the button's
; down-hotkey and cleared by its up-hotkey, rather than polling GetKeyState(...,"P")
; in the #HotIf lines. The physical-state poll could desync during bursts of fast
; scrolling, leaving the fast-scroll/zoom/h-scroll context "stuck" on.
;
; Down/up hotkeys are used instead of a blocking KeyWait. KeyWait would park the
; handler thread until release, and AHK runs threads as a stack: whichever button
; was pressed FIRST sits at the bottom, and its KeyWait cannot return until the
; thread stacked on top of it (the second button) finishes. That made release
; order-dependent — releasing the first-pressed button did nothing until the
; second was released. Down/up hotkeys never block, so press order is irrelevant.

scrollMultiplier := 5
hScrollMultiplier := 1    ; horizontal scroll speed (notches per wheel tick); bump for faster pan
WHEEL_DELTA := 120        ; one wheel notch, per the Win32 wheel API
escDismissDelay := 50     ; ms after XB2 release before auto-Escape dismisses a menu
g_rbScrolled := false
g_altHeld := false
g_xb2Held := false
g_rbHeld := false
g_menuRisk := false       ; did this hold do something that can pop a menu?

; Watchdog: a hard fast-scroll burst can saturate the mouse hook and cause the
; XB2 up-event to be dropped, so the up-hotkey never fires and g_xb2Held stays
; stuck. This self-heals the flag if the hook's tracked physical state says XB2 is up.
; NOTE: GetKeyState(...,"P") — not GetAsyncKeyState — because the XButton2 hotkey
; suppresses the button, so the OS-level async state never sees it as held and
; would false-clear the flag mid-hold; the hook's "P" state tracks it correctly.
SetTimer Xb2Watchdog, 200

Xb2Watchdog() {
    global g_xb2Held, g_rbHeld
    if (g_xb2Held && !GetKeyState("XButton2", "P")) {
        g_xb2Held := false
        ReleaseAlt()
    }
    if (g_rbHeld && !GetKeyState("RButton", "P"))
        g_rbHeld := false
}

; Suppress XB2's default "forward navigation" and track its held state. The down
; hotkey sets the flag (and resets per-hold menu risk); the up hotkey clears the
; flag and drops any Alt left held from a Firefox zoom.
XButton2::{
    global g_xb2Held := true
    global g_menuRisk := false
}
XButton2 Up::{
    global g_xb2Held := false
    ReleaseAlt()
    ; If a zoom or right-click during the hold may have popped a menu (Firefox
    ; menu bar / context menu), auto-dismiss it shortly after release.
    if (g_menuRisk)
        SetTimer DismissMenu, -escDismissDelay
}

#HotIf g_xb2Held && g_rbHeld
WheelUp::ZoomWheel("{WheelUp}")
WheelDown::ZoomWheel("{WheelDown}")
#HotIf

; Fast scroll: emit ONE wheel event carrying scrollMultiplier× the normal delta
; per physical tick, instead of multiplying the event count. Multiplying the
; count floods the target app's scroll queue on a fast burst, so it keeps
; scrolling after you stop; a single larger-delta event has no pile-up. See
; FastWheel for why the injected event doesn't re-trigger these hotkeys.
#HotIf g_xb2Held && !g_rbHeld
WheelUp::FastWheel(WHEEL_DELTA * scrollMultiplier)
WheelDown::FastWheel(-WHEEL_DELTA * scrollMultiplier)
#HotIf

; Horizontal scroll: RB held (without XB2) turns the wheel into a left/right pan.
; Marks g_rbScrolled so the RButton handler swallows the context-menu click on
; release. WheelUp = left, WheelDown = right — swap the signs to invert.
#HotIf !g_xb2Held && g_rbHeld
WheelUp::HScroll(-WHEEL_DELTA * hScrollMultiplier)
WheelDown::HScroll(WHEEL_DELTA * hScrollMultiplier)
#HotIf

; RButton is always intercepted so RB+wheel can be repurposed (h-scroll, or zoom
; while XB2 is also held) and the resulting context-menu click suppressed. The
; down hotkey arms the hold; the up hotkey re-emits a genuine right-click only if
; nothing scrolled during the hold.
RButton::{
    global g_rbScrolled := false
    global g_rbHeld := true
}
RButton Up::{
    global g_rbHeld := false
    ReleaseAlt()
    if (!g_rbScrolled) {
        if (g_xb2Held)
            global g_menuRisk := true   ; menu may need auto-dismiss on XB2 release
        Click "Right"
    }
}

; Firefox zooms via mousewheel.with_alt.action, so hold Alt down for the whole
; gesture instead of tapping it per tick — a lone Alt press/release activates the
; menu bar and makes it glitch in and out. Alt is released on RButton release and,
; as a safety net, on XButton2 release (see ReleaseAlt) so it can never get stuck.
ZoomWheel(wheel) {
    global g_rbScrolled := true
    if (MouseOverFirefox()) {
        global g_menuRisk := true   ; Alt can surface Firefox's menu bar
        if (!g_altHeld) {
            Send "{Alt down}"
            global g_altHeld := true
        }
        Send wheel
    } else {
        Send "^" wheel
    }
}

; Which app gets the zoom is decided by the window UNDER THE POINTER, not the
; active one: Windows routes the wheel event to the hovered window, so with
; another app focused and the pointer over Firefox, WinActive said "not Firefox"
; and we sent Ctrl+wheel — which Firefox ignores for zoom. MouseGetPos's window
; output is the top-level window under the cursor; the try guards the window
; vanishing between the two calls (WinGetProcessName would throw a TargetError).
MouseOverFirefox() {
    MouseGetPos , , &hwnd
    try
        return WinGetProcessName("ahk_id " hwnd) = "firefox.exe"
    return false
}

ReleaseAlt() {
    global g_altHeld
    if (g_altHeld) {
        Send "{Alt up}"
        g_altHeld := false
    }
}

; One-shot timer (scheduled on XB2 release) that taps Escape to close a menu
; left open by a zoom or right-click during the hold.
DismissMenu() {
    Send "{Escape}"
}

; Horizontal pan for RB+wheel. Marks g_rbScrolled so the RButton handler knows to
; swallow the context-menu click, then injects a horizontal wheel event.
HScroll(delta) {
    global g_rbScrolled := true
    FastWheel(delta, true)
}

; Inject a single mouse-wheel event with the given (signed) delta via SendInput.
; horizontal=true emits a horizontal wheel (MOUSEEVENTF_HWHEEL: +delta = right).
; The injected event is tagged with AutoHotkey's KEY_IGNORE value in dwExtraInfo
; so AHK's own mouse hook skips it — otherwise it would re-trigger the WheelUp/
; WheelDown hotkeys above and recreate the very flooding we're avoiding. The OS
; still delivers the event to the focused window, which scrolls by the full delta.
FastWheel(delta, horizontal := false) {
    static KEY_IGNORE := 0xFFC3D44F
    static INPUT_MOUSE := 0
    static MOUSEEVENTF_WHEEL := 0x0800
    static MOUSEEVENTF_HWHEEL := 0x01000
    flags := horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL
    ; INPUT = DWORD type + MOUSEINPUT union. The union is pointer-aligned, so it
    ; starts at offset 8 on x64 / 4 on x86; dwExtraInfo (ULONG_PTR) sits after a
    ; pad on x64. Compute sizes/offsets per architecture.
    x64 := (A_PtrSize = 8)
    size := x64 ? 40 : 28
    union := x64 ? 8 : 4
    buf := Buffer(size, 0)
    NumPut("UInt", INPUT_MOUSE, buf, 0)              ; type
    NumPut("Int", delta, buf, union + 8)             ; mouseData (signed wheel delta)
    NumPut("UInt", flags, buf, union + 12)           ; dwFlags
    NumPut("UPtr", KEY_IGNORE, buf, union + (x64 ? 24 : 20)) ; dwExtraInfo
    DllCall("SendInput", "UInt", 1, "Ptr", buf, "Int", size)
}
