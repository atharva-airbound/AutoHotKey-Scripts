#Requires AutoHotkey v2.0
#SingleInstance Force

; vJoy Diagnostic Script
global VJOY_DLL_PATH := "C:\Program Files\vJoy\x64\vJoyInterface.dll"

Main()

Main() {
    result := "=== vJoy Diagnostic Report ===`n`n"

    ; Step 1: Check if DLL exists
    if (!FileExist(VJOY_DLL_PATH)) {
        result .= "ERROR: vJoyInterface.dll not found at:`n" . VJOY_DLL_PATH . "`n`n"
        result .= "Check if vJoy is installed, or update VJOY_DLL_PATH in script.`n"
        result .= "Common locations:`n"
        result .= "  - C:\Program Files\vJoy\x64\vJoyInterface.dll`n"
        result .= "  - C:\Program Files\vJoy\x86\vJoyInterface.dll`n"
        MsgBox(result)
        return
    }
    result .= "DLL found: OK`n"

    ; Step 2: Load DLL
    try {
        hDLL := DllCall("LoadLibrary", "Str", VJOY_DLL_PATH, "Ptr")
        if (!hDLL) {
            result .= "ERROR: Failed to load DLL`n"
            MsgBox(result)
            return
        }
        result .= "DLL loaded: OK`n"
    } catch as err {
        result .= "ERROR loading DLL: " . err.Message . "`n"
        MsgBox(result)
        return
    }

    ; Step 3: Check if vJoy is enabled
    enabled := DllCall(VJOY_DLL_PATH . "\vJoyEnabled", "Int")
    if (!enabled) {
        result .= "`nERROR: vJoy driver is NOT enabled!`n`n"
        result .= "FIX: Run 'Configure vJoy' from Start Menu and enable at least one device.`n"
        MsgBox(result)
        return
    }
    result .= "vJoy enabled: OK`n`n"

    ; Step 4: Check device status for devices 1-4
    result .= "=== Device Status ===`n"
    Loop 4 {
        deviceId := A_Index
        status := DllCall(VJOY_DLL_PATH . "\GetVJDStatus", "UInt", deviceId, "Int")
        statusText := GetStatusText(status)
        result .= "Device " . deviceId . ": " . statusText . "`n"
    }

    result .= "`n=== Recommendation ===`n"

    ; Find first free device
    freeDevice := 0
    Loop 4 {
        status := DllCall(VJOY_DLL_PATH . "\GetVJDStatus", "UInt", A_Index, "Int")
        if (status = 0) {  ; VJD_STAT_OWN - already owned by this app
            freeDevice := A_Index
            result .= "Device " . A_Index . " is already acquired by this process.`n"
            break
        }
        if (status = 1) {  ; VJD_STAT_FREE
            freeDevice := A_Index
            result .= "Device " . A_Index . " is FREE and available.`n"
            break
        }
    }

    if (freeDevice = 0) {
        result .= "`nNo free devices found!`n"
        result .= "Close any applications using vJoy (Mission Planner, other AHK scripts, etc.)`n"
    }

    MsgBox(result)
}

GetStatusText(status) {
    switch status {
        case 0: return "VJD_STAT_OWN (owned by this app)"
        case 1: return "VJD_STAT_FREE (available)"
        case 2: return "VJD_STAT_BUSY (owned by another app)"
        case 3: return "VJD_STAT_MISS (not configured)"
        default: return "Unknown (" . status . ")"
    }
}
