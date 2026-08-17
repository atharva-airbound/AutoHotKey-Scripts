#Requires AutoHotkey v2.0
#SingleInstance Force

; Single entry point for the always-on scripts, launched at logon by the scheduled
; task "AHK Startup Scripts" (exported alongside this file as Startup-Task.xml).
; Merging them into one process is purely so there's ONE tray icon instead of one
; per script — AHK v2's auto-execute thread
; runs straight through every #Include, so each included file's top-level setup
; code, timers and #HotIf contexts all still run exactly as they do when the file
; is launched on its own.
;
; The files under scripts\ are included, not duplicated, so each stays
; independently runnable for editing/testing. Keep their global and function
; names distinct — after inclusion they share one namespace.
;
; #Include paths are written against %A_ScriptDir% (this file's directory) rather
; than left relative, so the includes resolve the same no matter what working
; directory the launching task or shell happens to hand us.

#Include %A_ScriptDir%\scripts\Mouse-Wheel.ahk

; Defensive: #HotIf context carries across #Include boundaries, so reset it here
; rather than trusting every included file to close its own contexts.
#HotIf

#Include %A_ScriptDir%\scripts\MouseXB1-WindowSwipe.ahk

#HotIf

#Include %A_ScriptDir%\scripts\Keyboard-Shortcuts.ahk

#HotIf

; Tray icon: a plain gear — deliberately generic, so it stays apt as scripts
; beyond the current mouse ones get included here. Checked at the tray's actual
; 16x16: it stays legible on both light and dark taskbars, which several
; better-looking candidates (wscript's scroll, shell32's document+gear) do not.
;
; TraySetIcon's IconNumber is 1-BASED, unlike the 0-based index that icon-browsing
; tools (and ExtractIconEx) report — so an index copied from elsewhere lands you
; one icon off, and the neighbours here are unrelated, not near-misses. If you
; change this, confirm it by eye at 16x16 rather than trusting the number.
TraySetIcon A_WinDir "\System32\shell32.dll", 315

; Without this the tray entry just reads "Startup.ahk", which says nothing about
; which hotkeys are live. Keep the second line in sync with the #Include list.
A_IconTip := "AHK Startup Scripts`nMouse-Wheel + MouseXB1-WindowSwipe + Keyboard-Shortcuts"
