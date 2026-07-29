#Requires AutoHotkey v2.0
#SingleInstance Force

; Test script for THROTTLE (Y axis)
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
    DllCall(VJOY_DLL_PATH . "\SetAxis", "Int", value, "UInt", VJOY_DEVICE_ID, "UInt", HID_USAGE_Y, "Int")
}

VJoyInit()

ToolTip("Throttle: MIN")
SetThrottle(AXIS_MIN)
Sleep(2000)

ToolTip("Throttle: CENTER")
SetThrottle(AXIS_CENTER)
Sleep(2000)

ToolTip("Throttle: MAX")
SetThrottle(AXIS_MAX)
Sleep(2000)

ToolTip("Throttle: CENTER (reset)")
SetThrottle(AXIS_CENTER)
Sleep(1000)

DllCall(VJOY_DLL_PATH . "\RelinquishVJD", "UInt", VJOY_DEVICE_ID)
ToolTip()
ExitApp()
