#Requires AutoHotkey v2.0

; Probe: tests whether GetAltTabInfo returns useful data on this Windows version.
;
; Press F8 to:
;   1. Open the Alt+Tab switcher.
;   2. Query the foreground window with GetAltTabInfo.
;   3. Release Alt (will commit to the second-most-recent window — expected).
;   4. Show results in a popup.
;
; If cItems/cColumns/cRows come back nonzero, the API works and we can use it to
; query exact grid layout in MouseXB1-WindowSwipe.ahk. If GetAltTabInfo returns 0,
; the popup will show the foreground window's class name as a starting point for
; the UIA fallback.

F8::{
    Send "{Alt Down}{Tab}"
    Sleep 200

    hwnd := WinExist("A")
    ; If no foreground was reported, give the switcher one more moment.
    if !hwnd {
        Sleep 200
        hwnd := WinExist("A")
    }
    if !hwnd {
        Send "{Alt Up}"
        ShowResult("No foreground window detected after Alt+Tab.`nSwitcher may not be opening, or focus is in an unusual state.")
        return
    }

    cls := ""
    try cls := WinGetClass(hwnd)

    ; ALTTABINFO layout (40 bytes total):
    ;   DWORD cbSize       offset  0
    ;   int   cItems       offset  4
    ;   int   cColumns     offset  8
    ;   int   cRows        offset 12
    ;   int   iColFocus    offset 16
    ;   int   iRowFocus    offset 20
    ;   int   cxItem       offset 24
    ;   int   cyItem       offset 28
    ;   POINT ptStart      offset 32 (x), 36 (y)
    info := Buffer(40, 0)
    NumPut("UInt", 40, info, 0)

    result := DllCall("user32\GetAltTabInfo"
                    , "Ptr",  hwnd
                    , "Int",  -1
                    , "Ptr",  info
                    , "Ptr",  0
                    , "UInt", 0)
    err := A_LastError

    Send "{Alt Up}"

    out := "Foreground class: " cls "`n"
    out .= "HWND:             " hwnd "`n"
    out .= "─────────────────────────`n"

    if !result {
        out .= "GetAltTabInfo returned 0`n"
        out .= "GetLastError:     " err "`n`n"
        out .= "→ API does NOT work on this Windows version`n"
        out .= "  for the foreground window above. Fall back to UIA."
    } else {
        out .= "GetAltTabInfo: SUCCESS`n`n"
        out .= "cItems:    " NumGet(info, 4,  "Int") "`n"
        out .= "cColumns:  " NumGet(info, 8,  "Int") "`n"
        out .= "cRows:     " NumGet(info, 12, "Int") "`n"
        out .= "iColFocus: " NumGet(info, 16, "Int") "`n"
        out .= "iRowFocus: " NumGet(info, 20, "Int") "`n"
        out .= "cxItem:    " NumGet(info, 24, "Int") "`n"
        out .= "cyItem:    " NumGet(info, 28, "Int")
    }

    ShowResult(out)
}

ShowResult(text) {
    g := Gui("+AlwaysOnTop +Resize", "GetAltTabInfo Probe")
    g.SetFont("s10", "Consolas")
    g.AddText(, text)
    g.AddButton("Default w80", "OK").OnEvent("Click", (*) => g.Destroy())
    g.Show()
}
