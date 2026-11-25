// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import ApplicationServices
import CoreGraphics

/// What a remapped button does. `.passthrough` lets the original event through; `.keystroke`
/// suppresses the button and posts a key combo instead. `.gesture` makes it a gesture button:
/// held and moved, it fires one action per direction; pressed in place, its click action.
enum RemapAction: Codable, Equatable, Sendable {
    case passthrough
    case keystroke(keyCode: UInt16, modifiers: UInt64, name: String)
    case mouseButton(button: Int, name: String)
    case doubleClick
    case mediaKey(code: Int, name: String)
    indirect case gesture(GestureBindings)

    var label: String {
        switch self {
        case .passthrough: return "None"
        case .keystroke(_, _, let name), .mouseButton(_, let name), .mediaKey(_, let name): return name
        case .doubleClick: return "Double Click"
        case .gesture: return "Gesture"
        }
    }

    var isGesture: Bool {
        if case .gesture = self { return true }
        return false
    }
}

/// What a gesture button does: one action for a press and release in place, and one for a
/// swipe in each direction while it's held. Each is an ordinary `RemapAction`. A gesture
/// inside a gesture is never offered, and does nothing if one ever turns up in saved data
/// (`ButtonRemapper.apply` ignores it).
struct GestureBindings: Codable, Equatable, Sendable {
    var click: RemapAction
    var up: RemapAction
    var down: RemapAction
    var left: RemapAction
    var right: RemapAction

    subscript(slot: GestureSlot) -> RemapAction {
        get {
            switch slot {
            case .click: click
            case .up: up
            case .down: down
            case .left: left
            case .right: right
            }
        }
        set {
            switch slot {
            case .click: click = newValue
            case .up: up = newValue
            case .down: down = newValue
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }

    /// The action a swipe in `direction` fires.
    func action(for direction: GestureDirection) -> RemapAction { self[GestureSlot(direction)] }

    /// What choosing Gesture sets, laid out like the gesture button on Logitech's MX mice:
    /// up for Mission Control, down for App Exposé, left and right to change Space. `click`
    /// is what a press without a swipe does.
    static func defaults(click: RemapAction) -> GestureBindings {
        func preset(_ id: String) -> RemapAction {
            ButtonRemapper.presets.first { $0.id == id }?.action ?? .passthrough
        }
        return GestureBindings(click: click, up: preset("missionControl"), down: preset("appExpose"),
                               left: preset("spaceLeft"), right: preset("spaceRight"))
    }

    /// The defaults for a mouse button, whose click keeps doing what the button did before.
    static func defaults(for button: Int) -> GestureBindings {
        defaults(click: ButtonRemapper.originalClick(for: button))
    }
}

/// One of a gesture's five actions, in the order the gesture editor lists them.
enum GestureSlot: CaseIterable, Sendable {
    case click, up, down, left, right

    init(_ direction: GestureDirection) {
        switch direction {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }

    var title: String {
        switch self {
        case .click: "Click"
        case .up: "Swipe Up"
        case .down: "Swipe Down"
        case .left: "Swipe Left"
        case .right: "Swipe Right"
        }
    }
}

/// A curated shortcut a button can be bound to (keeps v1 simple — no key recorder yet).
struct RemapPreset: Identifiable {
    let id: String
    let name: String
    let keyCode: UInt16
    let flags: CGEventFlags

    var action: RemapAction { .keystroke(keyCode: keyCode, modifiers: flags.rawValue, name: name) }
}

/// Software button remapping via a CGEvent tap. Detects which extra mouse buttons fire and,
/// for mapped ones, suppresses the original event and posts a key combo instead.
///
/// This is the legal/portable approach (no Razer protocol). It only works while the app runs
/// and needs Accessibility permission. Onboard remapping would require reverse-engineering
/// Synapse, which Razer's EULA forbids — see the research notes.
final class ButtonRemapper: ObservableObject, @unchecked Sendable {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var eventTapAvailable = false
    @Published private(set) var keyboardCaptureAvailable = false
    @Published private(set) var lastDetectedButton: Int?
    @Published private(set) var seenButtons: Set<Int> = []
    @Published private(set) var suggestedButtons: Set<Int> = []
    @Published private(set) var mappings: [Int: RemapAction] = [:]
    /// Other apps with an event tap that can swallow extra-button clicks (Synapse, Mac Mouse
    /// Fix, …). One that gets a click first leaves nothing for ours to see, so the page names
    /// them. Refreshed with the Accessibility check.
    @Published private(set) var competingTapApps: [String] = []
    /// A button past the wheel click has reached our tap from this mouse. Then nothing is
    /// taking its clicks, and naming apps that could would only be noise.
    @Published private(set) var sideButtonDetected = false
    /// Whether to show `competingTapApps`. A filtering tap may still pass every click on, so
    /// the apps are named only while no side button has got through.
    var showsCompetingApps: Bool { !competingTapApps.isEmpty && !sideButtonDetected }
    private var workspaceObservers: [NSObjectProtocol] = []

    /// What MacRazer does with the DPI button's F20, saved per device. Set only once the mouse
    /// has read back the F20 assignment (`configureDpiCycle`), or by editing the gesture it
    /// already is (`setGestureAction(_:for:of:)` with `dpiButton`).
    @Published private(set) var dpiCycleSoftwareAction: RemapAction?
    /// The mouse was read holding the F20 assignment. Until then F20 goes through untouched.
    /// Losing it ends a hold of the DPI button: what started it may no longer be the mouse's.
    @Published private(set) var dpiBridgeBindingConfirmed = false {
        didSet { if !dpiBridgeBindingConfirmed, gestureHold?.trigger == Self.dpiButton { gestureHold = nil } }
    }
    /// An F20 key-down was swallowed and its key-up hasn't come yet. Kept across a reinstall
    /// of the tap that keeps the keys, so the key-up of a swallowed press is always swallowed
    /// too; a fresh press sets it again either way (`handleDpiBridge`). Cleared when no tap
    /// with the keys is left to see that key-up.
    private var bridgeKeyIsDown = false
    private var dpiBridgeReadRequested = false
    private var dpiBridgeRestoreAttempted = false
    private var dpiObservers = Set<AnyCancellable>()
    private let defaults: UserDefaults
    private let actionEmitter: ((RemapAction) -> Void)?

    init(defaults: UserDefaults = .standard, actionEmitter: ((RemapAction) -> Void)? = nil) {
        self.defaults = defaults
        self.actionEmitter = actionEmitter
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The events the installed tap asks for (`eventMask`), 0 with no tap. A change in what
    /// it should ask for reinstalls it.
    private var tapMask: CGEventMask = 0

    /// A gesture button being held: which one, the movement so far and what it fires.
    struct GestureHold: Equatable {
        /// The CGEvent button number that started it. `dpiButton` (-1) for a hold that comes
        /// from the DPI button's F20 key instead of a mouse button.
        let trigger: Int
        let bindings: GestureBindings
        var recognizer = GestureRecognizer()
    }
    /// The hold in progress, if any. One at a time: a new press ends it.
    private(set) var gestureHold: GestureHold?
    /// Per-device key so each mouse keeps its own remaps.
    private var activeKey = "none"
    private var activeDeviceID: Int?
    /// The DPI button's number wherever buttons are numbered: `label(for:)`, a gesture hold's
    /// trigger, and `gestureBindings(for:)`. It has no CGEvent button number of its own.
    static let dpiButton = -1
    /// The connected mouse's DPI button can be rebound over Bluetooth
    /// (`RazerDevices.supportsDpiButtonBinding`), and so may send F20 for MacRazer to act on.
    var supportsDpiButtonBinding: Bool {
        activeKey != "none" && (activeDeviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) ?? false)
    }
    /// The connected mouse has the Basilisk V3 X's Multi-function trigger, for the page's note.
    var hasMultiFunctionTrigger: Bool {
        activeKey != "none" && (activeDeviceID.map(RazerDevices.hasMultiFunctionTrigger(pid:)) ?? false)
    }
    var remappingPermissionsGranted: Bool { accessibilityGranted && eventTapAvailable }
    private var defaultsKey: String { "buttonMappings-\(activeKey)" }
    /// Mirrors `MouseController.connected` (wired in AppDelegate; main-thread, same as the
    /// tap callback). While the mouse is offline — powered off, asleep, dongle unplugged —
    /// its mappings must not fire: the tap can't tell which device sent a click, so they'd
    /// keep remapping matching buttons on every other pointing device. Published so the
    /// remap UI can say why nothing is firing (button detection still works while paused).
    /// Pausing ends a gesture hold: its release then passes through like any paused press.
    @Published var remappingPaused = false {
        didSet { if remappingPaused { gestureHold = nil } }
    }

    /// Called when a mapped button is pressed while remapping is paused. The mouse is paused
    /// because the app last saw it offline, and a press of one of its mapped buttons is a good
    /// sign it has just woken up. Without this, the mapping only came back at the next battery
    /// poll, and that poll backs off while the mouse is away. Main thread, like the tap.
    var onPressWhilePaused: (() -> Void)?

    /// Switch to the connected mouse's mappings (called when the device changes). `key` is the
    /// per-unit device key (serial/PID).
    func setActiveDevice(_ key: String?, deviceID: Int? = nil) {
        let k = key ?? "none"
        let idChanged = deviceID != nil && deviceID != activeDeviceID
        guard k != activeKey || idChanged else { return }
        activeKey = k
        if deviceID != nil || k == "none" { activeDeviceID = deviceID }
        seenButtons = [] // detected buttons are per-device
        sideButtonDetected = false
        suggestedButtons = supportsDpiButtonBinding ? [3, 4] : []
        gestureHold = nil
        loadMappings()
        loadDpiSoftwareAction()
        dpiBridgeBindingConfirmed = false
        dpiBridgeReadRequested = false
        dpiBridgeRestoreAttempted = false
        // This mouse's mappings may have gestures where the last one's had none, or none
        // where it had some: the drags are asked for only while one needs them.
        installTapIfNeeded()
    }

    static let presets: [RemapPreset] = [
        .init(id: "copy", name: "Copy  ⌘C", keyCode: 8, flags: .maskCommand),
        .init(id: "paste", name: "Paste  ⌘V", keyCode: 9, flags: .maskCommand),
        .init(id: "cut", name: "Cut  ⌘X", keyCode: 7, flags: .maskCommand),
        .init(id: "undo", name: "Undo  ⌘Z", keyCode: 6, flags: .maskCommand),
        .init(id: "redo", name: "Redo  ⇧⌘Z", keyCode: 6, flags: [.maskCommand, .maskShift]),
        .init(id: "selectAll", name: "Select All  ⌘A", keyCode: 0, flags: .maskCommand),
        .init(id: "save", name: "Save  ⌘S", keyCode: 1, flags: .maskCommand),
        .init(id: "find", name: "Find  ⌘F", keyCode: 3, flags: .maskCommand),
        .init(id: "newTab", name: "New Tab  ⌘T", keyCode: 17, flags: .maskCommand),
        .init(id: "close", name: "Close  ⌘W", keyCode: 13, flags: .maskCommand),
        .init(id: "back", name: "Back  ⌘[", keyCode: 33, flags: .maskCommand),
        .init(id: "forward", name: "Forward  ⌘]", keyCode: 30, flags: .maskCommand),
        .init(id: "missionControl", name: "Mission Control  ⌃↑", keyCode: 126,
              flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        .init(id: "appExpose", name: "App Exposé  ⌃↓", keyCode: 125,
              flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        .init(id: "spaceLeft", name: "Space Left  ⌃←", keyCode: 123,
              flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        .init(id: "spaceRight", name: "Space Right  ⌃→", keyCode: 124,
              flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]),
        .init(id: "screenshot", name: "Screenshot  ⇧⌘4", keyCode: 21, flags: [.maskCommand, .maskShift]),
        .init(id: "switchApp", name: "Switch App  ⌘Tab", keyCode: 48, flags: .maskCommand),
    ]

    // MARK: - Lifecycle

    func start() {
        loadMappings()
        loadDpiSoftwareAction()
        refreshAccessibility(prompt: false)
        // Keep the named apps current while the page is open: quitting one is what the note
        // asks for. A launched app may create its tap a moment after it starts.
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.refreshCompetingTaps()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refreshCompetingTaps() }
        })
        // No hold lasts through the Mac's sleep: a release that came while it slept was never
        // seen, and the hold would turn the first movement after waking into a swipe.
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            self?.cancelGesture()
        })
    }

    /// Re-check the Accessibility grant (call when the window appears / returns to front).
    func refreshAccessibility(prompt: Bool) {
        guard !RenderOptions.isActive else { return }
        // An explicit Re-check is the user saying they changed a permission: try the
        // keyboard-capable tap again.
        if prompt { keyboardTapRefused = false }
        // Use the literal key to avoid touching the non-Sendable global CFString symbol.
        let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        accessibilityGranted = granted
        if granted {
            installTapIfNeeded()
        } else {
            removeTap()
            // No tap is coming back to see this press's release.
            bridgeKeyIsDown = false
        }
        refreshCompetingTaps()
    }

    /// Tears down the event tap and its run-loop source — called when Accessibility is revoked
    /// while the app is running, so a stale tap isn't left registered indefinitely, and before
    /// a tap with another mask is installed. Ends any hold, the DPI button's too: its events
    /// may go by unseen in between. `bridgeKeyIsDown` stays, so a swallowed F20's key-up that
    /// reaches the new tap is still swallowed.
    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        tapMask = 0
        gestureHold = nil
        eventTapAvailable = false
        keyboardCaptureAvailable = false
    }

    func openAccessibilitySettings() { SystemSettingsPanes.openAccessibility() }

    // MARK: - Mappings

    /// Media keys (IOKit NX_KEYTYPE codes).
    static let mediaOptions: [(code: Int, name: String)] = [
        (16, "Play / Pause"), (17, "Next Track"), (18, "Previous Track"),
        (0, "Volume Up"), (1, "Volume Down"), (7, "Mute"),
    ]

    /// Called after an individual button's mapping changes — lets owners (e.g. profile tracking
    /// in `MouseController`) know the live config has drifted from whatever profile was applied.
    var onManualChange: (() -> Void)?

    func setAction(_ action: RemapAction, for button: Int) {
        // A hold of this button was started with what it did before.
        if gestureHold?.trigger == button { gestureHold = nil }
        mappings[button] = action
        seenButtons.insert(button)
        saveMappings()
        installTapIfNeeded()
        onManualChange?()
    }

    /// Replaces the whole mapping table at once — used when applying a saved profile (as opposed
    /// to a single-button edit from the remap UI, which goes through `setAction`).
    func setMappings(_ new: [Int: RemapAction]) {
        gestureHold = nil
        mappings = new
        seenButtons.formUnion(new.keys)
        saveMappings()
        installTapIfNeeded()
    }

    /// What choosing Gesture… for a button does: the defaults (`GestureBindings.defaults`)
    /// when it isn't a gesture yet. One that already is keeps its choices, as choosing it
    /// again is how the editor is reopened.
    /// Not for the DPI button, whose gesture needs the mouse to send F20 first
    /// (`makeDpiGesture`).
    func makeGesture(_ button: Int) {
        guard button != Self.dpiButton, mappings[button]?.isGesture != true else { return }
        setAction(.gesture(.defaults(for: button)), for: button)
    }

    /// A gesture button's five actions, or nil when the button isn't one. `dpiButton` reads
    /// the DPI button's software action, so the gesture editor serves it as any other.
    func gestureBindings(for button: Int) -> GestureBindings? {
        let action = button == Self.dpiButton ? dpiCycleSoftwareAction : mappings[button]
        guard case .gesture(let bindings) = action else { return nil }
        return bindings
    }

    /// Sets one of a gesture button's actions. Nothing changes for a button that isn't a
    /// gesture, or for a gesture as the action: one nested in another would never fire.
    /// For the DPI button only the saved action changes: the mouse already sends F20, so
    /// nothing is written to it.
    func setGestureAction(_ action: RemapAction, for slot: GestureSlot, of button: Int) {
        guard var bindings = gestureBindings(for: button), !action.isGesture else { return }
        bindings[slot] = action
        if button == Self.dpiButton {
            saveDpiSoftwareAction(.gesture(bindings))
        } else {
            setAction(.gesture(bindings), for: button)
        }
    }

    func actionLabel(for button: Int) -> String { mappings[button]?.label ?? "None" }

    /// A click of `button` itself. A gesture's click re-posts it, so a press without a swipe
    /// still does what the button did before: the wheel click still opens a link in a new
    /// tab, Back still goes back. `.passthrough` (nothing) for the DPI button (`dpiButton`)
    /// and the primary buttons, which have no click of their own to post: software can't
    /// cycle DPI, so a DPI gesture's click is None until one is chosen.
    static func originalClick(for button: Int) -> RemapAction {
        let name: String
        switch button {
        case ..<2: return .passthrough
        case 2: name = "Middle Click"
        case 3: name = "Back Button"
        case 4: name = "Forward Button"
        default: name = "Button \(button + 1)"
        }
        return .mouseButton(button: button, name: name)
    }

    /// Friendly, compact label for a raw CGEvent button number.
    static func label(for button: Int) -> String {
        switch button {
        case dpiButton: return "DPI Button"
        case 2: return "Wheel Click"
        case 3: return "Back (4)"
        case 4: return "Forward (5)"
        default: return "Button \(button + 1)"
        }
    }

    /// Mock state for the `render-remap` preview command.
    func loadPreviewState() {
        accessibilityGranted = true
        eventTapAvailable = true
        seenButtons = [2, 3, 4, 5]
        mappings = [3: .keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy  ⌘C"),
                    4: .keystroke(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue, name: "Paste  ⌘V"),
                    5: .gesture(.defaults(for: 5))]
    }

    // MARK: - Event tap

    private func installTapIfNeeded() {
        guard accessibilityGranted else { return }
        let mask = wantedEventMask
        guard tap == nil || tapMask != mask else {
            if let tap {
                if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
                eventTapAvailable = CGEvent.tapIsEnabled(tap: tap)
                refreshKeyboardCaptureStatus()
            }
            return
        }
        removeTap()
        installTap(mask: mask)
    }

    /// The mask the tap should have now (`eventMask`). A change reinstalls it. Internal rather
    /// than private so tests can check what the DPI button's action asks for.
    var wantedEventMask: CGEventMask {
        Self.eventMask(keyboard: shouldCaptureKeyboard && !keyboardTapRefused, gestures: wantsGestureEvents,
                       dpiGesture: wantsDpiGestureEvents)
    }

    /// A gesture needs the pointer's movement while its button is held.
    private var wantsGestureEvents: Bool {
        mappings.values.contains { $0.isGesture }
    }

    /// The DPI button is a gesture, whose movement comes as plain pointer moves.
    private var wantsDpiGestureEvents: Bool {
        supportsDpiButtonBinding && dpiCycleSoftwareAction?.isGesture == true
    }

    /// macOS refused the keyboard-capable tap this session. Cleared by an explicit Re-check
    /// (`refreshAccessibility(prompt: true)`) or a relaunch.
    private var keyboardTapRefused = false

    private var shouldCaptureKeyboard: Bool {
        supportsDpiButtonBinding && dpiCycleSoftwareAction != nil
    }

    private func installTap(mask: CGEventMask) {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // macOS may reject keyboard capture while allowing mouse events. Keep ordinary
            // button remapping available even when the optional F20 bridge cannot run, and
            // remember the refusal: otherwise every state change would tear down the working
            // mouse-only tap to try the keyboard one again.
            if Self.includesKeyboardEvents(mask) {
                // The same mask without the bridge's events, so gestures keep their drags and
                // the next `installTapIfNeeded` finds the mask it asks for. The pointer moves
                // go too: with no F20, no hold of the DPI button can start.
                installTap(mask: mask & ~Self.bridgeEventsMask)
                // Only a refusal if mouse events still work. When both fail, the cause is
                // something else (Accessibility not effective yet), so try both again later.
                keyboardTapRefused = tap != nil
            }
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = src
        self.tapMask = mask
        // A tap without the keys never sees F20's key-up, so none is waiting to be swallowed.
        if !Self.includesKeyboardEvents(mask) { bridgeKeyIsDown = false }
        eventTapAvailable = true
        refreshKeyboardCaptureStatus()
    }

    /// The events the tap asks for. otherMouse = middle/wheel-click + extra buttons, the only
    /// buttons we remap; primary left/right clicks are deliberately never tapped. Their drags
    /// only while a gesture needs them: they come at the mouse's polling rate, and a tap that
    /// doesn't ask for them never sees them. Keys only for the DPI button's F20 bridge.
    ///
    /// `dpiGesture`: the DPI button is a gesture. While its F20 is held no mouse button is
    /// down, so its movement comes as `.mouseMoved`, asked for only then and only with the
    /// keys: every move of the pointer goes through the tap while it's in the mask. Primary
    /// drags are never asked for, so a DPI hold sees no movement while the left or right
    /// button is also held: that movement is a drag the app under the pointer is doing.
    static func eventMask(keyboard: Bool, gestures: Bool, dpiGesture: Bool = false) -> CGEventMask {
        var types: [CGEventType] = [.otherMouseDown, .otherMouseUp]
        if gestures { types.append(.otherMouseDragged) }
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard keyboard else { return mask }
        return mask | keyboardEventsMask | (dpiGesture ? pointerMovedMask : 0)
    }

    static let keyboardEventsMask: CGEventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    static let pointerMovedMask: CGEventMask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
    /// What the F20 bridge adds to the mask, and what the fallback drops when macOS refuses it.
    static let bridgeEventsMask: CGEventMask = keyboardEventsMask | pointerMovedMask

    static func includesKeyboardEvents(_ mask: CGEventMask) -> Bool {
        mask & keyboardEventsMask == keyboardEventsMask
    }

    /// Every event tap on the session, or nil when macOS won't list them.
    private static func eventTaps() -> [CGEventTapInformation]? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &entries, &count) == .success else { return nil }
        return Array(entries.prefix(Int(count)))
    }

    private func refreshKeyboardCaptureStatus() {
        keyboardCaptureAvailable = Self.eventTaps()?.contains {
            $0.tappingProcess == getpid() && $0.enabled && Self.includesKeyboardEvents($0.eventsOfInterest)
        } ?? false
    }

    /// What `competingTapPIDs` needs from a `CGEventTapInformation`.
    struct TapEntry: Equatable {
        let pid: pid_t
        /// 0 for a tap on the whole session; else the one app it filters, which can't take
        /// clicks meant for anywhere else.
        let tappedPID: pid_t
        let enabled: Bool
        let listenOnly: Bool
        let eventsOfInterest: CGEventMask
    }

    /// The other processes whose taps can drop an extra-button click before ours sees it:
    /// enabled, session-wide, filtering (a listen-only tap can't drop anything) and asking
    /// for `otherMouseDown`. In list order, each once.
    static func competingTapPIDs(_ taps: [TapEntry], ownPID: pid_t) -> [pid_t] {
        let otherMouse = CGEventMask(1) << CGEventType.otherMouseDown.rawValue
        var seen = Set<pid_t>()
        return taps.compactMap { tap in
            guard tap.pid != ownPID, tap.tappedPID == 0, tap.enabled, !tap.listenOnly,
                  tap.eventsOfInterest & otherMouse != 0, seen.insert(tap.pid).inserted else { return nil }
            return tap.pid
        }
    }

    private func refreshCompetingTaps() {
        let names = Self.currentCompetingTapApps()
        if names != competingTapApps { competingTapApps = names }
    }

    /// The apps whose taps compete with ours (`competingTapPIDs`), each once. Also what the
    /// device test reports (`RemapSoftware`).
    static func currentCompetingTapApps() -> [String] {
        let taps = (eventTaps() ?? []).map {
            TapEntry(pid: $0.tappingProcess, tappedPID: $0.processBeingTapped, enabled: $0.enabled,
                     listenOnly: $0.options == .listenOnly, eventsOfInterest: $0.eventsOfInterest)
        }
        // Apps only: macOS's own daemons tap mouse events too, and passing clicks on is their job.
        var names: [String] = []
        for pid in competingTapPIDs(taps, ownPID: getpid()) {
            guard let name = appName(pid: pid), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// The app a process belongs to, or nil for one of macOS's own. A helper launched by
    /// launchd has no `NSRunningApplication`, so the `.app` around its executable names it.
    static func appName(pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            return bundleID.hasPrefix("com.apple.") ? nil : app.localizedName ?? bundleID
        }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return appName(executablePath: String(cString: buffer))
    }

    /// The outermost `.app` in the path, without its extension; nil outside one, in macOS's
    /// own folders, or inside one of Apple's apps (an Xcode helper is Apple's, not Xcode the
    /// competitor).
    static func appName(executablePath path: String) -> String? {
        guard !path.hasPrefix("/System/"), !path.hasPrefix("/usr/") else { return nil }
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let appPath = "/" + components[...index].joined(separator: "/")
        if Bundle(path: appPath)?.bundleIdentifier?.hasPrefix("com.apple.") ?? false { return nil }
        return String(components[index].dropLast(4))
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let remapper = Unmanaged<ButtonRemapper>.fromOpaque(userInfo).takeUnretainedValue()
        return remapper.handle(type: type, event: event)
    }

    private static let magic: Int64 = 0x52415A45 // "RAZE" — marks events we post, to skip them
    /// Internal rather than private so tests can check the events it makes carry `magic`.
    lazy var postSource: CGEventSource? = {
        let s = CGEventSource(stateID: .combinedSessionState)
        s?.userData = Self.magic
        return s
    }()

    /// Runs on the main run loop (the tap source is scheduled there). Internal rather than
    /// private so tests can hand it synthetic events.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Events went by unseen, perhaps the release that would have ended a hold.
            gestureHold = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // First and short: drags come at the mouse's polling rate, on the main thread, and
        // with no gesture held there is nothing to look at.
        if type == .otherMouseDragged {
            guard gestureHold != nil else { return Unmanaged.passUnretained(event) }
            return handleGestureDrag(event)
        }
        // As short: every move of the pointer comes here while the DPI button is a gesture.
        if type == .mouseMoved {
            if gestureHold?.trigger == Self.dpiButton { handleDpiGestureMove(event) }
            return Unmanaged.passUnretained(event)
        }
        // Skip events we ourselves posted (e.g. a remap-to-middle-click re-enters the tap).
        if event.getIntegerValueField(.eventSourceUserData) == Self.magic {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            return handleDpiBridge(type: type, event: event)
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if type == .otherMouseDown, button >= 3, !sideButtonDetected { sideButtonDetected = true }

        // Only the extra buttons are remappable (the tap is scoped to otherMouse events,
        // but keep the guard as a defensive net).
        guard type == .otherMouseDown || type == .otherMouseUp else {
            return Unmanaged.passUnretained(event)
        }
        // A press while a gesture is held ends the hold, so one whose release went missing
        // can't linger and swallow the next drags.
        if type == .otherMouseDown { gestureHold = nil }

        if let action = mappings[button], action != .passthrough {
            guard remappingPaused else {
                if case .gesture(let bindings) = action {
                    if type == .otherMouseDown {
                        beginGesture(bindings, trigger: button)
                    } else {
                        endGesture(trigger: button)
                    }
                } else if type == .otherMouseDown {
                    apply(action)
                }
                return nil // suppress the original button (both down and up)
            }
            // This press still goes through unchanged: the tap can't tell which device sent
            // it, so it may not be our mouse at all. The check brings the mapping back for the
            // next press, a moment later, if it is.
            if type == .otherMouseDown { onPressWhilePaused?() }
        }

        // Unmapped → remember it for the UI, and let it through unchanged.
        if type == .otherMouseDown, lastDetectedButton != button || !seenButtons.contains(button) {
            lastDetectedButton = button
            seenButtons.insert(button)
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Gestures

    /// A drag while a hold is in progress. Its button must be the one held: the drags of
    /// another button held alongside are that button's, and go through.
    private func handleGestureDrag(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        // Read as doubles, which keeps any fraction of a point macOS reports: a slow, steady
        // swipe would otherwise lose it on every event.
        let moved = moveGesture(dx: event.getDoubleValueField(.mouseEventDeltaX),
                                dy: event.getDoubleValueField(.mouseEventDeltaY), trigger: button)
        // Swallowed while held, as the press was: an app that never saw the button go down
        // shouldn't see it drag. The cursor still moves, so the swipe stays visible.
        return moved ? nil : Unmanaged.passUnretained(event)
    }

    /// A pointer move while the DPI button is held. Unlike a drag it always goes through: no
    /// app saw a button go down, so to them it's a plain move, and swallowing it would only
    /// leave hover effects behind the pointer.
    private func handleDpiGestureMove(_ event: CGEvent) {
        moveGesture(dx: event.getDoubleValueField(.mouseEventDeltaX),
                    dy: event.getDoubleValueField(.mouseEventDeltaY), trigger: Self.dpiButton)
    }

    // The hold itself, apart from the events that drive it, so a trigger other than a mouse
    // button can use it: the DPI button arrives as an F20 key down and up (see
    // `handleDpiBridge`), its movement as `.mouseMoved` (`handleDpiGestureMove`). `trigger`
    // names the hold as in `GestureHold.trigger`.

    /// A gesture button went down: start a hold, replacing any other.
    func beginGesture(_ bindings: GestureBindings, trigger: Int) {
        gestureHold = GestureHold(trigger: trigger, bindings: bindings)
    }

    /// The pointer moved by (dx, dy), CGEvent deltas with y growing downward. Fires the
    /// direction's action the first time the hold's movement is far enough. Returns whether
    /// a hold of `trigger` is in progress, and so whether the movement belongs to it.
    @discardableResult
    func moveGesture(dx: Double, dy: Double, trigger: Int) -> Bool {
        guard gestureHold?.trigger == trigger else { return false }
        // Mutated in place: a copy of the hold per event would be wasted work at this rate.
        if let direction = gestureHold?.recognizer.move(dx: dx, dy: dy), let hold = gestureHold {
            apply(hold.bindings.action(for: direction))
        }
        return true
    }

    /// The gesture button came back up: fire the click if no swipe fired. Returns whether a
    /// hold of `trigger` was in progress.
    @discardableResult
    func endGesture(trigger: Int) -> Bool {
        guard var hold = gestureHold, hold.trigger == trigger else { return false }
        gestureHold = nil
        if hold.recognizer.end() { apply(hold.bindings.click) }
        return true
    }

    /// Ends any hold without firing anything.
    func cancelGesture() {
        gestureHold = nil
    }

    private func apply(_ action: RemapAction) {
        // Nothing to post for `.passthrough` (a gesture's "None"). A gesture only ever runs
        // from a hold, never as a single action, so one nested in a gesture's slot is inert.
        guard action != .passthrough, !action.isGesture else { return }
        if let actionEmitter { actionEmitter(action); return }
        switch action {
        case .passthrough, .gesture: break
        case .keystroke(let kc, let mods, _): postKeystroke(keyCode: kc, flags: CGEventFlags(rawValue: mods))
        case .mouseButton(let b, _): postMouseClick(b)
        case .doubleClick: postDoubleClick()
        case .mediaKey(let code, _): postMediaKey(code)
        }
    }

    /// Arrow keys: a real press carries Fn and numeric pad.
    static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]
    /// Keys whose real press carries numeric pad: the arrows and the keypad's own keys
    /// (0 to 9, the operators, decimal, clear, enter and equals).
    static let numericPadKeyCodes: Set<UInt16> = arrowKeyCodes.union([
        65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92,
    ])
    /// F1 to F20, then Help, Home, Page Up, Forward Delete, End and Page Down: a real press
    /// carries Fn (Apple's NSEvent.ModifierFlags.function docs list these keys).
    static let fnKeyCodes: Set<UInt16> = arrowKeyCodes.union([
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        114, 115, 116, 117, 119, 121,
    ])

    /// The flags a keystroke goes out with: the saved ones plus the ones a real press of the
    /// key carries. macOS matches its own shortcuts on those flags, so ⌃↑ without Fn never
    /// opened Mission Control. Mappings saved before #143 lack them, and the recorder only keeps
    /// them since then, so they are added here, where every saved mapping, profile and the
    /// DPI-button bridge pass. Nothing saved is rewritten, and adding them twice changes nothing.
    static func postedFlags(keyCode: UInt16, saved: CGEventFlags) -> CGEventFlags {
        var flags = saved
        if fnKeyCodes.contains(keyCode) { flags.insert(.maskSecondaryFn) }
        if numericPadKeyCodes.contains(keyCode) { flags.insert(.maskNumericPad) }
        return flags
    }

    /// The key-down and key-up a keystroke action posts, with `postedFlags` applied.
    static func keystrokeEvents(keyCode: UInt16, saved: CGEventFlags, source: CGEventSource?) -> [CGEvent] {
        let flags = postedFlags(keyCode: keyCode, saved: saved)
        return [true, false].compactMap { keyDown in
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
            event?.flags = flags
            return event
        }
    }

    private func postKeystroke(keyCode: UInt16, flags saved: CGEventFlags) {
        Self.keystrokeEvents(keyCode: keyCode, saved: saved, source: postSource).forEach { $0.post(tap: .cghidEventTap) }
    }

    private func postMouseClick(_ button: Int) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        Self.mouseClickEvents(button: button, at: pos, source: postSource).forEach { $0.post(tap: .cghidEventTap) }
    }

    /// The down and up a mouse-button action posts. Made with `postSource`, they carry `magic`
    /// and pass our own tap untouched: a gesture's click re-posts the gesture button's own
    /// number, which the tap would otherwise take for another press of it.
    static func mouseClickEvents(button: Int, at pos: CGPoint, source: CGEventSource?) -> [CGEvent] {
        let mb = CGMouseButton(rawValue: UInt32(button)) ?? .center
        let downType: CGEventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
        let upType: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
        return [downType, upType].compactMap { type in
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: mb)
            // Set outright rather than trusting the conversion above: Back and Forward
            // (3 and 4) must not come out as a middle click.
            e?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            // Without a click count, apps reading NSEvent.clickCount see 0 and may not
            // treat the synthesized press as a click at all (e.g. middle-click-closes-tab).
            e?.setIntegerValueField(.mouseEventClickState, value: 1)
            return e
        }
    }

    private func postDoubleClick() {
        let pos = CGEvent(source: nil)?.location ?? .zero
        for clicks in [1, 2] {
            let down = CGEvent(mouseEventSource: postSource, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(mouseEventSource: postSource, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            up?.post(tap: .cghidEventTap)
        }
    }

    private func postMediaKey(_ code: Int) {
        func post(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(true); post(false)
    }

    // MARK: - DPI button software actions

    /// F20 is reserved only after the connected mouse (`supportsDpiButtonBinding`) has
    /// confirmed the corresponding onboard assignment. The event tap includes keyboard events
    /// only while that mouse has a saved software action; ordinary users keep a mouse-only tap.
    ///
    /// What reaches the mouse from here: connecting, waking and opening the page only read
    /// the DPI button's entry. The one write not chosen on the page is the restore below,
    /// which puts F20 back after a fresh read shows the mouse lost it, and only while a
    /// software action is saved, which happens only after a write of F20 read back.
    func observeDpiCycle(controller: MouseController) {
        dpiObservers.removeAll()
        controller.$deviceKey.combineLatest(controller.$deviceID)
            .combineLatest(controller.$deviceIsBluetooth)
            .combineLatest(controller.$connected)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] state in
                let (((key, deviceID), bluetooth), connected) = state
                guard let self else { return }
                self.setActiveDevice(key, deviceID: deviceID)
                self.remappingPaused = !connected
                self.installTapIfNeeded()
                if !connected {
                    self.dpiBridgeBindingConfirmed = false
                    self.dpiBridgeReadRequested = false
                    self.dpiBridgeRestoreAttempted = false
                } else if bluetooth, deviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) == true,
                          !self.dpiBridgeReadRequested {
                    self.dpiBridgeReadRequested = true
                    controller?.refreshDpiCycleButtonBinding()
                }
            }.store(in: &dpiObservers)

        controller.$wakeRecoveryCounter
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, controller.connected, controller.deviceIsBluetooth,
                      controller.deviceID.map(RazerDevices.supportsDpiButtonBinding(pid:)) == true else { return }
                // A wake can preserve the BLE session, so the connected observer above does
                // not fire. Re-read once in case firmware reset the physical assignment. A
                // hold of the DPI button from before the mouse slept is over.
                if self.gestureHold?.trigger == Self.dpiButton { self.cancelGesture() }
                self.dpiBridgeRestoreAttempted = false
                self.dpiBridgeReadRequested = false
                controller.refreshDpiCycleButtonBinding()
            }.store(in: &dpiObservers)

        controller.$dpiCycleButtonBinding
            .combineLatest(controller.$deviceIsBluetooth)
            .combineLatest(controller.$isUpdatingDpiCycleButton)
            .combineLatest(controller.$connected)
            .combineLatest(controller.$dpiCycleButtonError)
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self, weak controller] state in
                let (((bindingState, updating), connected), error) = state
                let (binding, bluetooth) = bindingState
                guard let self else { return }
                self.confirmDpiBridge(binding: bluetooth ? binding : nil)
                guard let controller, connected, bluetooth, self.supportsDpiButtonBinding,
                      !updating, error == nil,
                      self.shouldRestoreDpiBridge(binding: binding,
                                                  connected: connected,
                                                  bluetooth: bluetooth,
                                                  alreadyAttempted: self.dpiBridgeRestoreAttempted),
                      let action = self.dpiCycleSoftwareAction else { return }
                self.dpiBridgeRestoreAttempted = true
                self.configureDpiCycle(.softwareBridge, softwareAction: action, controller: controller)
            }.store(in: &dpiObservers)
    }

    func confirmDpiBridge(binding: BLEProtocol.DPIButtonBinding?) {
        dpiBridgeBindingConfirmed = supportsDpiButtonBinding && binding == .softwareBridge
    }

    func shouldRestoreDpiBridge(binding: BLEProtocol.DPIButtonBinding?, connected: Bool,
                                bluetooth: Bool, alreadyAttempted: Bool) -> Bool {
        // `binding` must have been read from the mouse: nil means "not known yet" (after a
        // reconnect), and restoring then would write before the fresh read.
        supportsDpiButtonBinding && connected && bluetooth && !alreadyAttempted
            && binding != nil && binding != .softwareBridge && dpiCycleSoftwareAction != nil
    }

    /// Writes `binding` to the mouse, and once it reads back, saves `softwareAction` as what
    /// MacRazer does with F20 (nil for a firmware function, which clears any saved one).
    /// A software action needs the event tap, so without it nothing is written.
    func configureDpiCycle(_ binding: BLEProtocol.DPIButtonBinding,
                           softwareAction: RemapAction? = nil, controller: MouseController) {
        guard softwareAction == nil || remappingPermissionsGranted else { return }
        dpiBridgeBindingConfirmed = false
        controller.setDpiCycleButtonBinding(binding) { [weak self] success in
            guard success, let self else { return }
            self.saveDpiSoftwareAction(softwareAction)
            self.confirmDpiBridge(binding: binding)
        }
    }

    /// How the DPI button carries out `action`. A function the mouse runs itself where it has
    /// one, so it works without MacRazer: DPI Cycle for None, a mouse button it can send, a key
    /// combination it can type. Anything else is F20 for MacRazer to turn into `action`.
    static func dpiButtonAssignment(for action: RemapAction)
        -> (binding: BLEProtocol.DPIButtonBinding, softwareAction: RemapAction?) {
        switch action {
        case .passthrough:
            return (.dpiCycle, nil)
        case .keystroke(let keyCode, let modifiers, _):
            if let usage = BLEProtocol.hidUsage(forMacKeyCode: keyCode) {
                let flags = CGEventFlags(rawValue: modifiers)
                return (.keyboardShortcut(hidUsage: usage, modifiers: DPIShortcutModifiers.hidValue(from: flags)), nil)
            }
        case .mouseButton(let button, _):
            // CGEvent numbers 0 to 4 are the mouse's buttons 1 to 5. Its Scroll Up and Down
            // (9 and 10) are not buttons a `RemapAction` can name.
            if (0...4).contains(button),
               let binding = BLEProtocol.DPIButtonBinding.allCases.first(where: { $0.buttonID == UInt8(button + 1) }) {
                return (binding, nil)
            }
        case .doubleClick, .mediaKey, .gesture:
            break
        }
        return (.softwareBridge, action)
    }

    /// Sets the DPI button to `action` (`dpiButtonAssignment`). False when that takes F20 and
    /// the event tap isn't available, and so nothing was written.
    @discardableResult
    func configureDpiButton(_ action: RemapAction, controller: MouseController) -> Bool {
        let assignment = Self.dpiButtonAssignment(for: action)
        guard assignment.softwareAction == nil || remappingPermissionsGranted else { return false }
        configureDpiCycle(assignment.binding, softwareAction: assignment.softwareAction, controller: controller)
        return true
    }

    /// What choosing Gesture… for the DPI button does: the defaults, with None as the click
    /// (`originalClick`), through F20. One that already is a gesture keeps its choices and
    /// nothing is written, as choosing it again is how the editor is reopened.
    @discardableResult
    func makeDpiGesture(controller: MouseController) -> Bool {
        if dpiCycleSoftwareAction?.isGesture == true { return true }
        return configureDpiButton(.gesture(.defaults(for: Self.dpiButton)), controller: controller)
    }

    func dpiCycleLabel(for binding: BLEProtocol.DPIButtonBinding) -> String {
        if binding == .softwareBridge {
            return dpiCycleSoftwareAction.map { $0.label + " (MacRazer)" } ?? "MacRazer action (choose…)"
        }
        return binding.label
    }

    func saveDpiSoftwareAction(_ action: RemapAction?) {
        guard supportsDpiButtonBinding else { return }
        let previous = dpiCycleSoftwareAction
        // A hold of the DPI button was started with what it did before.
        if action != previous, gestureHold?.trigger == Self.dpiButton { gestureHold = nil }
        dpiCycleSoftwareAction = action
        let key = "dpiCycleSoftwareAction-\(activeKey)"
        if let action, let data = try? JSONEncoder().encode(action) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        installTapIfNeeded()
        if action != previous { onManualChange?() }
    }

    private func loadDpiSoftwareAction() {
        dpiCycleSoftwareAction = nil
        guard supportsDpiButtonBinding,
              let data = defaults.data(forKey: "dpiCycleSoftwareAction-\(activeKey)") else { return }
        dpiCycleSoftwareAction = try? JSONDecoder().decode(RemapAction.self, from: data)
    }

    var dpiBridgeStatus: String {
        if !remappingPermissionsGranted { return "Input capture unavailable" }
        if !keyboardCaptureAvailable { return "Keyboard capture is blocked. Refresh Input Monitoring, then relaunch." }
        if remappingPaused { return "Waiting for mouse connection" }
        if !dpiBridgeBindingConfirmed { return "Waiting for button assignment verification" }
        return "Ready"
    }

    /// The DPI button's F20. A press fires the saved action, or starts a hold when it is a
    /// gesture; the release ends the hold (its click, if no swipe fired). Every key-up whose
    /// key-down was swallowed is swallowed too, whatever changed in between (paused, the
    /// binding no longer confirmed, the action changed): an app that never saw F20 go down
    /// mustn't see it come up. Key repeats follow their press and never start anything.
    private func handleDpiBridge(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.keyboardEventKeycode) == 90 else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp {
            guard bridgeKeyIsDown else { return Unmanaged.passUnretained(event) }
            bridgeKeyIsDown = false
            // Nothing when the hold was already ended (paused, a mouse button pressed, …).
            endGesture(trigger: Self.dpiButton)
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return bridgeKeyIsDown ? nil : Unmanaged.passUnretained(event)
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard supportsDpiButtonBinding, dpiBridgeBindingConfirmed,
              !remappingPaused, event.flags.intersection(modifiers).isEmpty,
              let action = dpiCycleSoftwareAction else {
            // A press let through: its repeats and release go through as well, even if one
            // before it lost its release.
            bridgeKeyIsDown = false
            return Unmanaged.passUnretained(event)
        }
        lastDetectedButton = Self.dpiButton
        bridgeKeyIsDown = true
        if case .gesture(let bindings) = action {
            beginGesture(bindings, trigger: Self.dpiButton)
        } else {
            apply(action)
        }
        return nil
    }

    // MARK: - Persistence

    private func saveMappings() {
        // No connected device, no persistence: an edit made in a remap window that outlived
        // a disconnect would otherwise be saved under the meaningless "none" key and
        // silently dropped on reconnect.
        guard activeKey != "none" else { return }
        if let data = try? JSONEncoder().encode(mappings) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private func loadMappings() {
        // Always reset first: a device with no saved table must start empty rather than
        // inherit the previous mouse's mappings — which would both remap the new mouse with
        // the old one's bindings and, on the next edit, save the old table under the new
        // device's key. Also covers disconnect (key "none"): with no mappings the tap
        // passes everything through.
        mappings = [:]
        // Never load under the no-device key. Nothing writes it anymore (see saveMappings),
        // but pre-fix builds persisted disconnected edits there — clear that junk out so it
        // can't remap other pointing devices on every launch/disconnect forever.
        guard activeKey != "none" else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Int: RemapAction].self, from: data) else { return }
        mappings = decoded
        seenButtons.formUnion(decoded.keys)
    }
}
