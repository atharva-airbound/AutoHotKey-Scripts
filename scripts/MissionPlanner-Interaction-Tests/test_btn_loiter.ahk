#Requires AutoHotkey v2.0
#SingleInstance Force

; Test script for LOITER button (Button 4)
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
ToolTip("Pressing LOITER (Button 4)...")
PressButton(4)
ToolTip("LOITER button released")
Sleep(1000)
DllCall(VJOY_DLL_PATH . "\RelinquishVJD", "UInt", VJOY_DEVICE_ID)
ExitApp()
