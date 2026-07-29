#Requires AutoHotkey v2.0
#SingleInstance Force

; Debug script to test throttle changes and verify they're applied
global VJOY_DEVICE_ID := 1
global VJOY_DLL_PATH := "C:\Program Files\vJoy\x64\vJoyInterface.dll"
global HID_USAGE_Y := 0x31

global AXIS_MIN := 1
global AXIS_CENTER := 16384
global AXIS_MAX := 32767

VJoyInit() {
    DllCall("LoadLibrary", "Str", VJOY_DLL_PATH, "Ptr")
    if (!DllCall(VJOY_DLL_PATH . "\vJoyEnabled", "Int")) {
        MsgBox("vJoy not enabled!")
        ExitApp()
    }
    if (!DllCall(VJOY_DLL_PATH . "\AcquireVJD", "UInt", VJOY_DEVICE_ID, "Int")) {
        MsgBox("Failed to acquire vJoy device!")
        ExitApp()
    }
    DllCall(VJOY_DLL_PATH . "\ResetVJD", "UInt", VJOY_DEVICE_ID, "Int")
}

SetThrottle(value) {
    result := DllCall(VJOY_DLL_PATH . "\SetAxis", "Int", value, "UInt", VJOY_DEVICE_ID, "UInt", HID_USAGE_Y, "Int")
    return result
}

VJoyInit()

; Test sequence with explicit result checking
MsgBox("Starting throttle debug test.`nWatch the vJoy Monitor or Mission Planner joystick display.")

result := SetThrottle(AXIS_MAX)
MsgBox("Set to MAX (32767)`nSetAxis returned: " . result . "`n`nIs throttle at MAX in Mission Planner?")

result := SetThrottle(AXIS_CENTER)
MsgBox("Set to CENTER (16384)`nSetAxis returned: " . result . "`n`nDid throttle move to CENTER?")

result := SetThrottle(AXIS_MIN)
MsgBox("Set to MIN (1)`nSetAxis returned: " . result . "`n`nDid throttle move to MIN?")

result := SetThrottle(AXIS_CENTER)
MsgBox("Set back to CENTER (16384)`nSetAxis returned: " . result . "`n`nTest complete.")

DllCall(VJOY_DLL_PATH . "\RelinquishVJD", "UInt", VJOY_DEVICE_ID)
ExitApp()
