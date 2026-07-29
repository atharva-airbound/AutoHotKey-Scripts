#Requires AutoHotkey v2.0
#SingleInstance Force

; Test script for DISARM button (Button 2)
global VJOY_DEVICE_ID := 1
global VJOY_DLL_PATH := "C:\Program Files\vJoy\x64\vJoyInterface.dll"

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

PressButton(btn, holdTime := 500) {
    DllCall(VJOY_DLL_PATH . "\SetBtn", "Int", 1, "UInt", VJOY_DEVICE_ID, "UChar", btn, "Int")
    Sleep(holdTime)
    DllCall(VJOY_DLL_PATH . "\SetBtn", "Int", 0, "UInt", VJOY_DEVICE_ID, "UChar", btn, "Int")
}

VJoyInit()
ToolTip("Pressing DISARM (Button 2)...")
PressButton(2)
ToolTip("DISARM button released")
Sleep(1000)
DllCall(VJOY_DLL_PATH . "\RelinquishVJD", "UInt", VJOY_DEVICE_ID)
ExitApp()
