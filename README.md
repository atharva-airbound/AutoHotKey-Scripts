# AutoHotkey scripts

Personal AutoHotkey v2 scripts for Windows 11. The always-on hotkey scripts are
merged into a single process by `Startup.ahk`, which a logon-triggered scheduled
task launches; everything else is run by hand when needed.

## Repository root

| File | Purpose |
|------|---------|
| `Startup.ahk` | Entry point launched at logon — `#Include`s the always-on scripts so they share one process and one tray icon. |
| `Startup-Task.xml` | Export of the `AHK Startup Scripts` scheduled task that runs `Startup.ahk`; re-importable via Task Scheduler or `schtasks /create /xml`. |

### Startup setup

`Startup.ahk` is launched by a Task Scheduler task (`AHK Startup Scripts`) with an
at-logon trigger, rather than from the Startup folder. Explorer deliberately holds
Startup-folder shortcuts and then launches them serialized, which delayed these
scripts by minutes after boot; a logon-triggered task is not in that queue.

To recreate the task on a new machine, import `Startup-Task.xml` and fix the
`<Command>`/`<Arguments>`/`<UserId>` paths for that machine. Adding a script means
dropping it in `scripts/`, adding an `#Include`, and keeping its global and
function names distinct — after inclusion every included file shares one namespace.

## `scripts/` — always-on

Loaded by `Startup.ahk`. Each remains independently runnable for editing and testing.

| Script | One-liner |
|--------|-----------|
| `Mouse-Wheel.ahk` | Remaps the wheel while side/right buttons are held: XB2 = fast scroll, XB2+RB = zoom (Alt+wheel over Firefox, else Ctrl+wheel), RB = horizontal pan. |
| `MouseXB1-WindowSwipe.ahk` | Hold the lower side button to open Alt+Tab and steer the switcher grid with mouse motion; release commits the selection. |
| `Keyboard-Shortcuts.ahk` | Collected one-line keyboard overrides. Currently: Win+M minimizes only the active window instead of all of them. |

## `scripts/` — utilities

Run manually.

| Script | One-liner |
|--------|-----------|
| `sitl_automation.ahk` | Drives a full ArduPilot SITL flight through vJoy — arm, QLoiter, climb, Loiter, RTL, land, reset RealFlight — starting on launch. |
| `UIA.ahk` | Vendored third-party UI Automation library ([Descolada/UIA-v2](https://github.com/Descolada/UIA-v2)) — a dependency of the UIA probe, not a script to run. |

## `scripts/` — Alt+Tab layout probes

Throwaway investigation tools for reading the Win11 Alt+Tab grid geometry, kept
because each rules out a different approach. See `ALT-TAB-LAYOUT-DETECTION.md` for
the problem statement and findings.

| Script | One-liner |
|--------|-----------|
| `Probe-GetAltTabInfo.ahk` | F8 — tests whether the Win32 `GetAltTabInfo` API still reports switcher row/column counts on this Windows build. |
| `Probe-MSAA-AltTab.ahk` | F8 — walks the switcher's MSAA tree via IDispatch and clusters tile rects by Y-center to infer the grid. |
| `Probe-UIA-AltTab.ahk` | F8 — same clustering via UI Automation (needs `UIA.ahk`); this is the probe that poisoned the XAML switcher host after one `FindAll`. |
| `Probe-UIA-Python.py` | Retries the UIA approach from Python (MTA + cache requests) to test whether apartment model or provider touch count causes that poisoning. |
| `Probe-Pixel-AltTab.py` | Screen-capture fallback — finds the panel and tile blobs from pixels alone, touching no accessibility API. |

Both Python probes declare inline PEP 723 dependencies; run them with `uv run <file>`.

A `Probe-Pixel-AltTab.py` run drops `alttab_capture.png` (the input frame) and
`alttab_panelmask.png` (the derived panel mask) beside the script. These are
regenerable output and are kept out of the repo, so expect them to be absent in a
fresh clone — re-run the probe if you need them.

## `scripts/MissionPlanner-Interaction-Tests/`

Manual harnesses for checking that a vJoy control reaches the flight stack before
debugging `sitl_automation.ahk`. Work down the table: confirm vJoy itself is
healthy, watch what the driver actually emits, then exercise one control at a time.

The two tools are interactive; the `test_*` scripts are not — each acquires vJoy
device 1, acts immediately on launch, then exits, with no hotkeys.

| Script | One-liner |
|--------|-----------|
| `vjoy_diagnose.ahk` | Reports whether the vJoy DLL loads, the driver is enabled and device 1 can be acquired; run this first when vJoy misbehaves. |
| `JoystickMonitor.ahk` | Live GUI readout of all joystick axes, POV hat and 32 buttons; Esc exits. Use it to see whether a `test_*` script's output actually lands. |
| `test_btn_arm.ahk` | Pulses vJoy button 3 (Arm). |
| `test_btn_disarm.ahk` | Pulses vJoy button 2 (Disarm). |
| `test_btn_loiter.ahk` | Pulses vJoy button 4 (Loiter mode). |
| `test_btn_qloiter.ahk` | Pulses vJoy button 6 (QLoiter mode). |
| `test_btn_rtl.ahk` | Pulses vJoy button 1 (RTL mode). |
| `test_throttle.ahk` | Steps the throttle axis min → center → max → center, 2s apart, with a tooltip at each step. |
| `test_throttle_debug.ahk` | Same sweep with verbose reporting, to confirm axis writes are actually applied. |

## Requirements

- AutoHotkey v2 (`#Requires AutoHotkey v2.0` in every script).
- vJoy with device 1 configured, for `sitl_automation.ahk` and the interaction
  tests. They hardcode `C:\Program Files\vJoy\x64\vJoyInterface.dll`; edit
  `VJOY_DLL_PATH` if yours differs.
- `uv` (or `pip`) for the two Python probes.
