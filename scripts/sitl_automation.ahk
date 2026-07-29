#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================
; ArduPilot SITL Simulation Automation Script
; ============================================

; ----- VJOY CONFIGURATION -----
global VJOY_DEVICE_ID := 1          ; vJoy device number
global VJOY_DLL_PATH := "C:\Program Files\vJoy\x64\vJoyInterface.dll"

; Button mappings (vJoy button numbers)
global BTN_ARM := 3                 ; Arm
global BTN_DISARM := 2	            ; Disarm
global BTN_QLOITER := 6             ; QLoiter mode
global BTN_LOITER := 4              ; Loiter mode
global BTN_RTL := 1                 ; RTL mode

; Axis configuration
; vJoy axis range is typically 1-32767 (0x1 to 0x7FFF)
global AXIS_MIN := 1
global AXIS_CENTER := 16384
global AXIS_MAX := 32767

; Timing configuration (in milliseconds)
global THROTTLE_HOLD_TIME := 5000   ; 5 seconds
global LOITER_WAIT_TIME := 40000    ; 40 seconds
global LAND_WAIT_TIME := 300000     ; 5 minutes
global BUTTON_PRESS_TIME := 200     ; How long to hold a button press

; Window title for RealFlight
global REALFLIGHT_WINDOW := "RealFlight Evolution"

; ----- VJOY DLL INTERFACE -----
class VJoy {
    static hDLL := 0
    static initialized := false

    ; Initialize vJoy
    static Init() {
        if (this.initialized)
            return true

        ; Load the DLL
        try {
            this.hDLL := DllCall("LoadLibrary", "Str", VJOY_DLL_PATH, "Ptr")
            if (!this.hDLL) {
                MsgBox("Failed to load vJoyInterface.dll`nCheck VJOY_DLL_PATH in script.")
                return false
            }
        } catch as err {
            MsgBox("Error loading vJoy DLL: " . err.Message)
            return false
        }

        ; Check if vJoy is enabled
        if (!this.vJoyEnabled()) {
            MsgBox("vJoy is not enabled. Run 'Configure vJoy' and enable a device.")
            return false
        }

        ; Acquire the device
        if (!this.AcquireDevice(VJOY_DEVICE_ID)) {
            MsgBox("Failed to acquire vJoy device " . VJOY_DEVICE_ID)
            return false
        }

        ; Reset all controls to default
        this.ResetDevice(VJOY_DEVICE_ID)

        this.initialized := true
        return true
    }

    ; Check if vJoy driver is enabled
    static vJoyEnabled() {
        return DllCall(VJOY_DLL_PATH . "\vJoyEnabled", "Int")
    }

    ; Acquire vJoy device
    static AcquireDevice(deviceId) {
        return DllCall(VJOY_DLL_PATH . "\AcquireVJD", "UInt", deviceId, "Int")
    }

    ; Relinquish vJoy device
    static RelinquishDevice(deviceId) {
        DllCall(VJOY_DLL_PATH . "\RelinquishVJD", "UInt", deviceId)
    }

    ; Reset device to default state
    static ResetDevice(deviceId) {
        DllCall(VJOY_DLL_PATH . "\ResetVJD", "UInt", deviceId, "Int")
    }

    ; Set button state (1 = pressed, 0 = released)
    static SetButton(state, deviceId, buttonNum) {
        return DllCall(VJOY_DLL_PATH . "\SetBtn", "Int", state, "UInt", deviceId, "UChar", buttonNum, "Int")
    }

    ; Set axis value (axisId: HID_USAGE values)
    ; Common axis IDs: X=0x30, Y=0x31, Z=0x32, RX=0x33, RY=0x34, RZ=0x35
    static SetAxis(value, deviceId, axisId) {
        return DllCall(VJOY_DLL_PATH . "\SetAxis", "Int", value, "UInt", deviceId, "UInt", axisId, "Int")
    }

    ; Cleanup
    static Cleanup() {
        if (this.initialized) {
            this.ResetDevice(VJOY_DEVICE_ID)
            this.RelinquishDevice(VJOY_DEVICE_ID)
            this.initialized := false
        }
    }
}

; HID Usage values for axes
class HID_USAGE {
    static X  := 0x30
    static Y  := 0x31
    static Z  := 0x32  ; Often used for throttle
    static RX := 0x33
    static RY := 0x34
    static RZ := 0x35
    static SL0 := 0x36  ; Slider 0
    static SL1 := 0x37  ; Slider 1
}

; ----- HELPER FUNCTIONS -----

; Press and release a vJoy button
PressButton(buttonNum, holdTime := 200) {
    VJoy.SetButton(1, VJOY_DEVICE_ID, buttonNum)  ; Press
    Sleep(holdTime)
    VJoy.SetButton(0, VJOY_DEVICE_ID, buttonNum)  ; Release
    Sleep(100)  ; Brief delay after release
}

; Set throttle (Y axis) to a specific value
SetThrottle(value) {
    VJoy.SetAxis(value, VJOY_DEVICE_ID, HID_USAGE.Y)
}

; Gradually change throttle over time (smooth transition)
RampThrottle(startVal, endVal, duration_ms) {
    steps := 50
    stepDelay := duration_ms // steps
    stepSize := (endVal - startVal) / steps

    currentVal := startVal
    Loop steps {
        currentVal += stepSize
        SetThrottle(Round(currentVal))
        Sleep(stepDelay)
    }
    SetThrottle(endVal)  ; Ensure we hit exact target
}

; Send key to RealFlight window
SendToRealFlight(key) {
    try {
        WinActivate(REALFLIGHT_WINDOW)
        Sleep(200)
        Send(key)
    } catch as err {
        LogStep("Error sending to RealFlight: " . err.Message)
    }
}

; Wait with progress indicator
WaitWithProgress(duration_ms, label) {
    start_time := A_TickCount
    end_time := start_time + duration_ms

    while (A_TickCount < end_time) {
        remaining := (end_time - A_TickCount) // 1000
        ToolTip(label . ": " . remaining . "s remaining")
        Sleep(1000)
    }
}

; Log step to tooltip
LogStep(message) {
    ToolTip(message)
    ; Uncomment to log to file:
    ; FileAppend(A_Now . " - " . message . "`n", "sitl_log.txt")
}

; ----- MAIN SEQUENCE -----
RunSimulationSequence() {
    ; Initialize vJoy
    if (!VJoy.Init()) {
        MsgBox("Failed to initialize vJoy. Aborting.")
        return
    }

    LogStep("Starting SITL Automation Sequence...")
    Sleep(1000)

    ; Step 1: Arm
    LogStep("Step 1: Arming...")
    PressButton(BTN_ARM, BUTTON_PRESS_TIME)
    Sleep(1000)

    ; Step 2: QLoiter mode
    LogStep("Step 2: Switching to QLoiter mode...")
    PressButton(BTN_QLOITER, BUTTON_PRESS_TIME)
    Sleep(1000)

    ; Step 3: Throttle to max for 5 seconds
    LogStep("Step 3: Increasing altitude (throttle max for 5s)...")
    SetThrottle(AXIS_MAX)
    WaitWithProgress(THROTTLE_HOLD_TIME, "Throttle up")
    SetThrottle(AXIS_CENTER)  ; Return to center/neutral
    Sleep(500)

    ; Step 4: Loiter mode
    LogStep("Step 4: Switching to Loiter mode...")
    PressButton(BTN_LOITER, BUTTON_PRESS_TIME)
    Sleep(1000)

    ; Step 5: Wait 40 seconds
    LogStep("Step 5: Waiting 40 seconds in Loiter...")
    WaitWithProgress(LOITER_WAIT_TIME, "Loiter wait")

    ; Step 6: RTL mode
    LogStep("Step 6: Switching to RTL mode...")
    PressButton(BTN_RTL, BUTTON_PRESS_TIME)
    Sleep(1000)

    ; Step 7: Wait 5 minutes for landing
    LogStep("Step 7: Waiting 5 minutes for landing...")
    WaitWithProgress(LAND_WAIT_TIME, "Landing wait")

    ; Step 8: Reset simulation in RealFlight
    LogStep("Step 8: Resetting simulation...")
    SendToRealFlight("{Space}")
    Sleep(2000)

    ; Done
    LogStep("Sequence complete!")
    Sleep(3000)
    ToolTip()
}

; ----- HOTKEYS -----

; F12: Start the automation sequence
; F12::RunSimulationSequence()

; F11: Test vJoy connection
F11::{
    if (VJoy.Init()) {
        MsgBox("vJoy initialized successfully!`nDevice " . VJOY_DEVICE_ID . " acquired.")
    }
}

; F10: Test button press (press button 1)
F10::{
    if (VJoy.Init()) {
        ToolTip("Pressing button 1...")
        PressButton(1, 500)
        ToolTip("Button 1 released")
        Sleep(1000)
        ToolTip()
    }
}

; F9: Test throttle
F9::{
    if (VJoy.Init()) {
        ToolTip("Throttle to MAX")
        SetThrottle(AXIS_MAX)
        Sleep(2000)
        ToolTip("Throttle to CENTER")
        SetThrottle(AXIS_CENTER)
        Sleep(2000)
        ToolTip("Throttle to MIN")
        SetThrottle(AXIS_MIN)
        Sleep(2000)
        SetThrottle(AXIS_CENTER)
        ToolTip()
    }
}

; Escape: Cleanup and exit
Esc::{
    VJoy.Cleanup()
    ExitApp()
}

; Cleanup on script exit
OnExit(ExitFunc)
ExitFunc(ExitReason, ExitCode) {
    VJoy.Cleanup()
}

; ----- AUTO-START -----
RunSimulationSequence()
