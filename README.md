# MacRazer MX: Razer mouse control for macOS

> **MacRazer MX is a fork of [MacRazer](https://github.com/SorcRR/MacRazer) by
> [SorcRR](https://github.com/SorcRR)** (GPL-2.0-or-later), maintained by
> [cortinadev](https://github.com/cortinadev) at
> [cortinadev/MacRazer-MX](https://github.com/cortinadev/MacRazer-MX). Everything below that
> isn't listed here is upstream's work, and the credit for it is theirs.
>
> **What it adds**
> - **Gesture mode** for the mouse's extra buttons: hold a button and move the mouse up, down,
>   left or right to run a different action for each direction (Mission Control, App Exposé,
>   a Space to the left or right by default). See [Gesture mode](#gesture-mode).
> - **DPI button remap** on the Razer Cobra HyperSpeed over Bluetooth, as well as the Basilisk
>   V3 X HyperSpeed, where upstream only has it. The button can take any action, a gesture
>   included. See [The DPI button](#the-dpi-button).
>
> **What is different from upstream**
> - **No update checks.** The fork has no release feed of its own, and must never offer
>   upstream's releases, which would replace it with an app that lacks these features. To update,
>   pull and build again.
> - **No reporting.** It never contacts upstream's report server, so it sends no usage counts,
>   crash reports, issue reports or device reports. Where upstream offers an email address, the
>   app points to this fork's [GitHub issues](https://github.com/cortinadev/MacRazer-MX/issues).
> - **Its own identity**: the app is "MacRazer MX", bundle ID `com.cortinadev.macrazer-mx`, with
>   its own preferences and its own Application Support folder. It can be installed next to
>   upstream's MacRazer, but **don't run both at once**: both would talk to the mouse and install
>   event taps. macOS also treats it as a different app, so Accessibility and Input Monitoring
>   have to be granted to it again.
> - **No published releases.** You build it from source (see [Build and run](#build-and-run)).
>
> The gesture and DPI button features have so far been exercised by unit tests only. The DPI
> button remap is enabled for the Cobra HyperSpeed over Bluetooth but **not yet confirmed on
> real hardware** (details [below](#the-dpi-button)).

A native menu bar app to control Razer mice on macOS. Razer does ship a Synapse for Mac now,
but its [supported-device list](https://mysupport.razer.com/app/answers/detail/a_id/14809/~/razer-synapse-for-mac-supported-and-compatible-devices)
is short and doesn't include the Cobra HyperSpeed or Atheris — this fills that gap. It talks
to the mouse directly over USB HID (no kernel extension, no driver install), using a protocol
ported from [OpenRazer](https://github.com/openrazer/openrazer).

Upstream's website, whose download and setup help are for upstream's app, not this fork:
[macrazer.com](https://macrazer.com/?utm_source=github&utm_campaign=readme)

Works best with the **Razer Cobra HyperSpeed** and the **Razer Atheris**, the two devices this
has actually been tested on. It detects any Razer mouse by name and should work with other
Razer mice that use the same HID protocol family, but those are untested, so treat support as
"likely to work, not verified" until someone confirms it on real hardware.

> Unofficial. Not affiliated with, authorized by, or endorsed by Razer Inc. See [NOTICE.md](NOTICE.md).

<p>
  <img width="380" alt="MacRazer popover: battery, DPI stages, polling rate, lighting, buttons and profiles" src=".github/screenshots/popover.png" />
  <img width="372" alt="Battery Usage: discharge curve, rate, time left and past charges" src=".github/screenshots/battery-usage.png" />
</p>


## Features

- **Battery** percentage in the menu bar, charging status, and a learned time-until-empty
  estimate. History and the estimate are kept per physical device (by serial number).
- **Battery usage graph**: a chart button beside the battery percentage opens the current
  discharge curve, the discharge rate, time since the last full charge, and a trend chart of
  past charge cycles with their average length.
- **DPI** with a slider (capped at each model's real maximum), the mouse's own preset stages
  read from the device, and a recallable custom value (per device).
- **Polling rate**: 125 / 500 / 1000 Hz.
- **RGB lighting**: static colour via an inline hue/saturation wheel, plus breathing,
  spectrum, wave (with a speed slider), off, and a brightness slider.
- **Sliders follow the scroll wheel**: scroll over any slider in the popover to move it.
- **Low battery alert**: a notification when the battery drops below 15%, once per charge.
- **Profiles**: save DPI, polling rate, lighting and button remaps under a name, and switch
  between them from the popover. Saved per device.
- **Themes**: System, Dark, Light or Razer Green, with an optional glass effect, in
  Settings › Appearance. A two-column popover is there too. It's always used while a keyboard
  or mousepad is connected.
- **Connection sounds** when the mouse connects or disconnects (can be turned off).
- **Button remapping** for the extra buttons (software, via a CGEvent tap): keyboard
  shortcuts (presets or a custom recorder), mouse clicks, media keys, or a **gesture** (hold
  the button and swipe; see [Gesture mode](#gesture-mode)). Saved per device. If another mouse
  app (Mac Mouse Fix, SteerMouse, BetterMouse) takes the side buttons' clicks first, the page
  names it so you know which one to quit.
- **DPI button remap** over Bluetooth on the Basilisk V3 X HyperSpeed and the Cobra HyperSpeed
  (the Cobra's is not yet confirmed on hardware): any action, a gesture included, or back to
  DPI Cycle. See [The DPI button](#the-dpi-button).
- **Reverse scrolling on Razer mice**, under Settings › General. Reverses wheel and tilt
  scrolling on Razer mice while trackpads and other mice keep their directions. Off by
  default and saved once for the app. Requires Accessibility and MacRazer running; it does
  not change macOS's Natural scrolling setting.
- **Any Razer mouse is detected and named.** Controls a model lacks are hidden automatically
  (no lighting on the Atheris, no battery UI on wired-only mice). A Razer keyboard or other
  product that is never a mouse is not taken for one.
- **Keyboard and mousepad lighting.** Each Razer keyboard or mousepad next to the mouse gets
  its own card in the popover, with its own colour, effect and brightness. Each can also
  follow the mouse's lighting. Tested on the Cynosa Chroma, Cynosa Lite, Joro, Ornata V3 and Ornata V3 X
  keyboards and the Firefly V2, Firefly V2 Pro, Goliathus Chroma and Goliathus Chroma Extended
  mousepads. The Cynosa Chroma Pro, the Ornata V3's other versions and the
  Goliathus Chroma 3XL use the same commands but are untested. An untested one's card has a
  Test it button.
- **Asks for help with a new mouse.** When a mouse MacRazer doesn't fully support connects, a
  small window offers the device test (see below). It can be turned off in Settings.
- Settings are written to the mouse's **onboard memory** where supported, so they persist when
  the app is not running.
- **Starts at login** (on by default, switchable in the popover and in System Settings ›
  General › Login Items), so the menu bar item is there after a reboot.
- **No update checks in MacRazer MX.** Upstream's app updates itself from its GitHub
  releases. The fork has switched that off (`AppInfo.updatesEnabled`), so there is no Check for
  Updates item and no Updates page in Settings. You update by building a newer checkout.

Settings persist across app restarts and reconnects, and the menu bar updates on its own when
the mouse connects, disconnects, or sleeps.

## Screens

**Keyboard and mousepad lighting.** With a Razer keyboard or mousepad connected, the popover
goes to two columns. Each device gets a card, and a keyboard can follow the mouse's lighting.

<img width="760" alt="Two-column popover: the mouse's controls, and under Other Razer devices a Cynosa Chroma following the mouse, a Firefly V2 and an Ornata V3 on Wave" src=".github/screenshots/popover-accessories.png" />

**Button remapping.** Point each extra button at a shortcut, a click, a media key or a gesture.

<img width="440" alt="Configure Buttons: Back mapped to Copy and Forward to Paste" src=".github/screenshots/buttons.png" />

**DPI stages.** Click Edit on the DPI card, then a stage, to change its DPI on the mouse itself.

<img width="380" alt="The DPI card in Edit mode: five stage chips with dashed outlines and a hint to click one" src=".github/screenshots/dpi-stages.png" />

**Themes.** Light, Dark or Razer Green, in Settings › Appearance. System follows macOS.

<p>
  <img width="250" alt="The popover in the Light theme" src=".github/screenshots/theme-light.png" />
  <img width="250" alt="The popover in the Dark theme" src=".github/screenshots/popover.png" />
  <img width="250" alt="The popover in the Razer Green theme" src=".github/screenshots/theme-green.png" />
</p>

**Settings.** Reverse scrolling on Razer mice, login, menu bar and sounds.

<img width="780" alt="Settings › General: Start at login, Reverse scrolling on Razer mice, battery percentage in the menu bar, connection sounds, and the device test prompt" src=".github/screenshots/settings-general.png" />

**The device test.** Each step changes one thing, reads it back, then puts yours back.

<img width="440" alt="Device test, DPI step: sets a value 50 away, reads it back, puts the original back, and lists the stages" src=".github/screenshots/device-test.png" />

## Supported mice

The table is upstream's, built from reports sent to upstream. "Maintainer" means SorcRR, and
nothing here has been re-verified for MacRazer MX. Its two additions, gestures and the DPI
button remap, are not in this table: they have only been exercised by unit tests.

"Verified" below means someone ran the CLI probes or the in-app test against the mouse and
posted the output, not that the protocol tables say it should work. Where nobody has, the row
says so.

| Mouse | Verified on hardware | By |
|---|---|---|
| Razer Cobra HyperSpeed (wired + wireless) | Everything, continuously — the development mouse | maintainer |
| Razer Atheris | Battery, DPI, polling | maintainer |
| Razer Basilisk V3 X HyperSpeed | Battery, DPI, DPI stages, polling, lighting, brightness | [@joelday](https://github.com/joelday) |
| Razer Basilisk Mobile (Wireless) | Battery, DPI, DPI stages, polling, static color, brightness | [@oss3](https://github.com/oss3) |
| Razer Viper Ultimate (Wireless) | Battery, DPI, polling, brightness | [@raphaelchenouard](https://github.com/raphaelchenouard) |
| Razer Naga Pro (Wireless) | Battery, DPI, DPI stages, polling, lighting, brightness | [@sidneylopes](https://github.com/sidneylopes) |
| Razer Naga Pro (Wired) | Battery, DPI, DPI stages, polling, lighting, brightness | anonymous report |
| Razer Naga V3 Pro (Wireless) | Battery, DPI, DPI stages, polling, lighting, brightness | [@chris-agnew](https://github.com/chris-agnew) |
| Razer Naga V3 Pro (Wired) | Battery, DPI, DPI stages, polling, lighting, brightness | [@chris-agnew](https://github.com/chris-agnew) |
| Razer Naga Trinity | DPI, DPI stages, polling, lighting, brightness | anonymous report |
| Razer Naga Left Handed Edition | DPI, DPI stages, polling, lighting, brightness | anonymous report |
| Razer Naga Classic Edition | DPI, DPI stages, polling, lighting, brightness | spellbook |
| Razer Lancehead Tournament Edition | DPI, polling, lighting (side strips too), brightness | fortinmike and an anonymous report |
| Razer Viper V3 HyperSpeed | Battery, DPI, DPI stages, polling | anonymous report |
| Razer Basilisk V3 | DPI, DPI stages, polling, lighting, brightness | SuperSpacer54376 |
| Razer Basilisk V3 35K | DPI, DPI stages, polling, lighting, brightness | anonymous report |
| Razer Basilisk V3 Pro (wired + wireless) | Battery, DPI, DPI stages, polling, lighting, brightness | anonymous reports |
| Razer Viper V3 Pro (Wireless) | Battery, DPI, DPI stages, polling (it has no lighting) | anonymous report |
| Razer DeathAdder V2 | DPI, DPI stages, polling, lighting, brightness (wired only) | anonymous reports |
| Razer DeathAdder V2 X HyperSpeed | Battery, DPI, DPI stages, polling (it has no lighting) | anonymous report |
| Razer Basilisk V2 | DPI, DPI stages, polling, lighting, brightness | anonymous report |
| Razer DeathAdder Essential | DPI, DPI stages, polling, brightness (its one light is green only) | anonymous report |
| Razer DeathAdder Elite | DPI, polling, lighting, brightness | anonymous reports |
| Razer DeathAdder V3 | DPI, DPI stages, polling (1000 Hz and 500 Hz tested; it has no battery or lighting) | anonymous reports |
| Razer Naga V2 Pro (Wired) | Battery, DPI, DPI stages, polling, lighting, brightness | anonymous report |
| Razer Pro Click V2 (wired + wireless) | Battery, DPI, DPI stages, polling | anonymous reports |
| Razer Pro Click (wired + wireless) | Battery, DPI, DPI stages, polling (it has no lighting) | anonymous reports |
| Razer Viper | DPI, DPI stages, polling, lighting, brightness (wired only) | anonymous report |
| Razer Viper Mini | DPI, polling, lighting, brightness (wired only) | anonymous report |
| Razer Pro Click Mini (wireless) | Battery, DPI, DPI stages, polling (it has no lighting) | anonymous report |
| Razer DeathAdder V4 Pro (wired + wireless) | Battery, DPI, DPI stages, polling (it has no lighting) | anonymous reports |
| Razer Viper Mini Signature Edition (Wired) | Battery, DPI, polling (it has no lighting) | anonymous report |
| Razer Orochi 2013 | DPI, polling | [@raphaelchenouard](https://github.com/raphaelchenouard) and an anonymous report |
| Razer DeathAdder V3 Pro (Wireless, both dongles, and the first one's cable) | Battery, DPI, DPI stages, polling (it has no lighting) | anonymous reports |
| Razer Viper V3 Pro SE (Wireless) | Battery, DPI, DPI stages, polling (it has no lighting) | anonymous report |
| Razer Naga V2 HyperSpeed | Battery, DPI, DPI stages, polling (it has no lighting) | anonymous reports |
| Razer Basilisk X HyperSpeed | Battery, DPI, DPI stages, polling (it has no lighting) | MagnetTileMan |
| Razer Orochi V2 (Wireless) | Battery, DPI, DPI stages, polling (it has no lighting) | anonymous report |
| Razer DeathAdder V3 HyperSpeed (wired + wireless) | Battery, DPI, DPI stages, polling (it has no lighting) | fxaxg and anonymous reports |
| Razer DeathAdder V2 Pro (Wireless) | Battery, DPI, polling, lighting | anonymous reports |
| Razer DeathAdder V2 Pro (Wired) | Battery, DPI, DPI stages, polling, lighting, brightness | anonymous reports |
| Razer Viper Ultimate (Wired) | Battery, DPI, polling, lighting | anonymous report |
| Razer Taipan | DPI, polling; lighting not working yet | anonymous report |
| Razer Basilisk V4 HyperSpeed (wired + wireless) | Battery, DPI, DPI stages; polling confirmed on the cable, not yet over the dongle | anonymous reports |
| Razer Viper V4 Pro (wired + wireless) | Battery, DPI, DPI stages; polling up to 8000 Hz on the cable; over the dongle the rate doesn't change yet, so the picker is hidden there | Robotxm, Kartas and an anonymous report |
| Razer Viper 8KHz | DPI, DPI stages, polling up to 8000 Hz, lighting, brightness (wired only) | anonymous reports |
| Razer Basilisk V4 Pro (wired + wireless) | Battery, DPI, DPI stages, polling up to 8000 Hz, lighting, brightness | by_hlz, Maude and anonymous reports |
| Razer Mouse Dock Pro (with a Naga V3 Pro or Basilisk V4 HyperSpeed) | Battery, DPI, polling up to 8000 Hz; lighting and brightness with a Naga V3 Pro (the dock lights only what the mouse has) | maesta2, Kartas and an anonymous report |
| Razer Mouse Dock V2 Pro (with a Basilisk V4 Pro) | Battery, DPI, DPI stages, polling up to 8000 Hz, lighting, brightness | cparedes and an anonymous report |
| Razer HyperFlux V2 (with the mouse on it) | Battery, DPI, DPI stages, polling; lighting not confirmed yet | anonymous report |
| Razer Naga Chroma | DPI, polling; lighting not working yet | anonymous report |
| Razer Naga Hex V2 | DPI, polling; lighting not working yet | foivos92 |
| Razer Mamba Tournament Edition | DPI, polling; lighting not working yet | anonymous report |
| Razer Naga X | DPI, DPI stages, polling; lighting not working yet | anonymous report |
| Razer Basilisk Ultimate (wired + wireless) | Battery, DPI, DPI stages, polling; lighting hidden for now (it dims over the dongle, but colours didn't show) | anonymous reports |
| Razer Basilisk | DPI, DPI stages, polling, lighting, brightness | anonymous reports |
| Razer DeathAdder V2 Mini | DPI, DPI stages, polling; lighting not confirmed yet | anonymous reports |
| Razer Basilisk V3 Pro 35K (Wireless) | Battery, DPI, DPI stages, polling, lighting, brightness | anonymous reports |
| Razer Basilisk V3 Pro 35K (Wired) | Battery, DPI, DPI stages, polling; lighting not confirmed yet | anonymous reports |
| Razer Basilisk V3 Pro 35K Phantom Green Edition (Wired) | Battery, DPI, DPI stages, polling; lighting not tried yet | anonymous report |
| Razer Mamba Elite | DPI, DPI stages, polling; lighting not confirmed yet | mikey-vivedia and anonymous reports |
| Razer Basilisk Essential | DPI, polling, lighting, brightness; its DPI button keeps its own stages | anonymous reports |
| Razer Basilisk V3 Pro 35K (Bluetooth) | Battery; DPI and lighting not tried yet | anonymous reports |
| Razer Basilisk V4 HyperSpeed (Bluetooth) | Battery; DPI and lighting not tried yet | anonymous report |
| Razer Pro Click V2 Vertical Edition (wired + wireless) | Battery, DPI, DPI stages, polling, a static color, effects (it has no brightness) | [@k6n7frbrtc-hub](https://github.com/k6n7frbrtc-hub), tekumara and an anonymous report |
| Razer DeathAdder Essential (2018) | DPI, polling, brightness (its one light is green only) | anonymous report |
| Razer DeathAdder Essential (White Edition) | DPI, polling, brightness (its one light is white only) | anonymous report |
| Razer Cobra, Cobra Pro (wired + wireless) | Nothing; same protocol family, values from OpenRazer | — |
| Any other Razer mouse | Nothing; detected and named, controls attempted | — |

An unverified mouse is not a broken one. Detection and naming work for any Razer mouse, and
the controls are attempted with values taken from OpenRazer's tables — they usually work. The
column is about who has actually seen it happen.

**Have a mouse that isn't verified?** The quickest way to help is in the app. Right-click the
menu bar icon and choose **Help Support This Mouse…**. It runs the same probes as the
commands below, puts every setting back, and builds the report for you. MacRazer MX has no
**Send** button: you copy the report or open a GitHub issue with it, on this fork's tracker. If part of your mouse is
already verified, the test lists what works and offers to check only what's missing. It also
says which of the mouse's other connections (cable, dongle, Bluetooth) still need a report. On
a verified mouse the item reads **Test This Mouse…**. The window says no test is needed, but you
can still run one to confirm it works on your firmware. The full
test needs the dongle or a cable. A mouse on Bluetooth gets a shorter test that only reads.

You don't have to find the menu item. When an unverified mouse connects by cable or dongle,
MacRazer asks once, when no other window is open. A partly verified mouse is asked about just
what's missing. A mouse verified on one connection but not another (say, the dongle but not
the cable or Bluetooth) gets a note telling you which and how to switch. If you say Not Now, it reminds you once a
week later and then stops. A card at the top of the popover offers the same test until you send
a report or hide it. "Don't ask for this mouse" stops both for that model. If the mouse is
plugged in before Input Monitoring is allowed, the window starts with that permission. To turn
all of this off, use Settings › General › **Ask me to help test my mouse**.

### What a device report contains

You can read the whole report on the last screen before it goes anywhere.

- The mouse's name, product ID and firmware version, and whether it's on a cable or the dongle.
- Its USB interfaces: product IDs, usage pages and report sizes.
- What each step found: which transaction ids the mouse answered to, the battery level, the
  DPI and polling rate it read and wrote back, and the lighting brightness. Every command the
  test sent is listed, with the first 8 bytes of each answer.
- Whether the mouse answers about 30 more read-only commands: newer polling rates, the sleep
  timer, scroll wheel settings, profiles stored in the mouse, saved button functions and each
  lighting zone. These only read, so nothing on the mouse changes. They show which features
  are worth adding for it.
- If the mouse keeps a button function table, every entry in it. With the buttons you press,
  that is most of what's needed to remap them.
- If no transaction id answers, whether the mouse's other interfaces do.
- From the Bluetooth test: the Bluetooth services the mouse has, its standard battery level,
  and which of Razer's Bluetooth commands it answers, button table included.
- Which extra buttons you pressed during the button step, and how many you pressed that
  didn't show up, if you say. On a cable or dongle, also a timeline of the step: when each
  press came, counted from the step opening, and any change of the mouse's DPI or profile
  slot meanwhile. That shows buttons that change DPI inside the mouse. Never the time of day.
- The app and macOS versions.
- Only if you fill them in: a comment, a name to credit, and an email address for a reply.

Never in it: the mouse's serial number, or anything else about your Mac.

Where it goes depends on the button. **Copy** puts it on your clipboard. **Open GitHub issue**
makes it public, so it leaves out your email address; it opens a new issue on
[cortinadev/MacRazer-MX](https://github.com/cortinadev/MacRazer-MX/issues). Upstream's app can
also **Send** a report through its own server. MacRazer MX never contacts that server, so
nothing is sent unless you send it yourself.

Adding a model is a small change to a registry plus on-hardware verification. See
[CONTRIBUTING.md](CONTRIBUTING.md).

### Gesture mode

In Configure Buttons, any extra button can be set to **Gesture…**. Hold the button and move
the mouse up, down, left or right, and that direction's action runs. Press and release without
moving and the **Click** action runs.

- **Defaults** when you choose Gesture…: up Mission Control, down App Exposé, left Space Left,
  right Space Right. Click is what the button did before (Back still goes back, the wheel click
  still middle-clicks).
- **Each of the five slots** takes any ordinary action: a shortcut preset, a recorded shortcut,
  a mouse click, a media key, or None. A gesture can't be nested inside a gesture.
- **The swipe fires once per hold**, as soon as the movement along the stronger axis reaches 50
  points, not at release. Going right and then back again counts as no movement, so it is
  still a click.
- **The system actions are keyboard shortcuts.** MacRazer MX sends the standard macOS shortcuts
  (⌃↑, ⌃↓, ⌃←, ⌃→), so they must be switched on in System Settings › Keyboard › Keyboard
  Shortcuts › Mission Control. If one is off, that swipe does nothing.
- **The pointer is not frozen** while you hold the button; it moves as usual. The button's own
  press, drag events and release are swallowed, so the app under the pointer doesn't see them.
- **Only the extra buttons** (the ones macOS reports as "other" mouse buttons) can be gestures,
  not the left and right buttons. The Click action fires when the button comes back up, so a
  gesture button can't be held to drag.
- Like every remap, it works while MacRazer MX is running and the mouse is connected, and needs
  Accessibility. It only watches for pointer drags while at least one button is a gesture.

### The DPI button

Upstream can turn the **Basilisk V3 X HyperSpeed's** DPI button into another action over
Bluetooth. MacRazer MX enables the same for the **Razer Cobra HyperSpeed over Bluetooth**, and
lets the DPI button take any action, **Gesture…** included. It's a section of Configure Buttons
that only appears for a mouse on Bluetooth that supports it.

**Not yet confirmed on real hardware.** On the Basilisk V3 X this is upstream's tested
behaviour. On the Cobra HyperSpeed it is switched on, and so far only checked by unit tests:
nobody has yet confirmed on a real Cobra that entry `0x60` of its button table is the DPI
button. MacRazer MX is built to fail safe, as described below, but treat it as experimental
there, and please report what you see in an issue.

How it works:

- The mouse keeps what each button does in an onboard function table, and entry `0x60` is the
  DPI button's. For a function the mouse can do itself (a mouse button, a keyboard shortcut it
  can type, or DPI Cycle), MacRazer MX writes that function, and it keeps working without the
  app.
- For anything else (media keys, Double Click, a gesture, a key the mouse can't type) it writes
  **F20** to the entry, so the button types F20. The event tap turns F20 into your action.
  That needs MacRazer MX running with Accessibility, and the tap then also sees key events, so
  **Input Monitoring** may be needed too. An F20 from a keyboard is captured while an action is
  set (not with ⌘, ⌃, ⌥ or ⇧ held).
- **Safety.** Before every write the app reads the entry, and if it can't confirm that the entry
  is the DPI button, or doesn't recognise what is saved there, it writes nothing. After a write
  it reads the entry back and reports a failure if it differs. **DPI Cycle (default)** writes
  the factory function back. The write goes to the mouse's onboard profile 1, so the app only
  writes while the mouse is on that profile and asks you to switch to it otherwise.
- A **DPI-button gesture** is driven by F20 going down and up, plus the pointer's movement. Its
  Click slot starts as **None**, because software can't cycle the DPI.
- **Not supported:** the USB cable and the 2.4 GHz dongle. There the firmware handles the DPI
  button onboard, and the command to rewrite it over USB isn't implemented.

### Buttons MacRazer cannot see

Remapping works by watching macOS mouse events, so it can only reach buttons the mouse
actually reports to the Mac. Some buttons are handled *inside* the mouse and never send
anything, so no app can detect those as they are, MacRazer MX included. The exception is the
DPI button on the mice listed [above](#the-dpi-button), which MacRazer MX can ask the mouse to
turn into an F20 key it does see.

The clearest example of one that stays out of reach is the **Basilisk's multi-function
trigger** (the third side button), which ships assigned to **Razer Hypershift**. Hypershift is
a modifier: held down, it switches every other button to a second onboard layer. The firmware
resolves that layer itself, so pressing the trigger alone puts no report on the wire at all,
verified by watching every HID interface the mouse exposes while it was pressed.

To make it remappable, reassign it from Hypershift to a normal key or mouse button in
Razer Synapse (Windows only, Razer dropped macOS support). The assignment is stored in the
mouse's onboard memory, so it persists on the Mac afterwards and MacRazer MX will then see the
button like any other. Apart from the DPI button's entry and the side-button reset, MacRazer MX
deliberately does not reprogram onboard assignments itself; that would mean reverse-engineering
Synapse, which Razer's EULA forbids.

### Known limitation: two identical mice without a hardware serial

Per-device settings (custom DPI, button remaps, battery history) are keyed by the mouse's own
serial number when it reports one, otherwise by its USB product ID. If you own **two mice of
the exact same model and that model doesn't expose a serial**, both fall back to the same
PID-based key and will share one settings/history file: there's no other stable identifier to
tell them apart. This doesn't affect mixed setups (different models, or models that do report
a serial).

## Requirements

macOS 14 or later, on Apple Silicon or Intel.

**Connect over the 2.4 GHz dongle or a USB-C cable.** That's where Razer exposes its full
control protocol. The **Cobra HyperSpeed and Basilisk V3 X HyperSpeed also work over
Bluetooth**: battery, DPI stages, brightness, a static lighting colour and the DPI button remap.
Polling rate, other lighting effects, custom DPI values and profiles still need the dongle or a cable. On the
Basilisk V3 Pro 35K and Basilisk V4 HyperSpeed, only the battery is confirmed over Bluetooth so far. MacRazer asks for Bluetooth access the
first time it finds the mouse there.

Other models are a plain pointer over Bluetooth, so MacRazer can't read or change anything.
If your mouse has a mode switch, set it to 2.4 GHz. MacRazer tells you when it sees your
mouse on Bluetooth.

## Install

MacRazer MX has no published releases, so you build it from source. You need macOS 14 or
later and Xcode 16 / Swift 6.1 (full Xcode, not only the Command Line Tools, since the build
is universal).

```sh
git clone https://github.com/cortinadev/MacRazer-MX.git
cd MacRazer-MX
./Scripts/setup-signing.sh      # one-time: a stable self-signed identity (see Permissions)
./Scripts/build-app.sh          # produces "MacRazer MX.app"
open "MacRazer MX.app"
```

Move **MacRazer MX.app** to Applications if you want it there. To update, pull and build again.

The app is self-signed, not signed with a paid Apple Developer ID. An app you build on your own
Mac is not quarantined, so it normally opens straight away. If you copy it from another Mac,
or macOS blocks it ("MacRazer MX Not Opened", "is from an unidentified developer", or "is
damaged and can't be opened"), do **one** of:

- Go to System Settings › Privacy & Security, scroll to the bottom and click **Open Anyway**
  next to the MacRazer MX message. Confirm with your password or Touch ID.
- Or, from Terminal: `xattr -cr "/Applications/MacRazer MX.app"`, then open it normally.
- On macOS 14 and earlier you can also right-click (or Control-click) **MacRazer MX.app** in
  Finder, choose **Open**, then **Open** again. macOS 15 removed this shortcut.

On first launch it asks for **Input Monitoring** (and **Accessibility** for button remapping or
scroll reversal); see [Permissions](#permissions) below.

**Running it next to upstream's MacRazer.** The two have different bundle IDs and data folders,
so both can be installed. Quit one before starting the other.

## Build and run

To build from source: Xcode 16 / Swift 6.1.

```sh
# Run the menu bar app directly (easiest while developing; uses your Terminal's permissions):
swift run MacRazer

# Or build a standalone .app:
./Scripts/setup-signing.sh      # one-time: a stable self-signed identity (see Permissions)
./Scripts/build-app.sh          # produces "MacRazer MX.app", versioned "<version>-dev"
open "MacRazer MX.app"
```

The SwiftPM target and the executable inside the bundle are still called `MacRazer`, as in
upstream, so `swift run MacRazer` and the commands below are unchanged.

The screenshots in this README come from preview data, no mouse needed:
`./Scripts/render-screenshots.sh` writes them all to `dist/screenshots/`. They show upstream's
MacRazer and may not match this fork's windows exactly.

## Permissions

- **Input Monitoring** is required to send and receive HID reports to the mouse. The app
  requests it on launch; grant it in System Settings › Privacy & Security › Input Monitoring.
  It is also what lets the event tap see the DPI button's F20 key.
- **Accessibility** is required for button remapping, gestures and scroll reversal (the event
  tap). The remap screen has a button to open the right settings pane.
- **Bluetooth**, the first time it finds a mouse on Bluetooth.

macOS keeps these grants per app, by bundle ID. MacRazer MX is a different app from MacRazer, so
anything you granted upstream's app doesn't carry over: grant both again for **MacRazer MX**.

macOS binds a permission grant to the app's code signature. An ad-hoc build gets a new
signature on every rebuild, which resets the grant, so either run `Scripts/setup-signing.sh`
once (it creates a stable self-signed identity that `build-app.sh` then uses) or develop with
`swift run MacRazer`, which inherits your Terminal's grants.

If a build seems to stop dead at the codesigning step, it hasn't crashed: macOS is showing a
keychain prompt for the signing key (the build script says so once it has been waiting a few
seconds). Click **Always Allow** (not Allow), then run `Scripts/setup-signing.sh --repair`
once to grant codesign standing access so nothing prompts again.

## Command-line diagnostics

The same binary runs read-only probes when given a subcommand (handy for verifying a new
mouse). Run these from a terminal:

```sh
swift run MacRazer info                 # list the mouse's HID interfaces
swift run MacRazer battery              # read battery %
swift run MacRazer dpi [x] [y]          # read or set DPI
swift run MacRazer poll [125|500|1000]  # read or set polling rate
swift run MacRazer rgb static ff0000    # static colour (or: spectrum | wave [speed] | off)
swift run MacRazer rgb breathing ff0000 # breathing (two colours for dual, none for random)
swift run MacRazer brightness [0-100]   # read or set LED brightness
swift run MacRazer discover             # which transaction ids the mouse answers to
swift run MacRazer devicetest           # the in-app device test, printed as JSON
"MacRazer MX.app/Contents/MacOS/MacRazer" bluetoothtest  # the read-only Bluetooth test (quit the app first)
```

## How it works

The mouse speaks Razer's HID protocol. We did not reverse-engineer it: the command bytes were
ported from OpenRazer's Linux driver and reimplemented in Swift over Apple's IOKit HID
Manager. No kernel extension is needed because Razer mice respond to standard USB HID feature
reports that any userspace process can send.

Full details, including the protocol, the per-device hardware quirks, and a file-by-file map,
are in [Documentation/DOCUMENTATION.md](Documentation/DOCUMENTATION.md). The complete feature history is in
[CHANGELOG.md](CHANGELOG.md).

## Built with

Upstream's MacRazer was built with [Hiveship](https://hiveship.app/), an issue tracker for planning work,
tracking bugs, and handing issues to coding agents as well as the people on your team.

## Contributing

Pull requests and issues are welcome on
[cortinadev/MacRazer-MX](https://github.com/cortinadev/MacRazer-MX), especially **device
profiles** so this works on more Razer mice. Changes that aren't specific to the fork's features
may be better sent to [upstream](https://github.com/SorcRR/MacRazer). See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

GPL-2.0-or-later, see [LICENSE](LICENSE). The project is GPL because its HID protocol is
derived from OpenRazer. MacRazer MX is a modified version of SorcRR's MacRazer; full
attribution, the list of the fork's changes and the trademark notice are in [NOTICE.md](NOTICE.md).

## Support

This is a free, unpaid community project. The tip jar below is the original author's, for
upstream's MacRazer, which this fork is built on. If MacRazer is useful to you, you can leave
a tip: [ko-fi.com/sorcrr](https://ko-fi.com/sorcrr). The first goal is an Apple Developer ID
($99 a year), so MacRazer can be signed and opens without the security warning.
