; Joystick Monitor Script for AHK v2
#Requires AutoHotkey v2.0

; Create a GUI to display joystick info
MyGui := Gui()
MyGui.Title := "Joystick Monitor"
MyGui.SetFont("s10", "Consolas")

; Add text controls for each axis and button
InfoText := MyGui.Add("Text", "w400 h400", "Monitoring joystick...")

MyGui.Show()

; Monitor joystick continuously
SetTimer(UpdateJoystickInfo, 50)

UpdateJoystickInfo() {
    global InfoText
    
    ; Build the info string
    info := "=== JOYSTICK VALUES ===`n`n"
    
    ; Check axes (X, Y, Z, R, U, V)
    info .= "X-Axis: " GetKeyState("JoyX") "`n"
    info .= "Y-Axis: " GetKeyState("JoyY") "`n"
    info .= "Z-Axis: " GetKeyState("JoyZ") "`n"
    info .= "R-Axis: " GetKeyState("JoyR") "`n"
    info .= "U-Axis: " GetKeyState("JoyU") "`n"
    info .= "V-Axis: " GetKeyState("JoyV") "`n"
    
    ; POV (D-pad)
    info .= "`nPOV: " GetKeyState("JoyPOV") "`n"
    
    ; Check buttons (most joysticks have 1-32 buttons)
    info .= "`nBUTTONS:`n"
    Loop 32 {
        if GetKeyState("Joy" A_Index) {
            info .= "Button " A_Index " is PRESSED`n"
        }
    }
    
    InfoText.Value := info
}

; Press Escape to close
Esc::ExitApp
