#Requires AutoHotkey v2.0

; Home for small keyboard shortcut overrides — one hotkey per line or two.
; Anything that needs real state or helper functions gets its own script.

; Minimize only the active window; Windows' Win+M minimizes every window
; (Win+D still does that). Win+Shift+M keeps its restore-all behaviour, since
; AHK won't fire #m while an unlisted modifier like Shift is held.
#m::WinMinimize("A")

; Swallowed Windows shortcuts. Nothing is rebound — these just stop the key
; reaching the shell, and only while this script is running. AHK masks the Win
; keypress on release, so blocking a Win combo doesn't leave Start popping open.
#c::return    ; Copilot
#h::return    ; voice typing
#f::return    ; Feedback Hub
#^q::return   ; Quick Assist
#u::return    ; Accessibility settings
