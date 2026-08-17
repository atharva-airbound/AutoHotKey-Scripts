#Requires AutoHotkey v2.0

; Home for small keyboard shortcut overrides — one hotkey per line or two.
; Anything that needs real state or helper functions gets its own script.

; Minimize only the active window; Windows' Win+M minimizes every window
; (Win+D still does that). Win+Shift+M keeps its restore-all behaviour, since
; AHK won't fire #m while an unlisted modifier like Shift is held.
#m::WinMinimize("A")
