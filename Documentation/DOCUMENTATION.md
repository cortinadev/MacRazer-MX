# MacRazer MX: Documentation

A native macOS menu bar app to control Razer mice: battery, DPI, polling rate, RGB lighting,
brightness, and software button remapping. Razer's Synapse does not support macOS, so this
app talks to the mouse directly over USB HID. The Razer Cobra HyperSpeed is the development
mouse; others have been verified from user reports. By design it detects and tries to control
any Razer mouse in the same protocol family. The registry (`RazerDevices.known`) lists every
product id it knows, and README's table says which of them anyone has actually run the probes
against, and how far.

**This is the documentation of MacRazer MX**, a fork of SorcRR's
[MacRazer](https://github.com/SorcRR/MacRazer) (fork: `github.com/cortinadev/MacRazer-MX`, branch
`feature/mx-gestures-dpi` at the time of writing). It was written for upstream's app, and what
the fork changes is described where it applies, in §6.3 (gesture mode, the DPI button),
§6.7 (updates are off), §7 (a different bundle ID, so permissions are separate) and the file map
in §10. The short version of the fork's differences:

- **Identity.** App and bundle "MacRazer MX", bundle ID `com.cortinadev.macrazer-mx`,
  Application Support folder "MacRazer MX", so it installs next to upstream's MacRazer. The two
  must not *run* together: both talk to the mouse and install event taps. The SwiftPM target
  and the executable inside the bundle are still `MacRazer`, to keep upstream merges simple.
- **No network features.** `AppInfo.updatesEnabled` is `false` and `WorkerEndpoint.base` is
  always `nil`, so there are no update checks, usage counts, crash, issue or device reports
  (§6.4 to §6.7 and §6.9 describe upstream's behaviour, which is dormant here). Where upstream
  gives an email address, `ProjectLinks.contact` and `ProjectLinks.newIssue(title:body:)` point
  to the fork's GitHub issues.
- **Additions.** Gesture mode and a wider DPI button remap (§6.3).
- On a real Cobra HyperSpeed over Bluetooth, the DPI button's remap (§6.3.3) has been run, and
  so have the mouse's driver mode and the two private keys it reports the button as: first
  captured with the gesture trace, then used through the product code path (hold and swipe,
  the short press doing Click, the software DPI cycle one stage per press, the periodic check
  over about an hour, normal mode restored at quit). Re-arming after the mouse sleeps was fixed
  from a hardware trace (§6.3.3, the driver mode lifecycle), and the fix has not been re-tried
  on the mouse. The Hold slot, App Exposé and the side-button gesture have only unit tests.

This document explains how the app is built and how every feature works, so a future Claude
session or a human can pick it up cold. See also:
- [`BRIEF.md`](BRIEF.md), the original research/planning brief and device facts.
- [`../CHANGELOG.md`](../CHANGELOG.md), feature list / history.
- [`../README.md`](../README.md), quick status + build commands.

---

## 1. Overview & how it works at a glance

The mouse speaks Razer's proprietary HID protocol. We did **not** reverse-engineer it from
scratch, we **ported the protocol from OpenRazer's Linux driver** (the Cobra Pro command
set, which the Cobra HyperSpeed reuses). All command bytes were read from the OpenRazer C
source and reimplemented in Swift over Apple's IOKit HID Manager. No kernel extension is
required: Razer mice respond to standard USB HID **feature reports** that any HID-capable
userspace process can send.

```
Razer mouse  <-- HID feature reports (90-byte razer_report) -->  HIDDevice (IOKit)
                                                                       |
                                                  RazerCommands (builds the command bytes)
                                                                       |
                                                  MouseController (poll loop, battery, state)
                                                                       |
                                                  SwiftUI popover / menu bar (NSStatusItem)
```

The app is a SwiftPM **executable** (not an Xcode project). With **no arguments** it launches
the menu bar app; with a subcommand it runs a CLI diagnostic (see §9).

---

## 2. Quick start

Requires macOS 14+ (Apple Silicon), Xcode 16 / Swift 6.1.

```sh
# Develop (inherits your Terminal's permission grants, easiest loop):
swift run MacRazer

# Build a standalone .app:
./Scripts/setup-signing.sh # one-time: stable self-signed identity (see §7)
./Scripts/build-app.sh # to "MacRazer MX.app" (the space means every use is quoted)
open "MacRazer MX.app"
```

**Permissions** (see §7): the app needs **Input Monitoring** (to send/receive HID reports)
and, for button remapping or scroll reversal, **Accessibility** (for the event tap). Both are requested in-app.

---

## 3. The HID protocol (ported from OpenRazer)

### 3.1 The wire format, `razer_report` (90 bytes)
Every command is a fixed 90-byte structure sent as a HID **feature report, report id 0**.
Ported in [`RazerReport.swift`](../Sources/MacRazer/RazerReport.swift):

| Offset | Field | Notes |
|---|---|---|
| 0 | status | response: `0x02` success, `0x01` busy, `0x03` failure, `0x04` timeout |
| 1 | transaction_id | **`0x1f` for all Cobra Pro/HyperSpeed commands** |
| 2-3 | remaining_packets | big-endian, usually 0 |
| 4 | protocol_type | 0 |
| 5 | data_size | size of the arguments used |
| 6 | command_class | |
| 7 | command_id | direction bit: get = `0x80\|id` |
| 8-87 | arguments[80] | |
| 88 | crc | XOR of bytes 2..87 |
| 89 | reserved | 0 |

### 3.2 Request/response timing (critical)
`HIDDevice.send()` sends the request (SetReport), waits, then reads the response (GetReport). The wait is
**31 ms** (`RAZER_NEW_MOUSE_RECEIVER_WAIT_US` in OpenRazer). Too short a wait returns status
`0x01` (BUSY) with empty arguments. On BUSY we re-read a few times.

### 3.3 Command reference (verified on hardware)
Built in [`RazerCommands.swift`](../Sources/MacRazer/RazerCommands.swift). VID `0x1532`.

| Operation | class / id | data_size | Notes |
|---|---|---|---|
| Get battery | `0x07` / `0x80` | `0x02` | response `args[1]` is 0-255; `* 100 / 255` gives the %. |
| Get charging | `0x07` / `0x84` | `0x02` | response `args[1]` != 0 = charging. |
| Get / Set DPI | `0x04` / `0x85` / `0x05` | `0x07` | VARSTORE + big-endian x/y; clamp **100-45000** (arbitrary DPI). |
| Get / Set poll | `0x00` / `0x85` / `0x05` | `0x01` | 1000->`0x01`, 500->`0x02`, 125->`0x08` (basic set only). |
| Lighting effect | `0x0F` / `0x02` | varies | extended-matrix on **ZERO_LED (0x00)**; effect ids: none `0x00`, static `0x01`, breathing `0x02`, spectrum `0x03`, wave `0x04`. Breathing takes one colour (arg size `0x09`), two (`0x0C`) or none for random (`0x06`). |
| Get / Set brightness | `0x0F` / `0x84` / `0x04` | `0x03` | value 0-255. LED group is **per model** (`RazerDevices.brightnessLed`), never ZERO_LED — see quirk below. |

### 3.4 Hardware quirks (discovered by testing, important!)
- **Battery works over the 2.4 GHz dongle.** The OpenRazer PR author thought it didn't; the
 real fix was the 31 ms wait + targeting the correct interface.
- **Brightness lives on a different LED group than effects, and which one is per model.**
 Colors/effects are driven on ZERO_LED for every model so far, but brightness is not: the
 Cobra family answers only on `LOGO_LED` (0x04), while the Basilisk V3 X HyperSpeed — whose
 only lit zone is the scroll wheel — answers only on `SCROLL_LED` (0x01). Every other group
 returns status `0x03` (failure), so a wrong id is not a silent no-op: the brightness slider
 simply stops working. The id is a registry field (`RazerDevices.brightnessLed`, default
 `LOGO_LED`); `swift run MacRazer brightness` sweeps all four groups to find it on a new
 model. Both verified live.
- **Lighting is one group.** The "4 zones" in marketing aren't independently addressable;
 everything is driven together via ZERO_LED.
- **Transient garbage on reconnect.** Right after a USB reconnect the battery can read 0x00
 (0%) or 0xFF (100%) before settling. The controller distrusts these (see §5.1).
- **Two product IDs:** `0x00DA` (wired) and `0x00DB` (wireless dongle).

---

## 4. IOKit HID layer

### `HIDDevice.swift`
- `matchingDevices(vendorId:)` enumerates all HID interfaces for a vendor **without opening
 the manager** (opening the manager grabs the keyboard/mouse interfaces and yields
 `kIOReturnNotOpen` on SetReport, a bug we hit and fixed).
- `open(vendorId:)` picks the **control interface** with `HIDDeviceSelection`. It must carry a
 90-byte feature report (`MaxFeatureReportSize >= 90`). Devices are ranked first: a PID in the
 registry wins, then a device with a Mouse usage interface (`0x01`/`0x02`), then the lowest
 location. A device the registry doesn't know is skipped when its product string names a line
 that is never a mouse (`HIDDeviceSelection.nonMouseProductLines`: BlackWidow, Huntsman,
 Tartarus, Blade, Kraken and so on), so a Razer keyboard on its own isn't opened as the mouse.
 Within the winning device, a vendor usage page and the Mouse usage score highest. Exposes the
 device's `productID` and `productName` (from the USB product string).
- `razerMice()` lists the Razer mice plugged in by cable or dongle without opening anything, so
 it works before Input Monitoring. It matches interfaces whose *primary* usage is Mouse, then
 applies the same name filter. The device test and the support prompt use it to find a mouse
 the app can't open yet.
- `send()` / `sendWithRetry()` implement the request/response with the 31 ms wait, BUSY
 re-reads, and retry/backoff for the finicky wireless link.

### `HIDMonitor.swift`
IOKit **service** notifications (`IOServiceAddMatchingNotification`, matched + terminated)
for instant USB plug/unplug detection. It does **not** open the device, so it can't
interfere with the control-interface open. Fires `onAppear` / `onRemove` callbacks on the
main queue. (Polling, §5, is the fallback for the wireless-sleep case where the dongle stays
plugged in.)

### Bluetooth LE: `BLEProtocol.swift` + `BluetoothDevice.swift`
Over Bluetooth the mouse is a plain HID pointer (feature report size 1, no control
interface). Razer's control protocol lives in a separate **vendor GATT service**
(`52401523-F97C-7F90-0E7F-6C6F4E36DB1C`), reverse-engineered by @ungrav in #32 and confirmed
on the Cobra HyperSpeed (Bluetooth PID `0x00DC`, vendor `0x068E`).

- **Framing.** A request is a header `[id, payloadLength, 0, 0, class, command, arg, arg]`
 written to `…1524`, then the payload in 20-byte writes. The reply arrives as notifications
 on `…1525`: a header `[id, length, 0, 0, 0, 0, 0, status]` (status `02` ok, `03` failure,
 `05` not supported) followed by `length` payload bytes. The mouse also sends an
 unsolicited `01 … 03` frame when notifications are enabled, which the assembler skips.
- **Commands (verified on the Cobra HyperSpeed):** battery `05 81 00 01` (0-255, same scale
 as USB), serial `01 83 00 00` (the same serial as over the dongle), DPI stages get/set
 `0B 84 01 00` / `0B 04 01 00`, brightness get/set `10 85 01 <led>` / `10 05 01 <led>` (LOGO
 `04` on the Cobra, like USB), static colour `10 04 00 00`.
- **Stage table.** `[activeID, count]` then per stage `[id, x_lo, x_hi, y_lo, y_hi, 0, 0]`,
 ids from 1, little-endian. Replies drop the last reserved byte. There is no direct "set
 DPI", so selecting a DPI rewrites the table with a new active stage, then reads it back.
- **Device mode** (`BLEProtocol.DeviceMode`): read `01 82 00 00`, set `01 02 00 00` with the
 little-endian u16 `03 00` (driver) or `00 00` (normal). In normal mode the firmware acts on its
 special buttons; in driver mode it reports them to the host instead, as "private keys" in HID
 input report 4 (§6.3.3). The mode is volatile: the mouse is back in normal mode after it
 sleeps, reconnects or is switched off and on, and just after a wake the Cobra took it, read it
 back and then dropped it as it finished starting (§6.3.3). Only `DeviceMode` values can be
 built into the write (`BLEProtocol.deviceModeRequest(_:)`), and it is only ever sent to a
 mouse with `RazerDevices.dpiButtonPrivateKeys`. `BluetoothDevice.setDeviceMode(_:readFirst:)`
 reads first (so a mouse already in the mode isn't written), writes once and reads back,
 throwing `DeviceModeError` (`unreadable`: nothing written; `notTaken`; `notReadBack`) and
 never writing twice. `DPIStageTable.nextStage()` is the stage after the active one, the first
 after the last (nil with one stage), used by the software DPI cycle.
- `BLEProtocol` translates `RazerReport` requests and replies, so `MouseController` and the
 `RazerCommands` parsers are shared with USB. Commands without a BLE equivalent (polling
 rate, effects other than static) throw `notSupported`, and the popover hides them.
- **Link choice** (`MouseController.openTransport`): a cable wins. An idle dongle loses to a
 supported mouse on Bluetooth, because the mouse is on one wireless link at a time and the
 dongle would only time out. Detection runs on IOHID (`HIDDevice.bluetoothRazerMouse`), so
 CoreBluetooth and its permission prompt only appear for someone who has such a mouse.

---

## 5. The controller, `MouseController.swift`

The orchestrator and single source of UI truth (an `ObservableObject`). All blocking HID IO
runs on a serial `io` queue; `@Published` state is updated on the main queue via `publish`.

Published state: `connected`, `batteryPercent`, `charging`, `dpi`, `pollRate`, `brightness`,
`timeEstimate`, `statusText`, `deviceName`, `deviceSupported`, `deviceHasBattery`,
`isRefreshing`, `showPercentInMenuBar`.

### 5.1 Polling & connection logic
- **Adaptive self-rescheduling poll.** `BatteryPollStateMachine` holds the connection logic as a
 pure value type (no I/O, no clock), and `MouseController` feeds it each poll's outcome. The
 interval (`BatteryPollStateMachine.Cadence`):
 - **15 s** connected and idle; **4 s** while the pointer has been used in the last 30 s,
 because switching a mouse off happens with a hand on it and nothing on USB reports it.
 - **4 s** for up to 15 polls after a start, reconnect or first failure (settling).
 - **0.5 s** to confirm a failure the UI hasn't acted on yet, so a disconnect settles in about
 a second.
 - **15 s** once the mouse stays silent (asleep or off), instead of 4 s all night.
 - **120 s** with no Razer device enumerated at all. `HIDMonitor` normally catches the replug
 first, so this is only a safety net.
- **Wake-up signal**, `HIDInputWatcher.swift`: a mouse asleep behind its dongle looks the same
 as one that is off, and nothing fires when it wakes. The watcher listens for the mouse's own
 input reports (movement, clicks, wheel) without taking the device from the system and
 triggers an immediate poll. It never reports a disconnect, since silence proves nothing.
- **Instant plug/unplug** via `HIDMonitor` to `forceCheck()` (USB removal is definitive, so it
 marks offline immediately, bypassing the debounce).
- **2-failure debounce**: a single transient wireless timeout won't flap the UI to "offline".
- **Reconnect sanity checks** (fixes the 0%/100% jumps): a raw `0` reading is treated as
 "not ready" (keep last value, re-poll fast); and the first post-reconnect reading is
 rejected if it jumps >20% from the last trusted value (transient garbage) until confirmed.
- **Battery-less mice**: if `deviceHasBattery` is false (registry), a successful DPI read is
 the alive-check instead of a battery read, and the battery UI is hidden.

### 5.2 Connect/disconnect sounds
On a connection-state transition (after the first baseline poll), plays a system sound:
**Pop** on connect, **Submarine** on disconnect (`NSSound`, names are constants). Settings ›
General can turn them off (`connectionSoundsEnabled`).

### 5.3 Writes
`setDPI`, `setPollRate`, `setBrightness`, `setStatic/Breathing/Spectrum/Wave/LightingOff`, each
dispatches a command on the io queue and re-publishes the new value optimistically. While
the popover is open, `setPopoverVisible(true)` polls DPI/poll every 2 s so on-mouse changes
(e.g. the DPI-cycle button) reflect live.

### `BatteryHistory.swift`, time-until-empty estimate
- Logs `(timestamp, %)` samples to `~/Library/Application Support/MacRazer MX/battery-history.json`.
- Computes a discharge rate by **linear least-squares fit** over samples (needs >=5 samples,
 >=30 min span, >=3% measured drop before it's trusted, otherwise the coarse reading is
 noise and the estimate drifts).
- Persists a **learned discharge rate** (`learnedDischargeRate` in UserDefaults), blended
 (EMA) across sessions and charge cycles, so after a restart/recharge the estimate is
 available **immediately** instead of re-deriving for ~3 hours.
- The estimate is always labelled "(est.)".

### Battery extras
- **Discharge curve**, `DischargeCurveModel.swift`: a fuel gauge's percent isn't linear with
 time (a long plateau, then steep drops near full and empty). This learns how long the battery
 actually stays at each percent, one bucket per percent, counting only traversals it watched
 from start to end. Below a minimum number of traversals a bucket falls back to the rate
 estimate. Used for models with a `dischargeCurveModelKey` in the registry.
- **Charge cycles**, `ChargeCycleHistory.swift`: when `BatteryHistory` finishes a cycle (one
 charge to the next), a summary goes into a rolling log. It feeds the trend chart and the
 average battery life per charge. A cycle needs the same minimum span and drop as the rate fit.
- **Usage page**, `UsageGraphView.swift`: the popover's battery sub-page, opened from the chart
 button beside the percentage. It shows the current discharge curve (with the previous charge
 dimmed behind it), the discharge rate, time since the last full charge, and the cross-charge
 trend. It reads only the snapshots `MouseController` publishes on the main queue, never the
 history objects on the `io` queue.
- **Last reading**, `LastBatterySnapshotStore.swift`: the last trusted reading per mouse, kept
 apart from the history so the popover can show an explicitly stale value while the mouse is
 away. Saved at most every so often, and at once on sleep, quit and state changes. Mice not
 seen for a long time are dropped.
- **Low battery alert**, `LowBatteryNotifier.swift`: one notification ("Battery Low") per
 discharge when the battery drops below **15%**. It re-arms at **20%** or when charging starts
 (`Battery.lowThresholdPercent` / `lowRearmPercent` in `CardComponents.swift`).
 `LowBatteryAlertPolicy` is the pure part. A failed charging read counts as unknown, not as
 on battery, so a docked mouse that refuses commands around sleep doesn't get a false alert.
- **Storage**, `Persistence.swift`: battery history, charge cycles and the curve are each a
 versioned JSON file in `~/Library/Application Support/MacRazer MX/` (`StoreDirectory.default`;
 upstream uses `MacRazer`), written atomically and
 throttled. A format change bumps the version and the data is re-learned instead of failing
 to decode.

### `RazerDevices.swift`, device registry
Maps PID to a `RazerDeviceInfo`: name, `unverified` (the features still waiting for a
report; empty means `fullySupported`), `hasBattery`, `hasLighting`,
`maxDPI`, transaction ids, the link (`connection`), the header silhouette, and the discharge
curve key. The connected device's **name comes from its own USB product string** (works for
any Razer mouse); the registry adds what has been verified about the model. Unknown mice show their name +
"limited support". This is the extension point for universal support (see §8).

---

## 6. The UI

### 6.1 Menu bar, `AppDelegate.swift` + `MenuBarIcon.swift`
- `NSStatusItem` with a custom-drawn **outlined mouse icon** (vector, drawn in
 `MenuBarIcon.swift`; a template image that adapts to light/dark and **dims to 60% opacity
 when disconnected**) + the battery % text (hideable via a setting; hidden entirely for
 battery-less mice).
- **Left-click** opens the popover; **right-click / control-click** shows an `NSMenu`:
 About MacRazer, the status line, Open Controls, Refresh Now (⌘R), Configure Buttons…, Help
 Support This Mouse… (Test This Mouse… on a verified model), Setup & Permissions…, Settings…
 (⌘,), Check for Updates…, Leave a Tip…, Quit MacRazer (⌘Q). Items that need a connected
 mouse are disabled when offline.
- The popover is **pre-warmed** at launch so it opens instantly, and `animates = false`. Its
 look follows Settings › Appearance (§6.2).
- **Focus.** Opening the popover activates MacRazer so its controls answer the first click.
 Closing it hands focus back to the app the person was in (`PopoverFocusReturn.swift`, pure),
 unless a window of ours opened or the person already moved on.
- **One rule for "busy".** Every window conforms to `AppWindowPresenter` (`AppWindows.swift`),
 and `AppDelegate.isShowingAWindow` asks all of them. Automatic installs, the support prompt
 and the other windows that open on their own wait while any of them, the popover or the menu
 is up. A new window only has to conform to be counted.

### 6.2 Popover, `PopoverView.swift`
A **380 pt** wide navigable container (760 pt in two columns), as tall as its content, with a main page and sub-pages (colour, Buttons,
Usage, Profiles, What's new) and a push/pop slide animation; each page is a `ScrollView` (so
long content scrolls without resizing the popover):

- **Main page**, Control-Center-style frosted cards, each section its own tile. One column by
 default. Two columns (`PopoverLayout`) when Settings › Appearance › Two-column popover is on
 (`appearance.twoColumnPopover`), and always with more than one Razer device connected (the
 mouse and an accessory, or two accessories). In two columns the header, support, update and
 Bluetooth cards run across the top, and below them are two 303 pt columns: battery, DPI and
 the accessories on the left, the settings sections on the right. With no mouse, the no-mouse
 card takes the left column and the accessories move right. The Buttons page then fills the
 width in two columns (the permission banner or "press a button" hint and how remapping works on the left; the
 buttons, the DPI button and model notes on the right), and the colour page
 puts a 250 pt wheel beside the title, device line, a swatch with its hex code and the
 brightness slider. The other sub-pages are 440 pt wide, centred.
 - **Header card**: Razer logo (green) in a tinted tile + detected device name +
 connection state + status dot. Shows "No mouse connected" when none.
 - **Battery card**: a custom proportional **battery gauge** (fill tracks the exact %,
 colored green >=40% / orange <40% / red <15%), the big % number, a state-colored level
 bar, the time estimate, and a spinner-animated refresh button. Dims when offline.
 - **DPI card**: green slider (100-26000) + preset chips (400/800/1600/3200/6400) + a
 persisted **custom chip** (drag the slider to any value to save it; green-outlined).
 - **Settings sections**: the rest, each a compact card of its own, Control-Center style. Each
 shows its current value ("1000 Hz", "Static · 80%", "5 min", the active profile) and the
 settings rows expand in place, each on its own; which are open is remembered
 (`popoverExpandedSections` in UserDefaults). Rows a mouse can't use are left out.
 - **Polling rate**: segmented 125/500/1000 Hz, plus what the rate is good for.
 - **Lighting**: brightness slider (☀︎) + effect segmented (Static/Breathing/Spectrum/Wave/Off)
 + colour swatches (true red...pink) + a rainbow "custom" well that opens the colour wheel.
 The swatches show for Static and Breathing, and set the colour of whichever is on. Breathing
 uses one colour. Over Bluetooth only a static colour has a known command, so the effect
 picker is hidden there.
 Under Wave, a speed slider (tortoise to hare). The speed byte is `args[4]` of the wave
 command, lower is faster; `WaveSpeed` maps the slider geometrically to 0xC8...0x08, so the
 standard 0x28 sits in the middle and speed changes evenly along it. It can't be read back, so the last one set is kept (`mouseWaveSpeed`, and in
 a profile). Each accessory card has the same slider.
 - **Power Management** (Basilisk V3 X over Bluetooth): the sleep timer.
 - **Buttons**: opens the buttons page; shows how many buttons are remapped, or "Needs access"
 when saved remaps can't fire without Accessibility permission.
 - Offline, the section rows still open to show last-known settings; their controls and the
 Buttons page are disabled. A failed write turns that row's value red.
 - **Profiles**: quick-switch chips, "+" to save, "Manage Profiles…". A profile
 (`MouseProfile.swift`) is a named snapshot of DPI, polling rate, lighting and button remaps,
 stored per device (`ProfileStore`). The mouse's own profile button only cycles DPI stages in
 firmware and tells the app nothing, so switching is done from the popover
 (`MouseController.applyProfile`). The Profiles page (`ProfilesView.swift`) renames, sets
 active and deletes.
 - **Other Razer devices** (`AccessoryController.swift`, `AccessoryCard.swift`,
 `RazerAccessories.swift`): one card per Razer keyboard or mousepad MacRazer knows, independent
 of the mouse being connected. They sit in a recessed tray (a shade darker than the popover,
 hairline edge, a count by the heading) so they read as their own group. `Accessories.shared` lists one `AccessoryController` per unit
 (PID and LocationID), each with its own device handle and queue; two of the same model are
 two cards. Closed, a card is one line: a drawn keyboard or pad (`AccessoryIcon`, lit like
 the device: keys or the pad's edge in its colour, a rainbow for Spectrum and Wave, plain when
 off, unknown or left to Synapse, on a tile tinted the same), name, an "Untested" tag for an untried model, a
 colour dot and the effect. Clicking opens it; which are open is remembered per model
 (`popoverAccessoryExpanded.<pid>`), and a lone accessory starts open. Open, it has the mouse's
 brightness slider and an effect picker with the effects that model has (no Wave on the
 Goliathus pads); its colour swatches stay on screen under every effect (picking one switches
 to Static). On a tested model, an effect not yet seen working gets a line saying so. The effect
 can't be read back, so what MacRazer sets is saved per model (`keyboardLighting.<pid>`, the
 key keyboards had before pads joined) and none is shown picked until it has set one. The
 brightness is re-read whenever the popover opens, and a colour or effect change never resends
 it, so a keyboard's own brightness keys stick.
 - **Follow mouse** (in each card, while there's a mouse): that accessory follows lighting
 the person sets on the mouse (`MouseController.lightingChanges`), never values read from it.
 A pad without Wave runs the mouse's wave as Spectrum. The card then says "Following mouse".
 Saved per model (`accessoryFollowsMouse.<pid>`); a keyboard falls back on the old single
 `keyboardFollowsMouse`.
 - **Use MacRazer** (in each card, only while Razer Synapse runs): off by default, so Synapse
 keeps that accessory and MacRazer writes nothing to it. On, MacRazer puts its lighting on,
 and back on after a wake or reconnect. Saved per model (`accessoryLightingOwner.<pid>`).
 - The colour page names the device it sets once an accessory is plugged in, and goes back to
 the main page if that accessory is unplugged.
 - **Update card**: when a newer release is found, "Update & Restart" (or the DMG download)
 and a row that opens the **What's new** page (`WhatsNewPage.swift`). After an update, an
 "Updated to …" card until dismissed. See §6.7.
 - **Support card**: see §6.5.
 - Sub-pages that scroll are at least 560 pt tall, so a short (collapsed) main page doesn't squeeze
 them; the colour page keeps the main page's height.
 - The gear in the footer opens the Settings window (§6.8).
 - Live mouse-config sections **grey out + disable when disconnected** (battery stays
 readable; refresh stays active).
 - With **no mouse known at all** (none seen yet, or unplugged), the controls are replaced
 by one card that says how to connect and offers "Look Again" (or the Input Monitoring
 grant, when that's what is missing). A last battery reading is still shown if there is one.
 - Keyboard: **⌘R** refreshes, **⌘,** opens Settings, and **Esc** on any sub-page goes back
 one level instead of closing the popover (except while a key recording or a rename is in
 progress, where Esc cancels that).
 - Swatches, chips and the icon buttons carry VoiceOver labels and tooltips; chips and
 rows get a hover highlight.
 - **Scroll wheel on sliders** (`SliderScroll.swift`, `.scrollAdjusts`): while the pointer is
 over a slider, a local `NSEvent` monitor takes vertical scrolls. Up raises the value with
 the natural-scrolling inversion undone. A wheel notch is 1% of the range, rounded to the
 slider's own step and never finer (`SliderScroll.notch`: DPI 250, sleep timer 15 s); a
 trackpad moves in proportion (300 pt crosses the slider), momentum is ignored, and the value
 lands on the slider's step grid. The write goes out 0.3 s after scrolling stops, or when the pointer
 leaves.
- **Appearance**, `PopoverTheme.swift`: Settings › Appearance has a **Theme** (System, Dark,
 Light, Razer Green) and a **Glass effect** switch (off by default), stored as `appearance.theme` and
 `appearance.glass` in UserDefaults. `PopoverLook.resolve` turns theme, glass and the system's
 light or dark mode into one of six looks (light, dark or green glass; solid light #F5F5F7,
 dark #1C1C1E or green #0F1A11). Razer Green is always dark. A **Two-column popover** switch
 (off by default) widens the popover with only the mouse; see the main page above.
 - `AppDelegate` re-applies the look when the setting changes or macOS switches mode, including
 while the popover is open. The popover's appearance is always set explicitly: a nil one would
 follow the menu bar, which macOS tints from the wallpaper.
 - Solid colours and the green tint are painted by `PopoverBackdropView`, which sits in
 NSPopover's frame view just under the content. That view clips to the popover's outline, so
 the fill covers the arrow too. A SwiftUI background would leave the arrow glass. The green
 edge is a SwiftUI overlay on the body (radius 10, measured on macOS 26).
 - Windows get the same look (`AppearanceSettings.track`, `WindowBackdrop`): glass is an
 `NSVisualEffectView` with the popover's material, plus the same tint view, both in the
 window's frame view so the title bar matches; solid looks set the window's background colour.
 The title bar is transparent in every look. Only the popover gets the green edge.
 - Colours: `razerGreen` is the fill (the same in both modes); text and icons use
 `razerGreenText` (#23891A on light). Anything on a green fill uses `onRazerGreen`, a dark green,
 because white on #44D62C is only about 1.9:1. `razerGreenBright` (logo) and `bluetoothBlue`
 also adapt.
- **Colour page**, `ColorPickerPage.swift`: an inline **hue/saturation colour wheel** +
 brightness slider + live preview, applied to the mouse live (throttled). Replaces the old
 system `NSColorPanel`.
- **Buttons page**, `RemapView.swift` embedded (see §6.3).

### 6.3 Button remapping, `ButtonRemapper.swift` + `RemapView.swift`
**Software** remapping via a `CGEvent` tap (the onboard-remap protocol isn't in OpenRazer and
Razer's EULA forbids reverse-engineering it, see CHANGELOG / chat). The tap watches
`otherMouseDown/Up`; for a mapped button it **suppresses the original event and posts the
mapped action** (events the app itself posts are tagged with `ButtonRemapper.magic` and skipped
to avoid loops). Only buttons macOS reports as "other" mouse buttons are remappable: the side
buttons (Back/Forward = buttons 4/5), the wheel click and any further extra buttons. Left and
right clicks are never tapped. A button the mouse handles onboard and never reports is out of
reach, with one exception: the DPI button on a mouse with `supportsDpiButtonBinding` can be made
to type F20 (Basilisk V3 X) or, on the Cobra HyperSpeed, reported as private keys in driver mode
(§6.3.3). Profile and DPI-stage buttons that change
something inside the mouse still never reach macOS.

- Actions (`RemapAction`): `.passthrough` (None), `.keystroke` (preset shortcuts or a **custom
 recorder** that captures any combo), `.mouseButton` (middle click and others), `.doubleClick`,
 `.mediaKey` (play/next/prev/volume/mute), `.launchpad` (Launchpad, Apps on macOS 26, opened
 by bundle id through `LaunchpadApp`, as it has no default shortcut), `.dpiCycle` (DPI Cycle, offered only in a slot of
 the DPI button's gesture on a mouse with private keys and inert anywhere else, §6.3.3) and
 `.gesture(GestureBindings)` (§6.3.2).
- Mappings persist to UserDefaults per device (`buttonMappings-<device key>`). Needs
 **Accessibility** permission (banner + Open Settings / Re-check in the UI).
- Available both inline (popover buttons page) and as a standalone window
 (`RemapWindowController.swift`, opened from the right-click menu).
- Another app's event tap can take a side button's clicks before MacRazer's sees them. Until a
 side button gets through, the page names any such app that's running
 (`ButtonRemapper.competingTapApps`, from `CGGetEventTapList`, Apple's own processes left out).
- While the mouse is offline (`remappingPaused`) mappings don't fire, since the tap can't tell
 which device sent a click.
- **Tap mask** (`ButtonRemapper.eventMask(keyboard:gestures:dpiGesture:privateKeyGesture:)`, wanted value in
 `wantedEventMask`): always `otherMouseDown/Up`; `otherMouseDragged` only while some mapped
 button is a gesture; key down/up only while the DPI button's F20 bridge has a saved software
 action (a mouse with private keys never asks for keys); and `mouseMoved` only with a
 DPI-button gesture, with the keys on a mouse using F20 and without them on a mouse with
 private keys (`privateKeyGesture`). Drags and moves come at the
 mouse's polling rate, and a tap that doesn't ask for them never sees them. A change in what
 is wanted reinstalls the tap (`installTapIfNeeded`). If macOS refuses a tap with keys,
 `installTap` falls back to the mask without `bridgeEventsMask` and remembers the refusal
 (`keyboardTapRefused`) until a Re-check or relaunch.

### 6.3.2 Gesture mode, `GestureRecognizer.swift` + `DockSwipe.swift` + `ButtonRemapper.swift`

A mouse button can be set to **Gesture…** in `RemapView` (the same menu, `RemapActionMenu`, has
it for every button; the DPI button's has it too, §6.3.3, where the hold comes from a private
key or F20 rather than a mouse button). Held and moved, the button fires one
action per direction; pressed and released without a swipe, it fires its Click action. A slot
that holds one of four system presets does not fire once: it drives a swipe that follows the
pointer (the "Interactive swipes" bullet below). Every other action is the discrete swipe
described here.

- **Data model.** `RemapAction.gesture(GestureBindings)` is saved with the other actions, so a
 gesture needs no new storage key. `GestureBindings` holds six ordinary `RemapAction`s:
 `click`, `hold`, `up`, `down`, `left`, `right` (`GestureSlot` names them for the editor, and
 `action(for: GestureDirection)` picks by direction). `hold` is the DPI button's long press
 released without a swipe on a mouse with private keys (§6.3.3); no other button has a short
 and a long press, so it is never offered or fired there. It defaults to `.passthrough`, a
 missing `hold` key decodes as `.passthrough`, and it is encoded only when it isn't, so a
 gesture without it is saved exactly as before (mappings, the DPI button's action, profiles).
 A gesture inside a gesture is never offered, and `apply(_:)` ignores one that turns up in
 saved data. `GestureBindings.defaults(click:)` puts `missionControl` up, `.launchpad` down,
 `spaceRight` left and `spaceLeft` right (a swipe drags the desktop, as on a trackpad), with
 Hold on None; saved gestures keep their choices; `defaults(for: button)` takes
 `originalClick(for:)` as the click (Back re-posts Back, the wheel click re-posts a middle
 click, and `.passthrough` for the DPI button and the primary buttons, on every mouse).
 `makeGesture(_:)` applies the defaults to a button that isn't a gesture yet and keeps the
 choices of one that is. `setGestureAction(_:for:of:)` edits one slot.
- **The recogniser** (`GestureRecognizer`, a pure struct; the discrete swipe) sums the net movement since the hold
 began (`dx`, `dy`, CGEvent deltas with y growing downward). `move(dx:dy:)` returns a
 `GestureDirection` the first time the larger axis reaches `GestureRecognizer.threshold` (50
 points), and nil after that, so one swipe fires per hold. An exact diagonal goes horizontal.
 Net rather than travelled distance: going right and back is still a click. `end()` returns
 whether the hold was a click and resets the value.
- **Event pipeline** (`ButtonRemapper.handle(type:event:)`). `otherMouseDown` of a gesture
 button calls `beginGesture(_:trigger:releaseSlot:)`, which stores a `GestureHold` (trigger,
 bindings, recogniser, and `releaseSlot`, the slot a release without a swipe fires: `.click`
 here) in `gestureHold`; one hold at a time. `otherMouseDragged` goes first in `handle`
 and returns at once when no hold exists; otherwise `handleGestureDrag` feeds the deltas to
 `moveGesture(dx:dy:trigger:)`, which calls `apply(_:)` with the direction's action on the
 swipe. `otherMouseUp` calls `endGesture(trigger:)`, which fires the click action if no swipe
 fired (no direction fired and no dock swipe began). The press, the drags of the held button
 and the release are swallowed (the tap returns
 nil); drags of another button go through. The pointer itself is not frozen, so the cursor
 moves while the swipe happens.
- **What ends or cancels a hold without a click**: a new `otherMouseDown` of any button,
 pausing (`remappingPaused`), changing the mappings (`setAction` for that button, `setMappings` for all), switching
 device (`setActiveDevice`), and the tap being disabled by macOS
 (`tapDisabledByTimeout` / `tapDisabledByUserInput`). While paused a press passes through, so
 the mouse's own function remains.
- **Launchpad** (`RemapAction.launchpad`, the default for a swipe down). `LaunchpadApp.open()`
 opens `com.apple.apps.launcher` (Apps, which replaced Launchpad on macOS 26, where there is no
 Launchpad.app) or else `com.apple.launchpad.launcher` (macOS 15 and earlier) through
 `NSWorkspace`, and nothing on a Mac with neither. The menus call it "Apps" where Apps is the
 one installed (`LaunchpadApp.label(installed:)`, pure). It is a discrete action, never a swipe,
 and goes through `apply`, so a test's `actionEmitter` catches it.
- **The system presets as keyboard shortcuts.** `appExpose` ("App Exposé  ⌃↓", key code 125) was
 added for the gesture. Where a system preset is posted as a keystroke (a slot outside a
 gesture, or a gesture where `DockSwipe.isSupported` is false, below), it goes out as the
 standard shortcut (⌃↑ Mission Control, ⌃↓ App Exposé, ⌃← and ⌃→ for Spaces) with the flags a
 real arrow key carries (`postedFlags(keyCode:saved:)`), so the user must have it on in System
 Settings › Keyboard › Keyboard Shortcuts › Mission Control.
- **Interactive swipes, `DockSwipe.swift`.** In a gesture, the four presets (`SystemSwipe`:
 `missionControl`, `appExpose`, `spaceLeft`, `spaceRight`) are not typed. They are driven as
 the trackpad's "dock swipe" gesture events, so the Spaces transition, Mission Control or App
 Exposé follows the pointer while the button is held and the Dock finishes or cancels it on
 release. Other slot actions (a custom shortcut, a media key, a mouse click) still fire once at
 50 points. A slot is a system swipe only when it holds the very value the menu put there
 (`SystemSwipe.init?(_:)` compares key code, name and the posted flags with the preset), so the
 same keys recorded as a custom shortcut stay a plain keystroke. The event format is
 undocumented macOS behaviour, learned from Mac Mouse Fix (credited in NOTICE.md, with
 InstantSpaceSwitcher for the direction) and written independently: facts only, no code taken.
  - **Tracker** (`DockSwipeTracker`, a pure struct fed every pointer move with a time).
   `SystemSwipeSlots` (made once at `beginGesture` by `dockSwipeTracker(for:)`, nil when no slot
   is a system swipe) says which swipe each direction holds. Inside `deadZone` (12 points)
   nothing happens, so a click's drift is still a click. Past it, the larger axis is locked for
   the rest of the hold (an exact diagonal goes horizontal), and the direction decides: a system
   swipe there sends `began` at once, with the dead zone's movement counted; any other action
   leaves the hold to `GestureRecognizer` (state `discrete`). Once swiping, it follows every
   movement along the locked axis, backwards too. `changed` frames are at most
   `minimumFrameInterval` (1/240 s) apart; the end always carries the latest progress.
  - **Sign.** It follows the slots, not the screen: moving towards the slot that holds Space
   Left heads for the Space on the left, whichever slot that is (`progressSign`: Mission
   Control and Space Left -1, App Exposé and Space Right +1). Moving back past the start goes on
   into the opposite slot's swipe only when that slot holds the same swipe the other way
   (`opposite`). Otherwise (another action, None, or the other kind of swipe, which cannot take
   over a swipe under way) the progress is clamped at zero (`keepSign`).
  - **End or cancel, velocity.** `end(at:)` sends `ended` with an exit velocity: a time-weighted
   average of the pointer's speed (`velocitySmoothing`, 0.05 s) times the gain, faded by how
   long the pointer has been still, so a flick finishes a short swipe and a stop leaves it to
   the progress. It sends `cancelled` instead when the progress is zero or the velocity opposes
   it, which is the pointer coming back towards the start, so the swipe snaps back. `cancel()`
   cancels with no velocity.
  - **Progress and scale** (`DockSwipe.Frame.progress`, `DockSwipe.Scale`). Every event carries
   the total so far, not a step. Horizontally one Space is `perSpace(spaces)`: 2 for one or two
   Spaces, else 1 + 1/(n - 1); 3 is assumed (`assumedSpaces`) when the count is unknown. The
   scale is `perSpace / (screen width + 63)` per point (`spaceGap`, the gap the Dock draws
   between Spaces), so the desktop slides about a screen width for a Space. Vertically it is
   `1 / screen height`, so Mission Control is fully open over the height; negative heads for
   Mission Control, positive for App Exposé. The screen is the one under the pointer when the
   hold starts (`Scale.current()`). The Spaces count comes from a private window server call,
   `CGSCopyManagedDisplaySpaces` (with `CGSMainConnectionID`), looked up with `dlsym` in
   `ManagedSpaces` so a macOS without it only loses the count.
  - **Method** (`DockSwipe.Method`, `DockSwipe.method`, worked out once). macOS 26 and earlier
   take the CGEvent fields below (`eventFields`); macOS 27 and later ignore them and take an
   attached IOHIDEvent (`attachedHIDEvent`, below), but only when every private call it needs
   resolves (`DockSwipe.AttachedEvent.missingSymbol`). The pure
   `method(majorVersion:missingSymbol:)` decides, and asks for the symbols only on 27 or later,
   so an earlier macOS never looks them up. `DockSwipe.isSupported` is `method != nil`.
  - **Event format, macOS 26 and earlier** (`DockSwipe.events(for:userData:)`, pure). Each frame
   is two CGEvents, both tagged with `userData` (`ButtonRemapper.magic`) so the tap skips them.
   The first is event type 30 (`swipeEventType`) with gesture type 23 (field 110, the dock
   swipe `IOHIDEventType`); the phase (`Phase`: began 1, changed 2, ended 4, cancelled 8) in
   fields 132 and 134; the kind (`Kind`: horizontal 1, vertical 2) in fields 123 and 165 and,
   as the 32-bit float with those bits, in 119 and 139; the progress as a double in 124 and as
   float bits in integer field 135; field 136 (inverted from device) 1 for vertical and 0 for
   horizontal; on `ended` and `cancelled`, the velocity in 129 and 130; and field 41 set to
   33231, whose meaning is unknown and which is copied because it costs nothing. The second
   event is type 29 (`gestureEventType`) with field 41 alone. The field numbers are
   `CGEventField` raw values and none of this is public API.
  - **Event format, macOS 27 and later** (`DockSwipe.HIDPayload`, pure, and
   `DockSwipe.AttachedEvent`). Each frame is one CGEvent: type 30 (field 55) and the
   `userData` tag, nothing else of the old format, no type 29 event. Attached to it is an
   IOHIDEvent of type 23 (kIOHIDEventTypeDockSwipe) with the phase in its event flags
   (`phase << 24`), the kind as its motion (field `0x170001`), flavor 3
   (kIOHIDGestureFlavorDockPrimary, field `0x170005`) and the progress as a double (field
   `0x170002`, kept by IOKit in 16.16 fixed point). On `ended` and `cancelled` it has a child
   IOHIDEvent of type 9 (velocity) with the velocity in X and Y (`0x90000`, `0x90001`). The
   field numbers are Apple's, from IOHIDFamily's open-source IOHIDEventTypes.h. The progress and
   the velocity are signed for macOS 27 (`HIDPayload.orientation`): flipped while Natural
   scrolling is on (`com.apple.swipescrolldirection` in the global domain, on when absent,
   `DockGestures.naturalScrolling`), kept while it is off, so the swipe goes the same way as
   on macOS 26 and follows the slots. The poster reads the setting as each swipe begins, so one
   swipe keeps one sign. The calls are `IOHIDEventCreate`, `IOHIDEventSetEventFlags`,
   `IOHIDEventSetIntegerValue`, `IOHIDEventSetDoubleValue` and `IOHIDEventAppendEvent` from
   IOKit and `SLEventSetIOHIDEvent` from SkyLight, opened with `dlopen` and looked up with
   `dlsym` once. Ownership: IOHIDEventCreate is a Create-rule call, so each IOHIDEvent made is
   released by `event(for:userData:)`; the parent retains its velocity child; and
   SLEventSetIOHIDEvent keeps a copy in the CGEvent (measured on macOS 27.2.1), so the CGEvent
   owns all a frame needs and nothing leaks per frame. The CGEvent's fields are written
   before the attach: written after it, a field didn't keep its value. The facts come from Mac
   Mouse Fix's macOS 27 path and OpenLogi's hardware-tested sign (NOTICE.md); the code is this
   project's own.
  - **Posting** (`DockSwipePoster`, main thread, session tap, with the `method` it was given).
   Under load the Dock can miss an end and leave the desktop stuck between two Spaces, so each
   end goes out again after 0.2 s and 0.5 s (`endRepeats`), with either method; the next
   swipe's `began`, or another end, stops the repeats still waiting. `ButtonRemapper` keeps the
   last frame of an open swipe (`openDockSwipe`) and `gestureHold`'s `didSet` cancels it on
   every reset that ends a hold, so the Dock is never left halfway; the ends that finish a swipe
   send theirs first.
  - **macOS 27 without the calls.** When one of the private calls is missing,
   `DockSwipe.method` is nil, `DockSwipe.isSupported` is false, `DockSwipeOutput.system` returns
   nil, no tracker is made, and the four presets are the keyboard shortcuts above, firing once
   at 50 points. The gesture trace says which method is in use when the poster is made
   (`SWIPE method: ...`), or which call was missing (`SWIPE method: none, ...`); with the
   attached method it also logs each swipe's `began`, `ended` and `cancelled` as sent
   (`SWIPE attached ...`, with the signed progress, the velocity and the Natural scrolling
   setting). The macOS 27 method has been tried on a real Mac: macOS 27.2.1 with a Cobra
   HyperSpeed over Bluetooth, where the Spaces and Mission Control swipes follow the pointer.
  - **App Exposé needs the Dock's trackpad gesture.** The Dock ignores an App Exposé swipe while
   System Settings › Trackpad › More Gestures › App Exposé is off, as it is out of the box
   (`showAppExposeGestureEnabled` in `com.apple.dock`). So `dockSwipeTracker(for:)` asks
   `DockSwipeOutput.appExposeEnabled` (`DockGestures.appExposeEnabled`, read fresh at every
   hold) and, while it is off, takes App Exposé out of the slots (`SystemSwipeSlots.removing`):
   it is then the ⌃↓ shortcut, fired once at 50 points.
  - **The defaults.** Space Right left and Space Left right, so the desktop moves with the
   pointer as on a trackpad, and Launchpad down, a discrete action: the vertical axis is mixed,
   so moving down from the start fires Launchpad once at 50 points, while a swipe up taken back
   down is clamped at the start and fires nothing.
  - **Hardware.** Confirmed on a real mouse on macOS 26.3: the Spaces animation follows the
   pointer for horizontal swipes, and a vertical swipe was driven. App Exposé as a swipe did
   nothing there with its trackpad gesture off, hence the fallback above. The constants (the
   scale, the dead zone) have not been tuned. On macOS 27.2.1 (Cobra HyperSpeed over Bluetooth)
   the Spaces and Mission Control swipes follow the pointer with the attached method. Not yet
   tried on macOS 27: App Exposé as a swipe with its trackpad gesture on, and Natural scrolling
   turned off. An independent review measured no leak building 200,000 attached events.
  - **Turning it off** (`ButtonRemapper.systemSwipesFollowPointer`, `RemapView`'s checkbox titled
   `followPointerToggleTitle`, "Mission Control and Spaces follow the pointer"). On by default.
   Off, `dockSwipeTracker(for:)` returns nil, so no tracker is made and the four presets are
   the keyboard shortcuts their slots hold, fired once at 50 points like any other action, for
   a mouse button's hold and the DPI button's long press alike. One global setting: saved in the
   defaults key `systemSwipesFollowPointerKey` (`gestureSystemSwipesFollowPointer`), not per
   mouse and not in profiles; absent reads as on. Holds read it as they start, so a change
   sets `gestureHold` to nil, which ends the hold and cancels an open swipe. The checkbox shows
   only `if DockSwipe.isSupported`, and the editor's explanation goes by
   `systemSwipesFollowPointerHere` (`dockSwipes != nil` and the setting on).
- **A gesture's click re-posts the button** (`postMouseClick`, tagged so it passes the tap), so
 it fires at release. A gesture button therefore can't be held to drag.
- **UI.** `RemapView.gestureEditor` lists the slots (`ButtonRemapper.gestureSlots(of:)`: Click,
 Hold only for the DPI button of a mouse with private keys, then the four swipes) with an
 action menu each and a key recorder; `RemapActionMenu`'s `onGesture` adds Gesture… to the
 menu. `swift run MacRazer
 render-remap gesture out.png` renders the editor from preview data
 (`ButtonRemapper.loadPreviewState` has a gesture on button 5).
- **Debug trace** (`GestureDebugLog.swift`). Off by default. `defaults write
 com.cortinadev.macrazer-mx gestureDebugLog -bool true` and a relaunch make it append to
 `~/Library/Logs/MacRazer MX/gesture.log`: gesture holds beginning, moving, firing and ending,
 dock swipe frames, F20 down, up and repeat timing, and pointer deltas. It also records, with
 these line prefixes:
   - `HIDREPORT id=<n> len=<n> <hex>`: the mouse's own HID input reports other than pointer
     movement (`GestureDebugHIDWatch`, an `IOHIDManager` on the Razer vendor ids, leaving out
     the pointer and wheel's Generic Desktop page). It never records which key a keyboard
     typed: the HID watch matches by vendor, so a keyboard of the same make is seen, and a
     keyboard report is logged only when its keys are F13 to F20 (`GestureDebugReportFilter`);
     any other is "not recorded". Also `HID watch ...` lines for devices matched, skipped and
     removed.
   - `GATT <uuid> properties=...`: every characteristic of Razer's Bluetooth service, and
     `BLE unsolicited <uuid>: <hex>`: what the mouse sends there that isn't part of a reply the
     app is waiting for (`BluetoothDevice.swift`).
   - `BLEREAD <key> -> ...`: once per Bluetooth connection, after the reads the connection
     starts with, a fixed list of read-only vendor probes (`BLEProtocol.traceProbeKeys`: the
     device mode, the command catalogue, the button inventory, entries 0x60 and 0x80). A probe
     is built only from a key that is a read (`traceReadRequest`), so the trace can't write.
   - `DEVMODE ...`: the product's own reads and writes of the device mode and why (wanted,
     engaged, checked, restored, failures, the quit-time restore), the settling re-checks
     scheduled after an engage and what each found, a notification that called for a
     re-check (`DEVMODE notice <code> (...)`) or was MacRazer's own DPI change, an early
     re-check called off, and a restore dropped because its connection went.
   - `PRIVKEY down|up <code>`, `PRIVKEY watch ...` and `PRIVKEY <code> ignored`: the private
     keys as they arrive and why one was ignored (`DpiPrivateKeyWatcher`, `ButtonRemapper`).
   - `DPI cycle ...`: the stage a software DPI cycle steps to.
   - `SWIPE method: ...`: which dock swipe method the poster uses, once as it is made, or
     `SWIPE method: none, <call> did not resolve, ...` when macOS 27 lacks a private call; and
     with the attached method, `SWIPE attached began|ended|cancelled ...` with the progress and
     velocity as signed for macOS 27 and the Natural scrolling setting (`DockSwipePoster`).
   The HID watch needs **Input Monitoring**, so relaunch after granting it. It exists because
   nothing outside the app can see what its tap receives. The flag is read once at launch.
   (An earlier build had a `gestureDebugDeviceMode` key that wrote the device mode from the
   trace; it is gone, and the trace only reads what the mouse does.)
- **Tests.** `GestureRecognizerTests` (threshold, dominant axis, once per hold, net movement),
 `ButtonRemapperGestureTests` (swallowing, pass-through while paused, the cancel rules, nested
 gestures, defaults, persistence, the mask, Hold inert on a side button), driven through
 `handle(type:event:)` with
 synthetic `CGEvent`s and the `actionEmitter` hook that records actions instead of posting them.
 `DockSwipeTests` (the preset-to-swipe match, the tracker's dead zone, axis lock, sign, clamp,
 end versus cancel and velocity, the scale, the event fields, the poster's repeated end, the
 method by macOS version, the attached payload and its sign by Natural scrolling, and the
 attached IOHIDEvent read back and the poster sending one event a frame; those run only where
 the app uses that method (macOS 27 and later with the calls present, `skipUnlessAttachedMethod`)
 and skip elsewhere, and nothing is posted),
 `InteractiveSwipeTests` (the same through the tap with a recording `DockSwipeOutput` and a
 clock the test moves: the swipe following a hold, other actions still firing once, no swipe
 without dock swipes, resets cancelling, a hold of the DPI button ending with its release, and
 its Hold firing only when no swipe began) and `SystemSwipesFollowPointerTests` (the setting:
 on out of the box, each preset firing its shortcut once at 50 points when off for a mouse
 button and for the Cobra's long press, turning it off mid-swipe cancelling the swipe and
 mid-hold ending the hold without firing, the saved key being global, and the editor's text).

### 6.3.3 The DPI button: F20 bridge and driver mode, `ButtonRemapper.swift` + `DpiDriverMode.swift` + `DpiPrivateKeys.swift` + `BLEProtocol.swift` + `BluetoothDevice.swift`

On a mouse with `RazerDevices.supportsDpiButtonBinding` (Basilisk V3 X HyperSpeed, and in the
fork the Cobra HyperSpeed, both over Bluetooth, PIDs `0x00BA` and `0x00DC`) the DPI button's
assignment is entry `0x60` of the mouse's onboard function table. The Buttons page shows a "DPI
Button" section (`DpiCycleBindingSection`) only for such a mouse on Bluetooth. USB and the
2.4 GHz dongle are not supported: the firmware handles the button onboard there, and neither the
entry write nor driver mode exists for them in the app.

An action the mouse can't carry out itself (a media key, Double Click, a gesture, a key it can't
type) is MacRazer's, and there are two ways the app learns the button was pressed:

- **F20 bridge** (the Basilisk V3 X HyperSpeed, `usesDpiBridge`): entry `0x60` holds F20, the
  button types it, and the event tap turns it into the action. The hold behaviour is unchanged
  and unverified on hardware. Driver mode is not enabled on it: it is unverified there, and
  another project reported Bluetooth instability writing the device mode on that mouse.
- **Driver mode** (the Cobra HyperSpeed, `RazerDevices.dpiButtonPrivateKeys` is
  `DpiButtonPrivateKeys.cobraHyperSpeed`): entry `0x60` keeps DPI Cycle, the mouse is put in
  driver mode, and the app watches the button's private keys. No F20, and no key events in the
  tap, on this mouse.

**Status.** On the Basilisk V3 X this is upstream's, tested behaviour. On the Cobra over
Bluetooth, the entry `0x60` write path is confirmed on hardware (the read before the write, the
read back). For driver mode, a trace on a real Cobra captured: the mode write accepted and read
back, the link staying stable, the two keys below behaving as described, and normal mode
restored on quit. The product code path was then used on that mouse: hold and swipe, the short
press doing Click, the software DPI cycle stepping one stage per press, the periodic check
finding driver mode still set over about an hour, and normal mode restored at quit. A trace of
a sleep and wake then showed the mouse dropping driver mode just after it was engaged on the
new connection; the settling and notification checks below fix that, and have only unit tests
so far. **Not yet tried:** the Hold slot, App Exposé, and the side-button gesture. The safety
rules below stay.

**Why driver mode.** The Cobra HyperSpeed's DPI button is a documented tap/hold "multifunction"
button: a short press cycles DPI, a long press invokes a function only Synapse knows. That is
why in normal mode whatever is programmed in entry `0x60` only fires at the release of a short
press (an F20 pulse of about 50 ms, nothing while held), and why the long press has its own
function-table entry, `0x80`, disabled from the factory. A raw HID and Bluetooth trace showed
nothing at all while the button is held in normal mode, so a hold can't be seen there. An earlier
design of this fork worked around it with "click, then swipe" (a latched hold with a 0.6 s
window, ended by stillness); it, `dpiButtonActsOnRelease` and the latched hold in
`ButtonRemapper` are gone. In driver mode the firmware stops acting on the button and reports
it in HID input report 4 (`PrivateKeyReport`, report id 4, an array of the keys held):

- `short` `0x52`: a pulse of about 55 ms when a short press is released.
- `long` `0xD2`: down when the firmware recognises a long press, about a second after the press
  (per Razer's documentation; the delay is the firmware's and the app can't shorten it), and
  held until the button is released.

Over Bluetooth the report arrives with its id twice (`04 04 d2 00 ...`), so up to two leading
ids are dropped (`PrivateKeyReport.heldKeys`); a key whose code equals the report id can't be
told apart and is never acted on. The mouse matches as two HID devices, each delivering the
report, so `PrivateKeyTracker` turns successive key arrays into one down and one up per key and
a repeated frame changes nothing.

**Data flow.**

1. `ButtonRemapper.refreshDpiDriverModeWant` works out what driver mode needs
   (`DpiDriverModeNeed`, pure): `none` without a mouse with private keys or an action MacRazer
   carries out (`dpiCycleSoftwareAction != nil`); then `accessibility` without the tap
   (`remappingPermissionsGranted`), `inputMonitoring` without `IOHIDCheckAccess` granted (asked
   last), `relaunch` when it reads as granted but the keys couldn't be watched in this run
   (`privateKeyInputBlocked`), and `ready` otherwise. Only `ready` wants driver mode: without
   the rest the button is better left cycling DPI in the firmware than doing nothing. It tells
   `MouseController.setDpiDriverModeWanted(_:)` through `onDpiDriverModeWanted`, once per change.
   It runs on every change of device, action or tap, and wherever the permissions are looked at
   (`refreshAccessibility`: the Buttons page appearing, the popover opening, the app becoming
   active, Re-check). macOS says nothing when a permission is granted, so while the need is
   `accessibility` or `inputMonitoring` and the mouse is connected
   (`DpiDriverModeNeed.rechecksPermissions(paused:)`, published as `waitsForPermission`), a
   main-run-loop timer calls `refreshAccessibility` every `permissionRecheckInterval` (3 s). It
   stops at the first look that finds the permission there, or when the wait is over; nothing
   polls otherwise. A grant of Accessibility is picked up that way, without a relaunch. Input
   Monitoring turned on while the app runs is not: on macOS 26.3 `IOHIDCheckAccess` in the
   running process kept reporting not granted, so the wait never ended, and the reopened app
   had it. The timer still looks for it (harmless if macOS ever applies it to a running app),
   but `DpiDriverModeNeed.needsReopen` (`inputMonitoring` and `relaunch`) has the page ask for
   a reopen (step 5).
2. `MouseController.syncDpiDriverMode(_:)` (device queue) asks `DpiDriverModeBook.step(for:now:)`
   what to do and does it: `engage`, `recheck` or `restore`, through
   `BluetoothDevice.setDeviceMode`. It publishes `dpiDriverMode` (`DpiDriverModeState`: `off`,
   `engaging`, `engaged`, `unavailable(text)`). Nothing is sent to any mouse without private keys.
3. `ButtonRemapper.dpiDriverModeChanged` takes that state. While it is `.engaged`
   (`privateKeysActive`) `syncPrivateKeySource` starts `DpiPrivateKeyWatcher` for the mouse (an
   `IOHIDManager` on vendor `0x068E` and its product id, one input report callback per HID
   device, all feeding one `PrivateKeyTracker`; main thread, Input Monitoring needed). The same
   callbacks take report 5, the mouse's notifications (`MouseNoticeReport`), handed on through
   `onMouseNotice` to `MouseController.dpiDriverModeNoticed` (see the lifecycle below). When it
   stops being engaged the watcher stops and a hold of the DPI button ends. If the watcher can't
   start (`privateKeyInputBlocked`; `DpiPrivateKeyWatcher.startWorks` counts a manager open
   refused with no device open, kIOReturnNotPermitted, as a failure rather than a watch that
   never delivers), driver mode is no longer wanted and the button goes back to normal. The
   failure isn't kept for the run: it is dropped when Input Monitoring reads as not granted (a
   later grant gets a fresh try), and every look at the permissions tries to open the mouse's
   HID devices again (`retryBlockedPrivateKeys`, `PrivateKeySource.canWatch`, an open and close
   that sends nothing to the mouse). While Input Monitoring reads as granted and the device
   still won't open, the status line says to quit and reopen MacRazer MX.
4. `ButtonRemapper.handlePrivateKey(_:)` acts on each event, only while driver mode is engaged,
   the mouse is connected and remapping isn't paused:
   - long key down, with a gesture: starts a hold as a mouse button's press does
     (`beginGesture(_:trigger:releaseSlot:)` with trigger `ButtonRemapper.dpiButton`, -1, and
     `releaseSlot` `.hold`); the pointer's `.mouseMoved` events in between are the swipe
     (`handleDpiGestureMove`); long key up ends the hold (`endGesture`). Mission Control, App
     Exposé and Spaces follow the pointer (§6.3.2) and other actions fire once. A long hold
     released without a swipe (no direction fired, no dock swipe began, so the same rule as a
     mouse button's click) fires the **Hold** slot once, at the release (`perform`, so Hold on
     `.dpiCycle` cycles too). Only the long key's own release fires it: every reset sets
     `gestureHold` to nil first, and the release `PrivateKeyTracker.sourceGone` makes up when
     the HID device goes away (a disconnect) is marked `PrivateKeyEvent.deviceGone`, which ends
     the hold (`endGesture(trigger:released: false)`) without firing it.
   - short key down, with a gesture: the Click slot runs (`perform`). When it is `.dpiCycle`
     (DPI Cycle), `onDpiCycleRequest` calls `MouseController.cycleDpiStage()`: it reads the
     stage table, writes `nextStage()` and publishes the new stage, because in driver mode the
     firmware no longer cycles DPI. When it is `.passthrough` (None) nothing happens, and the
     DPI stage stays. A swipe whose direction holds `.dpiCycle` cycles once the same way. A new
     gesture (`newDpiGesture`) clicks and holds None (`.passthrough`), so a short press leaves
     DPI alone until DPI Cycle is chosen (it used to click `.dpiCycle`, which surprised: a
     re-created gesture kept changing DPI). One saved before DPI Cycle was its own case has
     `{"passthrough":{}}` and keeps None; one saved with Click on `{"dpiCycle":{}}` keeps it;
     one saved before Hold has no `hold` key and reads Hold as None.
   - short key down, any other action: `apply`s it. A long press does nothing for those.
     `.dpiCycle` as the whole action, or in any gesture of another button or mouse, reaches
     `apply`, which leaves it inert.
   - the short key's release and any other code do nothing.
5. `RemapView` says it: `gestureEditorExplanation(longPress:)` and `dpiButtonHelpText(privateKeys:)`
   describe holding until the gesture starts, a short press doing Click and holding without
   moving doing Hold. `dpiActionStatus` is the page's status line (what `DpiDriverModeNeed`
   says is missing first, then where driver mode stands). Without Input Monitoring it says to
   turn it on in System Settings and then reopen MacRazer MX, and offers the Input Monitoring
   settings; while `needsReopen` it also offers **Reopen MacRazer MX**
   (`ButtonRemapper.reopenApp`): `AppRelaunch.openNewInstance` of the bundle, and once the new
   instance runs, `NSApp.terminate`, the same path as Quit, so `applicationWillTerminate`
   restores driver mode first. A failed open quits nothing and the page says to quit and
   reopen by hand (`reopenFailed`). The first time `updatePermissionRecheck` finds Input
   Monitoring is what the button is missing, `ButtonRemapper.askForInputMonitoring()` asks macOS
   for it (`IOHIDRequestAccess`), so that macOS lists the app with a switch; the Input
   Monitoring button calls it too. See §7 for what that did on one Mac. The gesture editor lists Hold after Click for this button
   only (`gestureSlots(of:)`). Its menus start with None and DPI Cycle as separate choices
   (`gestureSlotLeadingChoices`), in every slot, Hold included; no other button, and no mouse
   without private keys, offers DPI Cycle.

**Driver mode lifecycle** (`DpiDriverModeBook`, pure, and `MouseController`):

- **Engaged** on each new connection (`connectionChanged`) and after each wake (`doubtful`),
  while wanted, with a read first so a mouse already in driver mode isn't written, and a read
  back after a write.
- **Settling checks.** Just after a reconnect or a wake the Cobra hasn't finished starting. A
  trace of a real one over Bluetooth showed it accept driver mode and read it back, then reset
  itself to normal mode a few hundred milliseconds later, around its own start-up
  notifications (`0c`, `31`, below): gestures stopped and the button cycled DPI in the firmware
  until the next check, 30 s later. So the first engage after `connectionChanged` or
  `doubtful` (`fresh`) is followed by two quiet checks, `firstSettlingCheckDelay` (1 s) and
  `secondSettlingCheckDelay` (3 s) after it (`engaged(at:wrote:)`). A check that has to write
  driver mode again (`wrote` while it was taken for engaged: the mouse dropped it) starts the
  two over from that write, at most `maxSettlingRounds` (3) rounds per connection or wake; a
  fall-back the 30 s check finds does the same. The checks are `earlyChecks` in the book.
  `MouseController.scheduleDpiDriverModeEarlyCheck` runs the next one (`nextEarlyCheck`) with a
  one-shot `asyncAfter` on the device queue (occasion `.earlyCheck`), never a timer, and a
  generation counter calls it off once the book drops it: a connection change, a wake, a change
  of mind (`setWanted`) or a failed change. An early check only ever checks (it never engages,
  restores or looks for a leftover), gives way to a command waiting on the queue and tries again
  `driverModeEarlyCheckRetryDelay` (0.5 s) later, and keeps the limits of any check: a failed
  write counts against `maxAttempts`, and one that goes unanswered isn't repeated (the round's
  later check still goes).
- **Notifications.** HID input report 5 carries the mouse's own notifications, `05 05 <code>
  ...` over Bluetooth with the id twice (`MouseNoticeReport.notice`, up to two leading ids
  dropped as for report 4). Codes matched (from other projects' notes and the trace, not relied
  on): `02` DPI changed, followed by X and Y big-endian; `09` availability (`09 02` seen at
  sleep, `09 03` documented as wake); `0c` power or connection state; `10` heartbeat; `31`
  battery. While driver mode is taken for engaged and the last check was answered,
  `noticed(_:at:)` turns `0c`, `09` and `02` (`MouseNotice.suggestsModeLost`) into an
  immediate check, at most one per `noticeCheckSpacing` (1 s; each notification comes from both
  HID devices and several come together). The rule for MacRazer's own DPI changes is by time: a
  `02` that arrives within `ownDpiChangeWindow` (2 s), either side, of the app's own DPI write
  is that write and calls for nothing. `MouseController.noteOwnDpiChange` stamps the time as
  each DPI write starts and again as it ends (`cycleDpiStage`, `setDPI`, `setDPIStageValue`,
  `applyProfile`), and the notification's time is taken on arrival on the main thread. Time
  rather than the DPI value, since stages can share a value and the firmware's next stage could
  be the one the app last set.
- **Re-checked** from the poll at most every `recheckInterval` (30 s) while engaged, to put the
  mode back if the mouse fell out of it. A background check gives way to a command waiting on
  the queue, and a read that goes unanswered changes nothing (the mouse is most likely still in
  the mode).
- **Retries.** A failed change isn't retried at once: the poll tries again `recheckInterval`
  later, at most `maxAttempts` (3) times per connection, then not until the next connection,
  wake or change of mind. A change of mind (`setWanted`) is a fresh start.
- **Restored** (`restore`: write normal mode, read it back) when it is no longer wanted, but only
  where this run may have left driver mode (`maybeSet`, set before a write of it or when a read
  finds it, cleared when normal mode reads back), and at quit
  (`MouseController.restoreDpiDriverModeForQuit`, from `applicationWillTerminate`, waiting at
  most `driverModeRestoreTimeout`, 3 s, for the device queue).
- **A disconnect drops a pending restore.** Driver mode doesn't outlast a connection, so
  `connectionChanged` clears `maybeSet` and with it any restore pending for the connection that
  went (it returns whether one was, traced as dropped). The trace showed why: "no longer wanted"
  came only because the mouse slept and its device went away, and the reconnect then got
  `00 00` before driver mode was wanted again. Quitting writes nothing until driver mode is
  engaged on the new connection. In case only MacRazer's own connection was reopened with the
  mouse still in driver mode, the leftover read is armed again (`leftoverChecked` false): it
  reads the mode and writes normal mode only if it finds driver mode. A wake (`doubtful`) keeps
  a pending restore, as it is the same connection, and clearing the action or quitting while
  connected restores as before. An observed removal of the mouse's HID device
  (`beginWakeRecovery` with `discardBluetoothSession`) ends the connection for driver mode at
  once (`dpiDriverModeConnectionLost`).
- **Crash.** If MacRazer crashes or is killed, nothing writes normal mode back at that moment:
  the DPI button does nothing until the mouse sleeps, reconnects or is power-cycled, or until
  the next run. A run that does not want driver mode and never set it looks for a leftover once
  (`DpiDriverModeBook`'s `.checkLeftover` step, from the poll, once the connection has answered
  for `leftoverCheckDelay`, 10 s): one read of the mode, and normal mode written back only if it
  reads 3.
- **The old F20 binding.** If a read finds entry `0x60` holding F20 on a mouse with private keys
  (left by a build from before driver mode), `shouldClearDpiBridge` allows one write of the
  factory DPI-cycle block per connection (`dpiBridgeRestoreAttempted`), whatever action is saved.
- **Permissions.** Accessibility (the tap, for the hold's pointer moves and the actions) plus
  Input Monitoring (the report callbacks). Accessibility granted while the app runs is picked
  up without a relaunch (step 1). Input Monitoring granted while it runs takes effect once
  MacRazer MX is reopened, which the page asks for and offers (step 5).

**Safety rules for driver mode.** Only `BLEProtocol.DeviceMode` values can be written, only
through `deviceModeRequest(_:)`, only to a mouse with private keys, never during a device test
(`deviceTestActiveForIO`), once per change with a read back and no second write. A failed change
leaves the button cycling DPI and says so in plain words (`dpiDriverModeErrorText`).

- **Assignments** (`BLEProtocol.DPIButtonBinding`): `.dpiCycle` (factory, `dpiCycleBlock`),
 mouse buttons by `buttonID` (`.leftClick` through `.scrollDown`), `.keyboardShortcut(hidUsage:
 modifiers:)`, and `.softwareBridge`, which is `.keyboardShortcut(hidUsage: 0x6F, modifiers:
 0)`, the HID usage of F20. `dpiButtonPayload(for:)` builds the 10-byte write.
- **Choosing how an action is carried out** (`ButtonRemapper.dpiButtonAssignment(for:privateKeys:)`):
 None, and `.dpiCycle`, are the firmware's DPI Cycle; a keystroke whose key
 `hidUsage(forMacKeyCode:)` knows, or a mouse button 1 to 5, is written as the mouse's own
 function and works without the app (and without driver mode);
 everything else (media key, Double Click, gesture, an unknown key) is MacRazer's, saved as
 `dpiCycleSoftwareAction` (UserDefaults key `dpiCycleSoftwareAction-<device key>`) with
 `.softwareBridge` written on a mouse using F20, and `.dpiCycle` kept on a mouse with private
 keys. `configureDpiCycle(_:softwareAction:controller:)` writes through
 `MouseController.setDpiCycleButtonBinding` and only saves the software action once the write
 read back (on a mouse with private keys whose entry already reads `.dpiCycle`, nothing is
 written and the action is saved at once). A software action is refused (nothing written)
 without Accessibility. `makeDpiGesture(controller:)` is Gesture… for this button:
 `newDpiGesture`, the defaults with None (`originalClick(for: dpiButton)`) as the click, and
 Hold on None, on every mouse.
- **F20 event pipeline** (Basilisk V3 X). `handleDpiBridge(type:event:)` handles key events whose
 key code is 90 (F20). A key-down that arrives with the binding confirmed, the mouse connected
 and none of ⌘ ⌃ ⌥ ⇧ held is swallowed and either `apply`s the saved action or, for a gesture,
 starts a hold with trigger `ButtonRemapper.dpiButton` (-1). Key repeats never start anything.
 Movement while the DPI button is held arrives as `.mouseMoved` (`handleDpiGestureMove`, which
 does not swallow it, since no app saw a button go down); the key-up ends the hold and fires
 the click if no swipe fired. `bridgeKeyIsDown` guarantees a swallowed key-down's key-up is
 swallowed too, and a key-down that was let through has its key-up let through. The F20 of a
 real keyboard takes the same path while an action is set. Primary-button drags are never
 tapped, so a DPI hold sees no movement while the left or right button is also down.
- **Reading and restoring the entry.** `observeDpiCycle(controller:)` (wired in `AppDelegate`)
 tracks the connection. On connecting (Bluetooth, supported model) and after a wake it reads the
 entry (`MouseController.refreshDpiCycleButtonBinding`, a read only). `confirmDpiBridge` marks the
 bridge live only when that read says `.softwareBridge`, on a mouse using F20. If a saved software
 action exists and a fresh read shows a mouse using F20 lost it, `shouldRestoreDpiBridge` allows
 one write to put it back per connection. `dpiBridgeStatus` is the page's one-line state for F20,
 `dpiPrivateKeyStatus` for private keys.
- **Safety rules for the firmware write** (`BLEProtocol.parseDpiButtonBinding`,
 `BluetoothDevice.writeDpiCycleBinding(_:read:write:)`):
 0. The active onboard profile is read first (`readActiveSlot`). Writes go to slot 1 while reads
 look at the slot in use, so on any other profile the write throws
 `DPIButtonEntryError.otherProfileInUse(slot)` and nothing is read or written. A mouse that
 doesn't answer is treated as being on profile 1.
 1. The entry is read first. Nothing is written unless the read succeeds and parses. A reply
 that isn't a read of entry 0x60, or holds something that isn't a `DPIButtonBinding` (a macro,
 a profile switch), throws `DPIButtonEntryError.unrecognized`. With the function-table layout
 and flag 0, a factory block other than DPI Cycle throws `.notTheDpiButton`. With flag 1 the
 second block is a HyperShift layer and says nothing, so only the current block is checked.
 2. The write is sent once. A refusal or timeout throws `DPIButtonWriteError.notTaken`.
 3. The entry is read again. Anything but the written binding throws `.notReadBack`, and no
 second write follows.
 `MouseController.dpiButtonErrorText(_:)` turns each into a plain sentence for the page. The
 errors of the first read always mean nothing was written.
 4. The DPI button's entry and `SideButtonReset`'s (entries 0x04 and 0x05) never share an
 entry, so a mouse can have both.
- **UI** (`RemapView.swift`, `DpiCycleBindingSection`): one action menu whose None is "DPI Cycle
 (default)", extra mouse choices that are firmware functions, software choices disabled without
 Accessibility, the status line while a software action is set, an Input Monitoring button when
 the keys can't be seen (the tap refused key events on the F20 mouse, Input Monitoring not in
 effect on the private-key mouse), a Reopen MacRazer MX button on the private-key mouse while
 Input Monitoring is missing or not yet applied (`dpiActionNeedsReopen`), and Retry / Read
 button assignment on errors.
- **Credits.** The device-mode key and the private-key report format were learned from other
 open-source projects' documentation: OpenRazer, OpenSnek (gh123man), OpenSynapse and
 ergo-control. No code from them is used.
- **Tests.** `DpiDriverModeTests` (when the mode is read and written: not while unwanted,
 engaged at once then checked every interval, a new connection or wake engaging again,
 retries slow and capped, restore only where it may have been set, a failed restore retried;
 settling checks 1 s and 3 s after a fresh engage, called off with the connection or the want,
 a fall-back they find put back and the checks started over, their limits; which notifications
 call for a check, once a second, never for the app's own DPI change; a disconnect dropping a
 pending restore while a clear still restores; the sleep and wake from a Cobra trace replayed;
 `BluetoothDevice.setDeviceMode` driven with a mouse made of closures: read first, no write when
 already set, no write after a failed read, a write that doesn't read back isn't repeated;
 error text). `DpiButtonPrivateKeyTests` (the report read with its id once or twice, report 5's
 notifications read the same way and which of them suggest driver mode was dropped, a repeated
 frame firing nothing, the frames captured on the Cobra giving one down and one up per press;
 only the Cobra over Bluetooth having private keys; a hold and one swipe, each direction, a
 long hold without a swipe not a click, the short key as Click, with None doing nothing and
 DPI Cycle cycling once per press, DPI Cycle in a direction, DPI Cycle inert anywhere else,
 Hold firing once for a long press released in place and never after a swipe, Hold on DPI
 Cycle, other actions on the short key, keys counting only while engaged, the Basilisk
 ignoring them, every reset ending the hold without Hold, a disconnect's release firing no
 Hold, the watcher started only while engaged and the notifications handed on from it, keys
 that can't be watched giving the button back until they open, what counts as a watcher
 start, driver mode wanted only with
 everything it needs and what is named missing, Input Monitoring asking for a reopen, the
 reopen quitting only once the new instance launched, the permission timer's rules, F20 never
 taken, the entry keeping DPI Cycle, the editor's None and DPI Cycle choices and its Hold row,
 a new gesture clicking and holding None, a gesture saved before keeping None, one saved
 before Hold reading Hold as None and saved again without it, the editor and status texts).
 `DpiCycleSoftwareBridgeTests` (per-device
 persistence, confirmation and restore gating, the F20 mouse's keyboard tap mask, the Cobra
 enabled over Bluetooth only, the write path: no write on a failed or unparsable read, one write
 then a read back, a HyperShift layer not taken for the factory function, a mismatching read back
 not retried, "DPI Cycle (default)" writing the factory block, error text); `DpiButtonGestureTests`
 (a hold driven by F20 and moves on the Basilisk, key-repeat and release handling, device
 changes, the mask, DPI Cycle and Hold doing nothing there); `InteractiveSwipeTests` (a swipe
 ended by the release of the DPI button, and Hold only when no swipe began);
 `BLEProtocolTests` for the parser and the device-mode request, read and parse; and
 `GestureDebugTraceTests` for the trace's report filter and probes. No test touches a real mouse:
 the mode is volatile and writing it changes how the real button behaves, so every rule about
 when it is written is checked without one.

### 6.3.1 Reverse scrolling, `ScrollSettings.swift` and `ScrollDirection.swift`

**Settings → General → Reverse scrolling on Razer mice** is off by default and saved
once for the app under `reverseScrollingOnRazerMice`. Both vertical and horizontal scrolling
reverse on Razer mice; trackpads and other mice keep their directions. The preference does
not change mouse firmware, profiles, or macOS's Natural scrolling setting.

`ScrollSettings` starts a separate scroll-only event tap only while the preference is enabled,
a Razer mouse is connected, Accessibility is granted, and source identification is available.
The tap has a dedicated thread and run loop. Disabling the setting, disconnecting, revoking
permission, or quitting stops it. Button remapping keeps its existing tap and lifecycle.

`ScrollEventRouter` identifies the underlying HID event's sender. `ScrollSources` preloads
IORegistry sender identities before installation; newly seen senders are resolved on a
separate queue. The event callback only consults cached decisions. Unresolved events pass
through, and negative lookups expire so a newly arriving service can be identified later.
Razer-vendor services match mouse usage or a known mouse PID, including their keyboard
collections. Other Bluetooth identities require an existing recognised mouse model. HID serials
are never compared with Razer protocol serials. No per-unit preference or migration is used.

The sender accessors (`CGEventCopyIOHIDEvent` and `IOHIDEventGetSenderID`) are undocumented
system interfaces, resolved dynamically. If unavailable, the switch is disabled. The HID
event is used only to identify the sender; reversal changes the CGEvent line, pixel and
fixed-point fields. The contributor confirmed CGEvent-only reversal works in Safari and a
native `NSEvent.scrollingDelta` reader on their Basilisk V4 HyperSpeed. Hardware behaviour
on other models and macOS versions still needs validation.

Preview: `swift run MacRazer render-settings reversed /tmp/scrolling-settings.png`.
The preview uses a fixed scratch defaults suite, removed before and after rendering.

### 6.4 Device test, `DeviceTest*.swift` + the Worker
The right-click menu's **Help Support This Mouse…** (or **Test This Mouse…** on a verified
model) runs a guided test and builds a report a maintainer can turn into a registry entry.

- `DeviceTest.swift`: the steps (Identify, Battery, DPI, Polling rate, Lighting) as plain
 functions over a channel, the report, and the verdict. Each step puts back what it changes
 before it returns, on every path. Tests drive them against a fake mouse.
- `DeviceProbeSession.swift`: transaction id discovery (every id OpenRazer uses is tried, and
 each result recorded) and the channel that records every command for the report.
- `DeviceTestModel.swift` / `DeviceTestView.swift` / `DeviceTestWindowController.swift`: the
 window. Steps run on `MouseController`'s device queue with the app's own reads paused. Quit
 waits for a running step. The full test needs the cable or dongle.
- After Identify, `DeviceTestSteps.capabilities` asks a fixed list of read-only commands once
 (`capabilityReads`: polling_rate2, idle time, scroll settings, profile slots, the per-zone
 effect for every LED id) and, when the button function read answers, the whole button table
 (`readButtonTable`). When no transaction id answers on the interface MacRazer picked, Identify
 also tries the mouse's other interfaces that can carry the control report
 (`HIDDevice.withOtherControlInterfaces`); an answer there means the interface pick is wrong
 for that mouse.
- A mouse on Bluetooth gets a shorter, read-only test (`DeviceTestSteps.bluetoothTest`, the
 window's **Bluetooth test**, or the `bluetoothtest` command). `BluetoothProbe.swift` opens its
 own CoreBluetooth connection, after `MouseController.releaseBluetoothForDeviceTest` closes the
 app's, and reads the GATT services, the PnP ID, the standard battery level and a list of keys
 over Razer's service (`bluetoothReads`). The report has `connection: bluetooth` and a
 `bluetooth` section. Identify is not on the mouse when there is no Razer service, and fails
 when the probe never saw any services (Bluetooth off or not allowed).
- The intro follows the registry row for the connected link (`DeviceTestModel.Support`). Fully
 supported: no test needed, with Test anyway for after a firmware update. Partly supported:
 what works, what still needs testing, and **Test what's missing**, which runs Identify and
 only those steps (`DeviceTestFlow.skipped`). The steps it passes over are recorded as skipped
 with "Already verified", so the report keeps the Worker's format and its verdict reads
 "Partly tested". Both intros also name the mouse's other links still worth a report
 (`RazerDevices.linksToTest`): any row for another link that isn't fully supported, and a
 cable or dongle without a row for a mouse with a battery. Bluetooth only from a row.
- `DeviceReportOutput.swift`: Copy, the GitHub issue, size fitting, and text limits.
 `DeviceReportSender.swift`: Send, a POST to the Worker.
- **In MacRazer MX** none of this runs: `WorkerEndpoint.base` is always `nil` and
 `build-app.sh` writes no address, so Send is hidden. The report windows' failure text and
 links go to the fork's issues (`ProjectLinks.contact`, `ProjectLinks.newIssue`). What follows
 is how upstream does it.
- `WorkerEndpoint` (`AppInfo.swift`): the Worker's address, from the bundle's Info.plist, where
 `Scripts/build-app.sh` writes it from DOMAIN in the maintainer's private settings file. It is
 never in the repository. A build without it (a clone, a fork, CI, `swift run`) hides Send and
 the reply address, and has no usage stats at all. `MACRAZER_WORKER_URL=http://127.0.0.1:8787`
 points a development build at `wrangler dev`.
- The Worker: a Cloudflare Worker that checks a report against the app's exact format, emails it
 to the maintainer, and keeps only daily counters. Its code and setup are in the private
 SorcRR/macrazer-worker repository. The contract between the two is the fixtures in
 `Tests/MacRazerTests/Fixtures/worker/`: the app's tests write them, and the Worker's CI fetches
 them from this repository and tests against them.

### 6.5 Support prompt, `SupportPrompt.swift` + `SupportPromptView.swift`
Asks someone whose mouse could still use a report (`RazerDevices.needsReport`) to run the
device test (§6.4), instead of relying on them finding the menu item.

- **Which mouse.** The connected mouse when a report would help: not on record, partly verified
 on this link, or verified here while another way it connects isn't
 (`RazerDevices.linksToTest`). On Bluetooth only the last kind, since the full test needs USB. With no mouse connected, an unverified one from `HIDDevice.razerMice()` when Input
 Monitoring is missing. The window then reads "We found a new Razer mouse" and leads with the
 permission. That list is refreshed from the plug monitor (`HIDMonitor`), a second after each
 burst of events, and only while it can matter: the prompt is on and the permission is missing.
 Turning the setting on refreshes it too.
- **When.** `SupportPromptPolicy`, keyed by PID: the cable, dongle and Bluetooth PIDs of one
 mouse are separate links that each need testing, while a second unit of the same model is not.
 The first ask, one reminder after 7 days, then no more windows. Never again after a report is
 sent, or after "Don't ask for this mouse" or Hide. A model later promoted to `fullySupported`
 stops asking without anything clearing its record. Records live in `UserDefaults`
 (`supportPrompt.records`).
- **The moment.** A 5 s timer in `AppDelegate` checks that no window, popover or menu is open,
 starting 10 s after launch so the setup window can come first. It asks only when the same
 mouse is read on two ticks in a row: the controller publishes a new mouse's fields one at a
 time, and a tick in between could pair one mouse's id with another's name.
- **What counts as reported.** `trackReports` watches the device test's Send. Opening the GitHub
 issue counts only in a build that can't send (no `WorkerEndpoint`), since nothing says the issue
 was filed.
- **What it says.** Three versions, from `RazerDevices.support`: the full test for an unknown
 mouse; for a partly verified one, what works, what's missing and "Run the Test" (the test then
 offers to check only what's missing); for one verified here, which other links still need a
 test and how to switch, with "Got It" instead of a test, since there's nothing to run on this
 link. Got It ends the ask like "Don't ask for this mouse". A row with `hasCableLink: false`
 (the AA-cell mice) is never asked about a cable.
- **The popover card.** At the top of the main page while `showsCard` holds. It stays after the
 window has stopped asking, because it only shows when the person opens the popover anyway.
- **Turning it off.** Settings › General › Ask me to help test my mouse (`supportPrompt.enabled`,
 on by default) silences both the window and the card.

### 6.6 Usage stats, `UsageStats.swift` + the Worker
**Off in MacRazer MX** (no Worker, §6.4), so everything below is upstream's behaviour and is
never reached.

Opt-in only. Nothing is sent until the person clicks Share. In a build without the Worker (see
`WorkerEndpoint` above) nothing is asked, Settings has no Privacy page, and nothing is sent.

- **Asking.** A new install gets `UsageStatsConsentView` in its own window, once nothing else is
 on screen (the setup window comes first). Someone updating gets `UsageStatsCard` in the
 Updated window instead. Closing either without answering counts as no, and it isn't asked again.
- **The ID.** An HMAC-SHA256 of the hardware UUID (`IOPlatformUUID`) with a fixed app key,
 cut to 16 bytes of hex. The same Mac gets the same ID after a reinstall, the UUID never leaves
 it, and the result can't be matched with what another app gets from the same UUID. It's saved
 in the preferences once worked out, so a UUID that changes in a macOS upgrade doesn't make a
 new Mac.
- **When.** `UsageStatsPolicy`: a `first` ping when nothing was reported yet, `update` when the
 version changed, `mouse` when a mouse connects that this Mac hasn't reported. Launch waits 15 s
 for a mouse, then sends anyway. A failed ping is simply due again, at the next launch or mouse. `swift run` builds never
 send.
- **What.** `UsagePing`: the ID, the event, app and macOS versions, the chip (from
 `hw.optional.arm64`, so Rosetta still counts as Apple Silicon), and the connected mouse with its
 product ID, link and whether it's supported. Settings › Privacy shows this exact JSON.
- **Delete My Data.** Turns sharing off and sends `DELETE /v1/stats/<id>`. The Worker moves the
 row to tables without the ID. If the server can't be reached, the delete is kept and retried at
 every launch and whenever a mouse connects, and no ping goes before it succeeds.
- **Seeing the numbers.** `npm run stats` in the Worker's repository prints a summary.

### 6.7 Updates, `UpdateChecker.swift` + `UpdateInstaller.swift`
**Off in MacRazer MX.** `AppInfo.updatesEnabled` is `false`. The fork publishes no release feed
of its own, and an update check that found upstream's releases would offer to install them over
the fork, replacing it with an app that lacks its features. While it is false
`AppDelegate` doesn't call the checks (`checkForUpdatesNow`, `checkForUpdatesIfDue`), the
right-click menu has no Check for Updates…, the Updates pane is left out of Settings
(`SettingsView.panes`, and the version row reads "Update checks are off"), and a new version is
recorded and its announcement dismissed at launch (`dismissAnnouncement`) instead of shown. The
updater is otherwise intact and unreachable, so upstream merges stay simple. To update the fork,
pull and run `./Scripts/build-app.sh`. `ProjectLinks.releasesAPI` and the other release URLs point
to `cortinadev/MacRazer-MX`, so if updates are ever switched on they never read upstream's
releases. `ForkIdentityTests` fails if `updatesEnabled` or any of these links changes. The rest
of this section is upstream's design.

No Sparkle: the app is self-signed and shipped as a plain DMG, so there is no appcast. Updates
come from GitHub Releases.

- **Checking.** At most every **3 hours** (`checkInterval`), from launch and a repeating timer,
 plus the menu's Check for Updates…. A build with a Worker asks it first: it passes on GitHub's
 release list and counts the Mac as active for the day by a salted hash of its IP. The check
 itself sends only the app version. Any failure there falls through to GitHub directly, so the Worker can never cost
 anyone an update. One exception skips the throttle: the version just changed and there are no
 notes for it yet.
- **Anonymous daily count.** `AnonymousCountReporter` sends the same Worker request with the
 connected mouse models and the usage stats answer (`stats=yes|no|unasked`), so the reports page
 can count mice in use and how many share. A change of answer is noted in `UsageStats` and goes
 with the next count (`change=said_yes|said_no|turned_off|turned_on`, Delete My Data counts as
 turned off) until the Worker has it. Always on, anonymous like the check. A count goes out
 when there's something new: the first of each UTC day, a mouse not sent yet that day, or a
 changed answer. A failed
 send is silent and retried on the 15-minute tick, at wake and when the network returns. It
 used to ride on the update check, which runs at launch before the mouse is found and then only
 every 3 hours, and missed about half the mice.
- **Release notes.** `ReleaseSpan` picks every published release between the running version
 and the new one, so someone skipping versions reads all of them, not only the latest.
 `ReleaseNotes.parse` turns each GitHub body into a summary and sections, and keeps anything it
 can't classify as plain text. `ReleaseNotesList` draws them the same way on the What's new page
 and in the Updated window. Versions compare as dotted integers (`VersionCompare`).
- **Installing.** "Update & Restart" downloads the DMG, mounts it, and checks the app inside
 (`UpdatePayloadCheck`: the same bundle id, a newer version, an intact signature). Then it swaps
 the bundle in place with `replaceItemAt` and relaunches (`AppRelaunch`). Swapping at the same
 path with the same signing identity keeps the Input Monitoring grant and the login item.
 Where the app can't replace itself (`AppLocation`: still on the disk image, translocated by
 Gatekeeper, in a temp folder, or on a read-only volume), the card offers the plain DMG download
 instead.
- **Automatic installs.** Settings › Updates › Install updates automatically (`autoInstallUpdates`,
 **off by default**). `AutoInstallPolicy` (pure) allows one attempt per version per session,
 never while busy or while anything is on screen (§6.1). A failure about the payload (not a
 newer MacRazer, broken signature) is final for that version. Any other failure is retried at
 the next chance, since the app can run for weeks.
- **After an update.** `UpdateAnnouncement` compares the running version with the last one that
 ran. On the first launch of a new version the Updated window (`UpdatedView.swift`) says the
 update worked and shows what it brought. A first install never claims to be an update, and a
 downgrade is still announced.

### 6.8 Settings, setup and About windows
- **Settings**, `SettingsView.swift` / `SettingsWindowController.swift`: settings for the app
 itself, in a window rather than the popover. Opened with ⌘, from the menu or the popover's
 gear. One fixed size, with a sidebar of pages, the version and update status at its foot.
 Escape and ⌘W close it. Pages:
 - **General**: Start at login, connection sounds (`connectionSoundsEnabled`), battery % in the
 menu bar (hidden for mice without a battery), crash reports (hidden while crash reporting is
 off, §6.9), Ask me to help test my mouse (§6.5).
 - **Privacy** (only in a build with the Worker): usage stats and deleting what's stored (§6.6).
 - **Appearance**: Theme, Glass effect and Two-column popover (§6.2).
 - **Updates**: Install updates automatically, the version, and Check Now.
- **Start at login**, `LaunchAtLogin.swift`: `SMAppService.mainApp`, which also lists MacRazer
 in System Settings › General › Login Items. On by default, applied once, on the first launch
 from a real installed location. After that the person's choice stands, including one made in
 System Settings.
- **Setup & Permissions**, `PermissionsView.swift` / `PermissionsWindowController.swift`:
 opens on the very first launch and from the menu. It explains Input Monitoring and
 Accessibility, shows their live state from `PermissionsModel` (`Permissions.swift`) and asks
 for them with the system prompts. `SystemSettingsPanes` holds the deep links into System
 Settings. Input Monitoring only applies after a relaunch, which the window offers.
- **About**, `AboutView.swift` / `AboutWindowController.swift`: version and build, what's new in
 this version, the credit to OpenRazer (the protocol source, and why the project is GPL), and
 the statement that MacRazer is not made by Razer.
- Shared window styling: `titledSection` and the popover's `card` live in `CardComponents.swift`.

### 6.9 Crash reports, `CrashReport*.swift`
Built and tested, but **switched off** (in MacRazer MX it stays off, with no Worker):
`CrashReporting.deliver` is nil until the Worker accepts crash reports. The crash scanner
looks for the fork's bundle ID (`CrashReportParser.bundleID`). While it is nil the app doesn't look for crashes, never shows the window and
hides the setting.

- On launch the app looks for `.ips` files macOS wrote for MacRazer since it last looked
 (`crashReportsHandledThrough`) and offers the newest one.
- `CrashReport` is a summary, never the file: versions, the Mac model, Rosetta, the exception,
 the termination reason, the crash message, the crashed queue and thread, and the Objective-C
 exception's stack. The file's username paths, `crashReporterKey`, boot IDs and registers are
 left out. Stacks are cut to fit the size limit, and the report says so.
- `CrashReportView` shows exactly what would be sent, with an optional comment and reply email
 (`ReportComment` trims comments to fit, shared with device reports). The window doesn't take
 focus, since it usually appears at login while the person is busy with something else.
- Settings › General has the switch (`offerCrashReports`).

---

## 7. Permissions & code signing

| Permission | Why | How |
|---|---|---|
| **Input Monitoring** | Razer mice enumerate as keyboard/mouse HID; macOS gates opening them. Also needed to see the DPI button: its F20 key through the tap (Basilisk V3 X) and its private keys in driver mode (Cobra, `DpiPrivateKeyWatcher`, §6.3.3). Without it the Cobra's DPI button keeps cycling DPI in the firmware; granted while the app runs, it takes effect once MacRazer MX is reopened (seen on macOS 26.3), which the Buttons page says and offers a button for. | Requested at launch via `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`; in-app banner + settings link. Also asked once a run, the first time it is what the DPI button is missing (`ButtonRemapper.askForInputMonitoring`), so macOS lists the app with a switch. On macOS 27.2.1 with an ad-hoc signed build, after a `tccutil reset`, the app still did not appear in the list and had to be added with the + button; the cause is not established. |
| **Accessibility** | The `CGEvent` tap for button remapping, gestures and scroll reversal. A DPI button action on the Cobra needs it together with Input Monitoring. | `AXIsProcessTrustedWithOptions`; Open Settings / Re-check in the relevant controls. |
| **Bluetooth** | A mouse on Bluetooth is reached through CoreBluetooth. | Asked the first time such a mouse is found (`NSBluetoothAlwaysUsageDescription`). |

**The fork's bundle ID is `com.cortinadev.macrazer-mx`** (upstream's is `com.macrazer.menubar`),
set in `Packaging/Info.plist` and in both `codesign --identifier` calls in `Scripts/build-app.sh`.
macOS keeps these grants, and the app's preferences, per bundle ID, so MacRazer MX starts with
none of upstream's: grant Input Monitoring and Accessibility to "MacRazer MX" again. The tap only
asks for key events once the DPI button of a mouse using F20 has a software action; if macOS
refuses them, remapping carries on with mouse events only and the page offers an Input
Monitoring button. A mouse with private keys never asks for key events.

**Signing matters for permissions.** TCC binds a grant to the app's code identity. The
build is **ad-hoc signed by default, so every rebuild changes the identity and breaks the
grant** (the toggle looks on but doesn't apply). Fixes:
- `Scripts/setup-signing.sh` creates a **stable self-signed identity** ("Razer Cobra
 Self-Signed"); `build-app.sh` auto-uses it. Grant persists across rebuilds.
- Or just develop with `swift run MacRazer`, which inherits the Terminal's grants.
- `tccutil reset ListenEvent com.cortinadev.macrazer-mx` clears a stale Input Monitoring grant
 (`tccutil reset Accessibility com.cortinadev.macrazer-mx` for Accessibility).

For distribution to other users: every user still grants Input Monitoring once (unavoidable
macOS security). Self-signed = works but Gatekeeper blocks the first launch. On macOS 15+ the
dialog only has Done, and the user has to click Open Anyway in System Settings > Privacy &
Security (or run `xattr -cr`). Right-click > Open only gets past it on macOS 14 and earlier. A
clean install needs Developer ID + notarization (paid Apple account).

---

## 8. Extending to other Razer mice

Detection + name display already work for any Razer mouse (read-only, via the USB product
string). The device test (§6.4, or `devicetest` in §9) gathers what the steps below need
in one run. To make the **controls** verified for another model:
1. Add its PID/name to `RazerDevices.known` with `unverified: []` (or the features a report
 hasn't shown working yet) and the right
 `hasBattery` / `hasLighting` / `maxDPI`. If its brightness answers on a group other than
 `LOGO_LED`, set `brightnessLed` too.
2. Confirm its command dialect matches the Cobra Pro set (transaction id, command variants,
 max DPI, poll rates, LED layout, brightness LED). Port any per-device specifics from
 OpenRazer's `razermouse_driver.c` switch statements / `daemon/.../mouse.py` METHODS.
3. Test each control on hardware (use the CLI diagnostics, §9).

If a model uses a different dialect, generalize `RazerCommands` / add a per-device command
table keyed by PID.

---

## 9. CLI diagnostics

Run from a terminal (uses the Terminal's permission grant). These were how each feature was
verified against hardware:

```sh
swift run MacRazer info # list HID interfaces (find the control one)
swift run MacRazer battery # read battery %
swift run MacRazer dpi [x] [y] # read / set DPI
swift run MacRazer stages # read (and optionally write) the onboard DPI stage table
swift run MacRazer poll [125|500|1000]
swift run MacRazer rgb static ff0000 # or: spectrum | wave [speed hex, lower is faster] | off
swift run MacRazer rgb breathing ff0000 # one colour; two for dual, none for random
swift run MacRazer brightness [0-100] # sweeps LOGO/SCROLL/ZERO/BACKLIGHT LEDs
swift run MacRazer discover # which transaction ids the mouse answers to
swift run MacRazer devicetest # the device test without its window, as JSON on stdout
"MacRazer MX.app/Contents/MacOS/MacRazer" bluetoothtest # the read-only Bluetooth test, as JSON; needs the bundle's Info.plist, and the app quit
swift run MacRazer render-device-test review ran sent out.png # one test screen (dev)
swift run MacRazer login-item [on|off] # the "Start at login" registration
swift run MacRazer icon out.png # render the menu bar icon
swift run MacRazer icon-models [dir] # each model's header silhouette
swift run MacRazer appicon [dir] / iconset [dir] # app icon concepts / the .iconset for iconutil
swift run MacRazer render-ui [offline|color|update|updated|whatsnew|…] out.png # popover (dev)
swift run MacRazer render-ui whatsnew installed out.png # the notes without an update to install
swift run MacRazer render-ui keyboard|pad|three [follow|synapse [macrazer]|wave] out.png # accessories next to the mouse
swift run MacRazer render-ui pad color out.png # the colour page naming the pad it sets
swift run MacRazer render-ui twocolumns out.png # two columns with only the mouse
swift run MacRazer render-ui pad color twocolumns out.png # the wide colour page
swift run MacRazer render-remap wide out.png # the two-column Buttons page
swift run MacRazer render-about [notes] out.png
swift run MacRazer render-remap out.png
swift run MacRazer render-support-prompt [noaccess] out.png # the support prompt window
swift run MacRazer render-settings out.png
swift run MacRazer render-updated [nonotes] out.png # the window after an update
swift run MacRazer render-usage-consent out.png
swift run MacRazer render-crash-report [sent] out.png
swift run MacRazer render-permissions out.png
```

(The `render-*` commands use SwiftUI `ImageRenderer`, which can't rasterize native controls —
buttons and sliders show as placeholders. It can't rasterize a `ScrollView` either, so
`render-ui whatsnew`, whose page *is* a scroll view, goes through an `NSHostingView` instead;
that path draws the content but needs an explicit size, since there is no window to supply one.)

---

## 10. File map

| File | Responsibility |
|---|---|
| `main.swift` | Entry point: no args to menu bar app; subcommands to CLI diagnostics. |
| `AppDelegate.swift` | `NSStatusItem`, popover, right-click menu, HIDMonitor wiring, permission request. |
| `MouseController.swift` | Orchestrator: poll loop, connection logic, writes, battery, published state. |
| `HIDDevice.swift` | IOKit HID open/enumerate + request/response send. |
| `HIDDeviceSelection.swift` | Which device and interface to open; tells mice from keyboards. |
| `HIDMonitor.swift` | IOKit service notifications for plug/unplug. |
| `SliderScroll.swift` | Scroll wheel and trackpad scrolling on the popover's sliders. |
| `RazerAccessories.swift` | Keyboards and mousepads whose lighting MacRazer sets (PID, kind, transaction id, LEDs, effects), their interface pick, Synapse detection. |
| `AccessoryController.swift` | `Accessories`, the list of plugged-in accessories, and one `AccessoryController` each: its own device and queue, follow-the-mouse, who sets colours while Synapse runs. |
| `AccessoryCard.swift` | An accessory's popover card, and the lighting controls it shares with the mouse's row (swatches, sliders). |
| `RazerTransport.swift` | Transport protocol shared by USB and Bluetooth, plus the shared retry ladder. |
| `BLEProtocol.swift` | Bluetooth LE framing and `RazerReport` translation, DPI button entry 0x60 (`DPIButtonBinding`, `parseDpiButtonBinding`), device mode (`DeviceMode`, `deviceModeRequest`), `DPIStageTable.nextStage()`. |
| `BluetoothDevice.swift` | CoreBluetooth connection to Razer's vendor GATT service; the DPI button's read-first, read-back write (`writeDpiCycleBinding`), `setDeviceMode` (read first, one write, read back), the trace's GATT and probe hooks. |
| `BluetoothProbe.swift` | The device test's own Bluetooth connection: GATT services, PnP ID, battery, read-only keys. |
| `StatusItemClick.swift` | Whether a menu bar icon click opens the popover or the right-click menu. |
| `FormControls.swift` | The windows' text fields, comment boxes and choice buttons. |
| `RazerReport.swift` | 90-byte `razer_report` struct + CRC. |
| `RazerCommands.swift` | Command-byte builders (battery/DPI/poll/RGB/brightness) + Razer constants. |
| `RazerDevices.swift` | PID to {name, supported, hasBattery} registry; `dpiButtonPrivateKeys` marks a mouse that reports its DPI button as private keys in driver mode (the Cobra HyperSpeed). |
| `DpiPrivateKeys.swift` | The DPI button's private keys (`DpiButtonPrivateKeys`), report 4 parsing (`PrivateKeyReport`), `PrivateKeyTracker`, and `DpiPrivateKeyWatcher` (an `IOHIDManager` on one Bluetooth mouse; fork). |
| `DpiDriverMode.swift` | `DpiDriverModeState` and the pure `DpiDriverModeBook`: when driver mode is engaged, re-checked, retried and restored (fork). |
| `BatteryHistory.swift` | Sample log + learned discharge rate + time estimate. |
| `PopoverView.swift` | Main popover UI + page navigation. |
| `PopoverTheme.swift` | Settings › Appearance: theme, glass, the resolved look, the popover and window backdrops. |
| `ColorPickerPage.swift` | Inline hue/sat colour wheel page + shared `BackButton`. |
| `ButtonRemapper.swift` | CGEvent tap, action model (`RemapAction`, `GestureBindings`, `GestureSlot`), presets, gesture holds, the DPI button (F20 bridge on the Basilisk V3 X, private keys and driver mode on the Cobra), persistence, Accessibility. |
| `GestureDebugLog.swift` | Hidden `gestureDebugLog` default: a trace of gesture holds, F20 timing, pointer deltas, the mouse's HID reports (`GestureDebugHIDWatch`, needs Input Monitoring), the GATT characteristics, unsolicited Bluetooth notifications, read-only probes at connect, device-mode changes and private-key events in `~/Library/Logs/MacRazer MX/gesture.log`; never which key a keyboard typed (fork). |
| `DockSwipe.swift` | The trackpad's dock swipe from a mouse: the event format (`DockSwipe`), `SystemSwipe` and `SystemSwipeSlots`, the pure `DockSwipeTracker`, `DockSwipeOutput` and `DockSwipePoster`. Mission Control, App Exposé and Spaces follow the pointer in a gesture: CGEvent fields on macOS 26 and earlier, an attached IOHIDEvent on macOS 27 (fork). |
| `GestureRecognizer.swift` | `GestureDirection` and the pure `GestureRecognizer`: net movement of one hold to at most one swipe (fork). |
| `RemapView.swift` | Button-config UI (inline + window), gesture editor, DPI button section, key recorder. |
| `RemapWindowController.swift` | Standalone window host for the remap UI. |
| `DeviceProbe.swift` | The probes shared by the CLI and the device test. |
| `DeviceProbeSession.swift` | Transaction id discovery and the recording channel. |
| `DeviceTest.swift` | Device test steps, report and verdict. |
| `DeviceTestModel.swift` / `DeviceTestView.swift` | Device test window: flow and screens. |
| `DeviceTestWindowController.swift` | Window host for the device test. |
| `DeviceReportOutput.swift` | Copy, GitHub issue, size fitting and text limits for reports. |
| `DeviceReportSender.swift` | Send: posts a report to the Worker. |
| `SupportPrompt.swift` | When to ask for a device test, and the per-model records. |
| `SupportPromptView.swift` | The support prompt window and its controller. |
| `UsageStats.swift` | Opt-in usage stats: the ID, when to ping, Delete My Data. |
| `UsageStatsView.swift` | The consent window, the Updated window's card, the shared summary. |
| `ButtonCapture.swift` | Listens to the Razer device's buttons during the test. |
| `BatteryPollStateMachine.swift` | Poll cadence, offline debounce, reconnect and charging checks. |
| `HIDInputWatcher.swift` | Polls at once when the mouse sends input after sleeping. |
| `DischargeCurveModel.swift` | Learned time at each battery percent. |
| `ChargeCycleHistory.swift` | Rolling log of finished charge cycles. |
| `LastBatterySnapshotStore.swift` | The last trusted battery reading per mouse. |
| `LowBatteryNotifier.swift` | The low battery notification and when it re-arms. |
| `Persistence.swift` | Versioned, atomic, throttled JSON files for the per-device stores. |
| `UsageGraphView.swift` | The popover's battery usage page. |
| `MouseProfile.swift` | Profiles: the saved snapshot, lighting effects, per-device storage. |
| `ProfilesView.swift` | The popover's page for managing profiles. |
| `DPIStageAccent.swift` | Colours that tell the DPI stages apart in the UI. |
| `CardComponents.swift` | Shared card styles and battery thresholds. |
| `PopoverFocusReturn.swift` | Whether closing the popover gives focus back. |
| `AppWindows.swift` | `AppWindowPresenter`: every window, for the "anything open?" check. |
| `UpdateChecker.swift` | Finds releases, downloads, installs, the announcement after. |
| `UpdateInstaller.swift` | Checks a downloaded app and swaps it in place. |
| `AutoInstallPolicy.swift` | When an automatic install may start. |
| `UpdateAnnouncement.swift` | Whether this launch is the first on a new version. |
| `UpdatedView.swift` / `UpdatedWindowController.swift` | The window after an update. |
| `ReleaseNotes.swift` / `ReleaseSpan.swift` / `VersionedNotes.swift` | Parsing and picking release notes. |
| `WhatsNewPage.swift` | The popover's What's new page and the shared notes list. |
| `VersionCompare.swift` | Dotted-integer version compare. |
| `AppLocation.swift` | Whether the app is at a stable, writable install location. |
| `AppRelaunch.swift` | Opens a new instance, for updates and the permission relaunch. |
| `LaunchAtLogin.swift` | Start at login via `SMAppService`. |
| `SettingsView.swift` / `SettingsWindowController.swift` | The Settings window. |
| `Permissions.swift` | Permission state and System Settings links. |
| `PermissionsView.swift` / `PermissionsWindowController.swift` | The setup and permissions window. |
| `AboutView.swift` / `AboutWindowController.swift` | The About window. |
| `CrashReport.swift` / `CrashReportModel.swift` | Crash summaries and the window's state (off for now). |
| `CrashReportView.swift` / `CrashReportWindowController.swift` | The crash report window. |
| `ReportComment.swift` | Trims a report's comment to fit. |
| `PreviewNotes.swift` | Sample release notes for the `render-*` commands. |
| `MenuBarIcon.swift` | Vector-drawn menu bar mouse icon (+ triskelion). |
| `RazerLogo.swift` | Embedded official Razer logo (vector PDF, base64) for the header. |

Tests added by the fork, in `Tests/MacRazerTests/`:

| File | Covers |
|---|---|
| `GestureRecognizerTests.swift` | The recogniser alone: threshold, dominant axis, one swipe per hold, net movement. |
| `ButtonRemapperGestureTests.swift` | Gesture holds through `ButtonRemapper.handle`: swallowing, pausing, cancel rules, defaults, persistence, tap mask. |
| `DpiButtonGestureTests.swift` | A gesture on the DPI button of a mouse using F20 (the Basilisk V3 X), driven by F20 and pointer moves. |
| `DpiButtonPrivateKeyTests.swift` | The Cobra's DPI button in driver mode: report 4 parsing and the tracker, report 5's notifications, a gesture held on the long key, the short key as Click (None does nothing, DPI Cycle cycles once), DPI Cycle in a direction and inert elsewhere, other actions, resets, the watcher and its retry, what driver mode needs and when the permissions are looked at again, a new gesture and a saved one, the editor's choices and status texts. |
| `DpiDriverModeTests.swift` | When driver mode is read, written, retried and restored (`DpiDriverModeBook`), the settling checks and the notification checks after a wake, a disconnect dropping a pending restore, the Cobra's sleep and wake trace replayed, `BluetoothDevice.setDeviceMode` with a mouse made of closures, and the error text. |
| `DockSwipeTests.swift` | Dock swipes alone: which presets are system swipes, the tracker's dead zone, axis lock, sign, clamp, end versus cancel and velocity, the scale, the event fields, the poster's repeated end, the method by macOS version, the macOS 27 attached IOHIDEvent and its sign (those tests skip where the app does not use that method). |
| `InteractiveSwipeTests.swift` | Interactive swipes through `ButtonRemapper.handle`: following a hold, other actions firing once, resets cancelling, and a swipe ended by the DPI button's release. |
| `SystemSwipesFollowPointerTests.swift` | The setting that turns the following swipes off (`systemSwipesFollowPointer`): the default, each preset as a shortcut once at 50 points for a mouse button and the Cobra's long press, a change cancelling a swipe or ending a hold, the global saved key, the editor's text. |
| `DpiCycleSoftwareBridgeTests.swift` | The DPI button's saved action and entry: confirmation and restore gating, the Cobra over Bluetooth only, the safe write path, error text. |
| `ForkIdentityTests.swift` | Bundle ID and name everywhere they are written, the "MacRazer MX" data folder, no Worker, updates off, links to the fork. Fails if an upstream merge brings upstream's values back. |

The fork also changed `CrashReportTests`, `DeviceReportOutputTests`, `IssueReportTests`,
`RazerDevicesTests`, `ShortcutFlagsTests` and `UpdateAndLaunchTests` for the new identity,
links and presets.

The Cloudflare Worker behind Send and the usage stats is upstream's, in the private
SorcRR/macrazer-worker repository. MacRazer MX never contacts it. `Tests/MacRazerTests/Fixtures/worker/` holds the fixtures it tests against.

External: `reference/openrazer/` (cloned driver source, the protocol reference, gitignored)
and `reference/openrazer-pr-2583.diff` (the Cobra HyperSpeed PR).
