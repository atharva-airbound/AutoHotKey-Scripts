#Requires AutoHotkey v2.0

; MSAA probe for the Alt+Tab switcher (IDispatch flavor).
;
; PRESS F8:
;   1. Opens Alt+Tab.
;   2. Walks the foreground window's MSAA tree via IDispatch::Invoke
;      (using AHK's ComObjFromPtr wrapper instead of raw vtable calls).
;   3. Clusters bounding rects by Y-center to derive rows × columns.
;   4. Shows results in a popup.

OBJID_CLIENT := 0xFFFFFFFC
IID_IAccessible := "{618736E0-3C3D-11CF-810C-00AA00389B71}"

ROLE_NAMES := Map(
    0,"TitleBar",  8,"Window",  9,"Client",  10,"MenuPopup", 11,"MenuItem",
    13,"Application", 14,"Document", 15,"Pane", 17,"Dialog", 18,"Border",
    19,"Grouping", 20,"Separator", 21,"Toolbar", 22,"StatusBar", 23,"Table",
    28,"Cell", 29,"Link", 32,"List", 33,"ListItem", 34,"Outline",
    35,"OutlineItem", 36,"PageTab", 39,"Graphic", 40,"StaticText", 41,"Text",
    42,"PushButton", 43,"CheckButton", 44,"RadioButton", 45,"ComboBox",
    50,"Slider", 59,"PageTabList"
)

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

    acc := GetRootAccessible(hwnd)
    if !acc {
        Send "{Alt Up}"
        ShowResult("AccessibleObjectFromWindow failed.`nClass: " cls)
        return
    }

    rects := []
    treeDump := ""
    walkErr := ""
    try {
        treeDump := WalkAcc(acc, 0, 4, rects)
    } catch as e {
        walkErr := e.Message
    }

    Send "{Alt Up}"

    out := "Class:        " cls "`n"
    if (walkErr != "")
        out .= "Walk error:   " walkErr "`n"
    out .= "Total items:  " rects.Length "`n"

    if rects.Length {
        SortRectsByCy(rects)
        rows := [[rects[1]]]
        Loop rects.Length - 1 {
            r := rects[A_Index + 1]
            last := rows[rows.Length]
            if (Abs(r.cy - last[1].cy) <= 30)
                last.Push(r)
            else
                rows.Push([r])
        }
        maxCols := 0
        for row in rows
            if (row.Length > maxCols)
                maxCols := row.Length

        out .= "Rows:         " rows.Length "`n"
        out .= "Max cols:     " maxCols "`n"
        out .= "─────────────────────────`n"
        for i, row in rows
            out .= "Row " (i - 1) ": " row.Length " item(s)  (y≈" row[1].cy ")`n"
    }

    out .= "─────────────────────────`n"
    out .= "MSAA tree (top 4 levels):`n`n"
    out .= treeDump

    ShowResult(out)
}

GetRootAccessible(hwnd) {
    global IID_IAccessible, OBJID_CLIENT
    iid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "WStr", IID_IAccessible, "Ptr", iid)
    pAcc := 0
    hr := DllCall("oleacc\AccessibleObjectFromWindow"
                , "Ptr",  hwnd
                , "UInt", OBJID_CLIENT
                , "Ptr",  iid
                , "Ptr*", &pAcc, "Int")
    if (hr != 0 || !pAcc)
        return 0
    return ComObjFromPtr(pAcc)
}

WalkAcc(acc, depth, maxDepth, rects) {
    global ROLE_NAMES

    indent := ""
    Loop depth
        indent .= "  "

    role := "?"
    try {
        roleId := acc.accRole(0)  ; CHILDID_SELF = 0
        if IsNumber(roleId)
            role := ROLE_NAMES.Has(roleId) ? ROLE_NAMES[roleId] : "Role" roleId
    }

    name := ""
    try {
        n := acc.accName(0)
        if (Type(n) = "String")
            name := n
    }

    l := 0, t := 0, w := 0, h := 0
    try acc.accLocation(&l, &t, &w, &h, 0)

    displayName := name
    if (StrLen(displayName) > 40)
        displayName := SubStr(displayName, 1, 37) "..."

    line := indent role " : " (name = "" ? "(no name)" : "'" displayName "'") "  [" w "x" h "]`n"

    if (w > 50 && h > 50)
        rects.Push({l:l, t:t, r:l+w, b:t+h, cx:l+w//2, cy:t+h//2, name:name, role:role})

    if (depth >= maxDepth)
        return line

    cnt := 0
    try cnt := acc.accChildCount
    if (!IsNumber(cnt) || cnt <= 0)
        return line

    Loop cnt {
        i := A_Index
        try {
            child := acc.accChild(i)
            if IsObject(child)
                line .= WalkAcc(child, depth + 1, maxDepth, rects)
        }
    }

    return line
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
    g := Gui("+AlwaysOnTop +Resize", "MSAA Probe")
    g.SetFont("s10", "Consolas")
    g.AddText(, text)
    g.AddButton("Default w80", "OK").OnEvent("Click", (*) => g.Destroy())
    g.Show()
}
