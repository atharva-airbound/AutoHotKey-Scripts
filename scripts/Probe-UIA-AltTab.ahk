#Requires AutoHotkey v2.0

; UIA probe for the Alt+Tab switcher.
;
; SETUP:
;   1. Download UIA.ahk from https://github.com/Descolada/UIA-v2
;      (the main library file is at Lib/UIA.ahk in that repo).
;   2. Drop UIA.ahk next to this script.
;
; PRESS F8:
;   1. Opens Alt+Tab.
;   2. Walks the switcher's UIA tree to find tile elements.
;   3. Clusters their bounding rects by Y-center to derive rows × columns.
;   4. Shows results in a popup.
;   Side effect: releasing Alt commits to the second-most-recent window, same
;   as the GetAltTabInfo probe.

#Include "UIA.ahk"

F8::{
    Send "{Alt Down}{Tab}"
    Sleep 500

    hwnd := WinExist("A")
    if !hwnd {
        Send "{Alt Up}"
        ShowResult("No foreground window detected.")
        return
    }

    cls := ""
    try cls := WinGetClass(hwnd)

    el := ""
    try {
        el := UIA.ElementFromHandle(hwnd)
    } catch as e {
        Send "{Alt Up}"
        ShowResult("UIA.ElementFromHandle failed.`nClass: " cls "`n`nError: " e.Message)
        return
    }

    ; Try a range of control types — different Windows builds use different ones.
    candidateTypes := ["ListItem", "Button", "ListViewItem", "GridViewItem", "DataItem", "Pane", "Group"]
    tiles := ""
    matchedType := ""
    for t in candidateTypes {
        try tiles := el.FindAll({Type: t})
        if (IsObject(tiles) && tiles.Length) {
            matchedType := t
            break
        }
    }

    rects := []
    if (IsObject(tiles) && matchedType != "") {
        for tile in tiles {
            try {
                br := tile.BoundingRectangle
                rects.Push({
                    l: br.l, t: br.t, r: br.r, b: br.b,
                    cx: (br.l + br.r) // 2,
                    cy: (br.t + br.b) // 2,
                    name: tile.Name
                })
            }
        }
    }

    Send "{Alt Up}"

    if !rects.Length {
        out := "Class: " cls "`n"
        out .= "Found 0 tile elements via UIA.`n"
        out .= "Tried: " ArrayJoin(candidateTypes, ", ") "`n"
        ShowResult(out)
        return
    }

    SortRectsByCy(rects)

    ; Group tiles into rows by Y-center proximity.
    tolerance := 30
    rows := [[rects[1]]]
    Loop rects.Length - 1 {
        r := rects[A_Index + 1]
        last := rows[rows.Length]
        if (Abs(r.cy - last[1].cy) <= tolerance)
            last.Push(r)
        else
            rows.Push([r])
    }

    maxCols := 0
    for row in rows
        if (row.Length > maxCols)
            maxCols := row.Length

    out := "Class:       " cls "`n"
    out .= "Total tiles: " rects.Length "`n"
    out .= "Rows:        " rows.Length "`n"
    out .= "Max cols:    " maxCols "`n"
    out .= "─────────────────────────`n"
    for i, row in rows
        out .= "Row " (i - 1) ": " row.Length " tile(s)  (y≈" row[1].cy ")`n"

    out .= "Matched type: " matchedType "`n"
    out .= "─────────────────────────`n"
    out .= "First few names:`n"
    Loop Min(rects.Length, 6)
        out .= "  • " rects[A_Index].name "`n"

    ShowResult(out)
}

ArrayJoin(arr, sep) {
    s := ""
    for i, v in arr
        s .= (i > 1 ? sep : "") v
    return s
}

SortRectsByCy(rects) {
    n := rects.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if (rects[j].cy > rects[j + 1].cy) {
                tmp := rects[j]
                rects[j] := rects[j + 1]
                rects[j + 1] := tmp
            }
        }
    }
}

ShowResult(text) {
    g := Gui("+AlwaysOnTop +Resize", "UIA Probe")
    g.SetFont("s10", "Consolas")
    g.AddText(, text)
    g.AddButton("Default w80", "OK").OnEvent("Click", (*) => g.Destroy())
    g.Show()
}
