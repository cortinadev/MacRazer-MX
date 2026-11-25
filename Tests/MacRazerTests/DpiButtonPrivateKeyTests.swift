// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// The DPI button of a mouse that reports it as private keys in driver mode (the Cobra
/// HyperSpeed over Bluetooth, `RazerDevices.dpiButtonPrivateKeys`): report 4 turned into key
/// events, and what the remapper does with them. The keys go straight to `handlePrivateKey`
/// (or through a fake `PrivateKeySource`), pointer moves into `handle`, and the actions land
/// in `actionEmitter`, so nothing here opens a HID device, needs a permission or reaches the
/// session. Dock swipes for the same hold are in `InteractiveSwipeTests`.
final class DpiButtonPrivateKeyTests: XCTestCase {
    private let cobra = 0x00DC
    private let basilisk = 0x00BA
    private let keys = DpiButtonPrivateKeys.cobraHyperSpeed
    private let bindings = GestureBindings(
        click: .mediaKey(code: 16, name: "Play / Pause"),
        up: .keystroke(keyCode: 126, modifiers: 0, name: "Up"),
        down: .keystroke(keyCode: 125, modifiers: 0, name: "Down"),
        left: .keystroke(keyCode: 123, modifiers: 0, name: "Left"),
        right: .keystroke(keyCode: 124, modifiers: 0, name: "Right"))

    private final class Emitted {
        var actions: [RemapAction] = []
        var dpiCycles = 0
    }

    /// A `PrivateKeySource` that opens nothing: it records starts and stops, can refuse to
    /// start, and hands on keys as the watcher would.
    private final class FakeSource: PrivateKeySource {
        var refuses = false
        private(set) var starts: [Int] = []
        private(set) var stops = 0
        private(set) var isRunning = false
        private var onEvent: ((PrivateKeyEvent) -> Void)?

        func start(productID: Int, onEvent: @escaping (PrivateKeyEvent) -> Void) -> Bool {
            starts.append(productID)
            guard !refuses else { return false }
            isRunning = true
            self.onEvent = onEvent
            return true
        }

        func stop() {
            stops += 1
            isRunning = false
            onEvent = nil
        }

        func send(_ code: UInt8, down: Bool) { onEvent?(PrivateKeyEvent(code: code, isDown: down)) }
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "MacRazerTests.DpiButtonPrivateKey.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A remapper on the Cobra over Bluetooth whose DPI button does `action` (the gesture
    /// unless given), in driver mode unless `engaged` is false, whose actions and DPI cycles
    /// land in `emitted`.
    private func remapper(_ emitted: Emitted, action: RemapAction? = nil, engaged: Bool = true,
                          source: PrivateKeySource? = nil, name: String = #function) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults(name), actionEmitter: { emitted.actions.append($0) },
                               privateKeys: source)
        r.onDpiCycleRequest = { emitted.dpiCycles += 1 }
        r.setActiveDevice("COBRA-BT", deviceID: cobra)
        r.saveDpiSoftwareAction(action ?? .gesture(bindings))
        if engaged { r.dpiDriverModeChanged(.engaged) }
        return r
    }

    private func key(_ r: ButtonRemapper, _ code: UInt8, down: Bool) {
        r.handlePrivateKey(PrivateKeyEvent(code: code, isDown: down))
    }

    /// What the firmware sends for a short press: the short key, and nothing held 55 ms later.
    private func shortPress(_ r: ButtonRemapper) {
        key(r, keys.short, down: true)
        key(r, keys.short, down: false)
    }

    /// The pointer moving with no button down. Whether the tap let it through.
    @discardableResult
    private func move(_ r: ButtonRemapper, dx: Int64 = 0, dy: Int64 = 0) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero,
                            mouseButton: .left)!
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        return r.handle(type: .mouseMoved, event: event) != nil
    }

    // MARK: Report 4

    /// The report as IOKit hands it over on the Cobra, its id twice, and with it once: the
    /// keys after the ids, nothing held for all zeros, and nil for any other report.
    func testTheReportsKeysAreReadWithTheIdOnceOrTwice() {
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x04, 0x04, 0xD2, 0, 0, 0, 0, 0, 0]), [0xD2])
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x04, 0x52, 0, 0, 0, 0, 0, 0]), [0x52])
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x52, 0, 0]), [0x52], "no id at all")
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0]), [])
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: [0x04, 0x04, 0x52, 0xD2, 0, 0, 0, 0, 0]), [0x52, 0xD2])
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: []), [])
        XCTAssertNil(PrivateKeyReport.heldKeys(reportID: 1, bytes: [0x01, 0x00, 0x05, 0x00]), "pointer movement")
        XCTAssertNil(PrivateKeyReport.heldKeys(reportID: 5, bytes: [0x05, 0x05, 0x02, 0x03]))
    }

    /// Each frame arrives twice (two HID devices deliver it), so a frame that holds what the
    /// last held changes nothing; a press is one down and one up.
    func testADuplicateFrameFiresNothing() {
        var tracker = PrivateKeyTracker()
        XCTAssertEqual(tracker.update([0xD2]), [PrivateKeyEvent(code: 0xD2, isDown: true)])
        XCTAssertEqual(tracker.update([0xD2]), [], "the same frame again")
        XCTAssertEqual(tracker.update([]), [PrivateKeyEvent(code: 0xD2, isDown: false)])
        XCTAssertEqual(tracker.update([]), [])
        XCTAssertEqual(tracker.held, [])
    }

    /// Several keys at once each go down and up on their own, releases first and in code
    /// order, so the result never depends on a set's order.
    func testSeveralKeysAreTrackedEachOnItsOwn() {
        var tracker = PrivateKeyTracker()
        XCTAssertEqual(tracker.update([0xD2, 0x52]), [PrivateKeyEvent(code: 0x52, isDown: true),
                                                      PrivateKeyEvent(code: 0xD2, isDown: true)])
        XCTAssertEqual(tracker.update([0xD2]), [PrivateKeyEvent(code: 0x52, isDown: false)])
        XCTAssertEqual(tracker.update([0x30]), [PrivateKeyEvent(code: 0xD2, isDown: false),
                                                PrivateKeyEvent(code: 0x30, isDown: true)])
        XCTAssertEqual(tracker.held, [0x30])
    }

    /// The captures from the mouse, end to end: a long hold and a short press, each frame
    /// delivered twice.
    func testTheCapturedFramesMakeOneDownAndOneUpPerPress() {
        var tracker = PrivateKeyTracker()
        let frames: [[UInt8]] = [
            [0x04, 0x04, 0xD2, 0, 0, 0, 0, 0, 0], [0x04, 0x04, 0xD2, 0, 0, 0, 0, 0, 0],
            [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0], [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0],
            [0x04, 0x04, 0x52, 0, 0, 0, 0, 0, 0], [0x04, 0x04, 0x52, 0, 0, 0, 0, 0, 0],
            [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0], [0x04, 0x04, 0, 0, 0, 0, 0, 0, 0],
        ]
        let events = frames.flatMap { tracker.update(PrivateKeyReport.heldKeys(reportID: 4, bytes: $0)!) }
        XCTAssertEqual(events, [PrivateKeyEvent(code: 0xD2, isDown: true), PrivateKeyEvent(code: 0xD2, isDown: false),
                                PrivateKeyEvent(code: 0x52, isDown: true), PrivateKeyEvent(code: 0x52, isDown: false)])
    }

    // MARK: Which mice

    /// Only the Cobra over Bluetooth was seen reporting the keys and taking driver mode: the
    /// Basilisk keeps F20, and any mouse not in the list has neither.
    func testOnlyTheCobraOverBluetoothHasPrivateKeys() {
        XCTAssertEqual(RazerDevices.dpiButtonPrivateKeys(pid: cobra), DpiButtonPrivateKeys(short: 0x52, long: 0xD2))
        XCTAssertNil(RazerDevices.dpiButtonPrivateKeys(pid: basilisk))
        XCTAssertNil(RazerDevices.dpiButtonPrivateKeys(pid: 0x00DB), "its dongle")
        XCTAssertNil(RazerDevices.dpiButtonPrivateKeys(pid: 0x00DA), "its cable")
        XCTAssertNil(RazerDevices.dpiButtonPrivateKeys(pid: 0x9999), "unknown")
        for row in RazerDevices.known where row.dpiButtonPrivateKeys != nil {
            XCTAssertEqual(row.connection, .bluetooth, row.name)
            XCTAssertTrue(row.supportsDpiButtonBinding, "\(row.name): only a button MacRazer binds")
        }
        let none = ButtonRemapper(defaults: defaults(#function))
        none.setActiveDevice(nil)
        XCTAssertFalse(none.supportsDpiPrivateKeys, "no mouse")
    }

    // MARK: A gesture

    /// The long key starts a true hold: moves while it is held swipe, once, during the
    /// movement, and its release ends the hold with no click. Moves go through.
    func testTheLongKeyHoldsAndASwipeFiresOnce() {
        let emitted = Emitted()
        let r = remapper(emitted)
        key(r, keys.long, down: true)
        XCTAssertEqual(r.gestureHold?.trigger, ButtonRemapper.dpiButton)
        XCTAssertEqual(r.lastDetectedButton, ButtonRemapper.dpiButton)
        XCTAssertTrue(move(r, dy: -30), "moves go through")
        XCTAssertEqual(emitted.actions, [], "30 points is not a swipe yet")
        move(r, dy: -30)
        XCTAssertEqual(emitted.actions, [bindings.up], "fired during the movement")
        move(r, dx: 300)
        XCTAssertNotNil(r.gestureHold, "a swipe doesn't end the hold: the release does")
        key(r, keys.long, down: false)
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [bindings.up], "once per hold, and no click after it")
        XCTAssertEqual(emitted.dpiCycles, 0)
    }

    /// Each direction is its own action, as for a mouse button's gesture.
    func testEachDirectionFiresItsOwnAction() {
        let emitted = Emitted()
        let r = remapper(emitted)
        for (dx, dy) in [(Int64(0), Int64(80)), (-80, 0), (80, 0)] {
            key(r, keys.long, down: true)
            move(r, dx: dx, dy: dy)
            key(r, keys.long, down: false)
        }
        XCTAssertEqual(emitted.actions, [bindings.down, bindings.left, bindings.right])
    }

    /// A long hold released without a swipe fires nothing: the short press is the click.
    func testALongHoldWithoutASwipeIsNotAClick() {
        let emitted = Emitted()
        let r = remapper(emitted)
        key(r, keys.long, down: true)
        move(r, dx: 12, dy: -8)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [])
        XCTAssertEqual(emitted.dpiCycles, 0)
    }

    /// The short key fires the Click slot, at once, and starts no hold.
    func testTheShortKeyIsTheClick() {
        let emitted = Emitted()
        let r = remapper(emitted)
        key(r, keys.short, down: true)
        XCTAssertEqual(emitted.actions, [bindings.click])
        XCTAssertNil(r.gestureHold)
        key(r, keys.short, down: false)
        move(r, dy: -100)
        XCTAssertEqual(emitted.actions, [bindings.click], "the key's release does nothing")
        XCTAssertEqual(emitted.dpiCycles, 0)
    }

    /// With Click on None (the default, labelled DPI Cycle), a short press cycles DPI as the
    /// firmware would have, and nothing else.
    func testTheShortKeyCyclesDpiWhenClickIsNone() {
        let emitted = Emitted()
        let defaults = GestureBindings.defaults(for: ButtonRemapper.dpiButton)
        XCTAssertEqual(defaults.click, .passthrough)
        let r = remapper(emitted, action: .gesture(defaults))
        shortPress(r)
        shortPress(r)
        XCTAssertEqual(emitted.dpiCycles, 2, "one cycle per press")
        XCTAssertEqual(emitted.actions, [])
    }

    // MARK: Another action

    /// An action that isn't a gesture fires on the short key, and a long press does nothing.
    func testAnotherActionFiresOnTheShortKeyAndALongPressDoesNothing() {
        let emitted = Emitted()
        let media = RemapAction.mediaKey(code: 7, name: "Mute")
        let r = remapper(emitted, action: media)
        shortPress(r)
        XCTAssertEqual(emitted.actions, [media])
        key(r, keys.long, down: true)
        XCTAssertNil(r.gestureHold, "no hold")
        XCTAssertTrue(move(r, dy: -100))
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [media], "nothing for the long press")
        XCTAssertEqual(emitted.dpiCycles, 0, "the button is remapped: no DPI cycle")
    }

    // MARK: When keys count

    /// Keys count only while driver mode is engaged on the connected mouse with an action
    /// saved: not before it is engaged, nor after it failed or went, nor while the mouse is
    /// offline, nor with DPI Cycle (default) chosen. A code that isn't the button's does nothing.
    func testKeysCountOnlyWhileDriverModeIsEngaged() {
        let cases: [(String, (ButtonRemapper) -> Void)] = [
            ("off", { $0.dpiDriverModeChanged(.off) }),
            ("engaging", { $0.dpiDriverModeChanged(.engaging) }),
            ("unavailable", { $0.dpiDriverModeChanged(.unavailable("The mouse didn't accept it.")) }),
            ("paused", { $0.remappingPaused = true }),
            ("no action", { $0.saveDpiSoftwareAction(nil) }),
        ]
        for (name, setUp) in cases {
            let emitted = Emitted()
            let r = remapper(emitted, name: "\(#function)-\(name)")
            setUp(r)
            shortPress(r)
            key(r, keys.long, down: true)
            XCTAssertNil(r.gestureHold, name)
            move(r, dy: -100)
            key(r, keys.long, down: false)
            XCTAssertEqual(emitted.actions, [], name)
            XCTAssertEqual(emitted.dpiCycles, 0, name)
        }
        let emitted = Emitted()
        let r = remapper(emitted, name: "\(#function)-other code")
        key(r, 0x30, down: true)
        key(r, 0x30, down: false)
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [])
    }

    /// The Basilisk has no private keys: its DPI button goes through F20, and keys handed to
    /// its remapper do nothing, engaged or not.
    func testTheBasiliskIgnoresPrivateKeys() {
        let emitted = Emitted()
        let r = ButtonRemapper(defaults: defaults(#function), actionEmitter: { emitted.actions.append($0) })
        r.setActiveDevice("PM2533", deviceID: basilisk)
        r.saveDpiSoftwareAction(.gesture(bindings))
        r.dpiDriverModeChanged(.engaged)
        XCTAssertFalse(r.privateKeysActive)
        shortPress(r)
        key(r, keys.long, down: true)
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [])
    }

    /// The ways a hold of the long key ends early: pausing, driver mode lost or failed, the
    /// action changing, a profile, a mouse button going down, the tap switched off for a
    /// moment, another mouse, and the Mac waking. None fires anything, and the long key's
    /// release after it fires nothing either.
    func testEveryResetEndsTheHoldAndItsReleaseFiresNothing() {
        let endings: [(String, (ButtonRemapper) -> Void)] = [
            ("paused", { $0.remappingPaused = true }),
            ("driver mode lost", { $0.dpiDriverModeChanged(.off) }),
            ("driver mode failed", { $0.dpiDriverModeChanged(.unavailable("The mouse didn't confirm.")) }),
            ("action changed", { $0.saveDpiSoftwareAction(.doubleClick) }),
            ("profile", { $0.setMappings([:]) }),
            ("mouse button", { r in
                let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                    mouseButton: .center)!
                _ = r.handle(type: .otherMouseDown, event: event)
            }),
            ("tap disabled", { _ = $0.handle(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!) }),
            ("device change", { $0.setActiveDevice("OTHER-BT", deviceID: 0x00DC) }),
            ("wake", { $0.cancelGesture() }),
        ]
        for (name, end) in endings {
            let emitted = Emitted()
            let r = remapper(emitted, name: "\(#function)-\(name)")
            key(r, keys.long, down: true)
            move(r, dy: -30)
            end(r)
            XCTAssertNil(r.gestureHold, "\(name) ends the hold")
            XCTAssertTrue(move(r, dy: -100), name)
            key(r, keys.long, down: false)
            XCTAssertEqual(emitted.actions, [], "\(name): no swipe, no click")
        }
    }

    // MARK: Watching the keys

    /// The keys are watched exactly while driver mode is engaged on this mouse, and they reach
    /// the remapper from there.
    func testTheKeysAreWatchedOnlyWhileDriverModeIsEngaged() {
        let emitted = Emitted()
        let source = FakeSource()
        let r = remapper(emitted, engaged: false, source: source)
        XCTAssertEqual(source.starts, [], "not before driver mode")
        r.dpiDriverModeChanged(.engaging)
        XCTAssertEqual(source.starts, [])
        r.dpiDriverModeChanged(.engaged)
        XCTAssertEqual(source.starts, [cobra])
        XCTAssertTrue(source.isRunning)
        source.send(keys.short, down: true)
        XCTAssertEqual(emitted.actions, [bindings.click], "through the source")

        r.dpiDriverModeChanged(.unavailable("The mouse didn't confirm."))
        XCTAssertFalse(source.isRunning, "stopped as driver mode goes")
        r.dpiDriverModeChanged(.engaged)
        XCTAssertTrue(source.isRunning)
        r.setActiveDevice("PM2533", deviceID: basilisk)
        XCTAssertFalse(source.isRunning, "another mouse")
    }

    /// Keys that can't be watched (Input Monitoring not in effect) are remembered, so the
    /// page offers Input Monitoring and driver mode is no longer wanted (the button goes back
    /// to cycling DPI rather than doing nothing), and the controller hears so.
    func testKeysThatCantBeWatchedGiveTheButtonBack() {
        let emitted = Emitted()
        let source = FakeSource()
        source.refuses = true
        var wanted: [Bool] = []
        let r = remapper(emitted, engaged: false, source: source)
        r.onDpiDriverModeWanted = { wanted.append($0) }
        XCTAssertFalse(r.privateKeyInputBlocked)
        r.dpiDriverModeChanged(.engaged)
        XCTAssertEqual(source.starts, [cobra])
        XCTAssertTrue(r.privateKeyInputBlocked)
        XCTAssertTrue(r.dpiActionNeedsInputMonitoring)
        XCTAssertEqual(wanted, [false])
        XCTAssertFalse(ButtonRemapper.wantsDpiDriverMode(privateKeys: true, action: .doubleClick, permissions: true,
                                                         inputMonitoring: { !r.privateKeyInputBlocked }))
    }

    // MARK: Wanting driver mode

    /// Driver mode is wanted only for a mouse with private keys, with an action of MacRazer's,
    /// and with what it takes to carry it out. Input Monitoring is asked last, and only then.
    func testDriverModeIsWantedOnlyWithEverythingItNeeds() {
        var asked = 0
        func wants(_ privateKeys: Bool, _ action: RemapAction?, _ permissions: Bool, _ monitoring: Bool) -> Bool {
            ButtonRemapper.wantsDpiDriverMode(privateKeys: privateKeys, action: action, permissions: permissions,
                                              inputMonitoring: { asked += 1; return monitoring })
        }
        let gesture = RemapAction.gesture(bindings)
        XCTAssertTrue(wants(true, gesture, true, true))
        XCTAssertTrue(wants(true, .doubleClick, true, true))
        asked = 0
        XCTAssertFalse(wants(false, gesture, true, true), "the Basilisk")
        XCTAssertFalse(wants(true, nil, true, true), "DPI Cycle (default), or a function the mouse runs itself")
        XCTAssertFalse(wants(true, gesture, false, true), "no event tap")
        XCTAssertEqual(asked, 0, "Input Monitoring isn't asked when something else is missing")
        XCTAssertFalse(wants(true, gesture, true, false))
        XCTAssertEqual(asked, 1)
    }

    /// The controller hears each change once, not every time the remapper looks.
    func testTheControllerHearsEachChangeOnce() {
        let emitted = Emitted()
        let r = remapper(emitted, engaged: false)
        var wanted: [Bool] = []
        r.onDpiDriverModeWanted = { wanted.append($0) }
        r.saveDpiSoftwareAction(.doubleClick)
        r.saveDpiSoftwareAction(.gesture(bindings))
        r.setMappings([:])
        XCTAssertEqual(wanted, [false], "no event tap in tests, so not wanted, and said once")
    }

    // MARK: The tap

    /// The pointer's moves are asked for while the DPI button is a gesture on this mouse, and
    /// no key events ever are: no F20 is involved, so a keyboard's typing never goes through
    /// the tap for it. The Basilisk's mask is as before.
    func testTheTapAsksForPointerMovesWithoutKeysOnThisMouse() {
        let moved = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        for gestures in [false, true] {
            let mask = ButtonRemapper.eventMask(keyboard: false, gestures: gestures, privateKeyGesture: true)
            XCTAssertNotEqual(mask & moved, 0)
            XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(mask))
            XCTAssertEqual(ButtonRemapper.eventMask(keyboard: false, gestures: gestures) & moved, 0)
        }

        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertNotEqual(r.wantedEventMask & moved, 0, "a gesture")
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(r.wantedEventMask))
        r.saveDpiSoftwareAction(.mediaKey(code: 16, name: "Play / Pause"))
        XCTAssertEqual(r.wantedEventMask & moved, 0, "a media key needs no movement")
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(r.wantedEventMask), "nor keys")
        r.saveDpiSoftwareAction(nil)
        XCTAssertEqual(r.wantedEventMask, ButtonRemapper.eventMask(keyboard: false, gestures: false))

        let bridge = ButtonRemapper(defaults: defaults("\(#function)-basilisk"), actionEmitter: { _ in })
        bridge.setActiveDevice("PM2533", deviceID: basilisk)
        bridge.saveDpiSoftwareAction(.gesture(bindings))
        XCTAssertEqual(bridge.wantedEventMask, ButtonRemapper.eventMask(keyboard: true, gestures: false, dpiGesture: true))
    }

    /// F20 typed on this mouse's Mac (a real keyboard, or an entry not yet cleared) is never
    /// taken: it goes through, press and release.
    func testF20IsNeverTakenOnThisMouse() {
        let emitted = Emitted()
        let r = remapper(emitted)
        r.confirmDpiBridge(binding: .softwareBridge)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 90, keyDown: down)!
            event.flags = []
            XCTAssertNotNil(r.handle(type: down ? .keyDown : .keyUp, event: event), "F20 \(down ? "down" : "up")")
        }
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [])
    }

    // MARK: Choosing

    /// An action of MacRazer's leaves the entry on DPI Cycle on this mouse, so the button is
    /// stock with MacRazer closed; the mouse's own functions are written as everywhere.
    func testAnActionOfMacRazersKeepsDpiCycleOnThisMouse() {
        func assignment(_ action: RemapAction) -> (BLEProtocol.DPIButtonBinding, RemapAction?) {
            let a = ButtonRemapper.dpiButtonAssignment(for: action, privateKeys: true)
            return (a.binding, a.softwareAction)
        }
        let f13 = RemapAction.keystroke(keyCode: 105, modifiers: 0, name: "F13")
        for action in [f13, .doubleClick, .mediaKey(code: 16, name: "Play / Pause"), .gesture(bindings)] {
            XCTAssertEqual(assignment(action).0, .dpiCycle, action.label)
            XCTAssertEqual(assignment(action).1, action, action.label)
        }
        XCTAssertEqual(assignment(.passthrough).0, .dpiCycle)
        XCTAssertNil(assignment(.passthrough).1, "DPI Cycle (default) clears the action")
        let copy = ButtonRemapper.presets.first { $0.id == "copy" }!.action
        XCTAssertEqual(assignment(copy).0, .keyboardShortcut(hidUsage: 0x06, modifiers: 0x08), "⌘C, typed by the mouse")
        XCTAssertNil(assignment(copy).1)
        XCTAssertEqual(assignment(.mouseButton(button: 3, name: "Back Button")).0, .back)
    }

    /// The menu names the action MacRazer carries out over the DPI Cycle the entry holds, and
    /// DPI Cycle itself without one.
    func testTheMenuNamesTheActionOverDpiCycle() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertEqual(r.dpiCycleLabel(for: .dpiCycle), "Gesture (MacRazer)")
        XCTAssertEqual(r.dpiCycleLabel(for: .softwareBridge), "Gesture (MacRazer)")
        XCTAssertEqual(r.dpiCycleLabel(for: .back), "Back")
        r.saveDpiSoftwareAction(nil)
        XCTAssertEqual(r.dpiCycleLabel(for: .dpiCycle), "DPI Cycle (default)")
    }

    /// The gesture editor calls the DPI button's Click None "DPI Cycle" on this mouse, as
    /// that's what it does; every other slot, button and mouse keeps "None".
    func testClickOnNoneIsCalledDpiCycleOnThisMouse() {
        let dpi = ButtonRemapper.dpiButton
        XCTAssertEqual(ButtonRemapper.gestureNoneTitle(slot: .click, button: dpi, privateKeys: true), "DPI Cycle")
        XCTAssertEqual(ButtonRemapper.gestureNoneTitle(slot: .up, button: dpi, privateKeys: true), "None")
        XCTAssertEqual(ButtonRemapper.gestureNoneTitle(slot: .click, button: 3, privateKeys: true), "None")
        XCTAssertEqual(ButtonRemapper.gestureNoneTitle(slot: .click, button: dpi, privateKeys: false), "None")

        let emitted = Emitted()
        var quiet = GestureBindings.defaults(for: dpi)
        quiet.down = .passthrough
        let r = remapper(emitted, action: .gesture(quiet))
        XCTAssertEqual(r.gestureSlotLabel(.click, of: dpi), "DPI Cycle")
        XCTAssertEqual(r.gestureSlotLabel(.down, of: dpi), "None")
        XCTAssertEqual(r.gestureSlotLabel(.up, of: dpi), quiet.up.label)
        r.setGestureAction(.doubleClick, for: .click, of: dpi)
        XCTAssertEqual(r.gestureSlotLabel(.click, of: dpi), "Double Click")
    }

    // MARK: What the page says

    /// The status line: what is missing first, then where driver mode stands, its error as it
    /// came.
    func testTheStatusLineSaysWhatIsMissingThenWhereDriverModeStands() {
        func status(_ mode: DpiDriverModeState, permissions: Bool = true, monitoring: Bool = true,
                    paused: Bool = false) -> String {
            ButtonRemapper.dpiPrivateKeyStatus(permissions: permissions, inputMonitoring: monitoring,
                                               paused: paused, driverMode: mode)
        }
        XCTAssertTrue(status(.engaged, permissions: false).contains("Accessibility"))
        XCTAssertTrue(status(.engaged, monitoring: false).contains("Input Monitoring"))
        XCTAssertEqual(status(.engaged, paused: true), "Waiting for mouse connection")
        XCTAssertEqual(status(.engaged), "Ready")
        XCTAssertEqual(status(.engaging), "Setting up the DPI button…")
        XCTAssertEqual(status(.off), "Setting up the DPI button…", "wanted, not yet started")
        XCTAssertEqual(status(.unavailable("The mouse didn't accept it.")), "The mouse didn't accept it.")
        for mode: DpiDriverModeState in [.engaged, .engaging, .off] {
            for text in [status(mode), status(mode, permissions: false), status(mode, monitoring: false)] {
                XCTAssertFalse(text.contains("\u{2014}"), text)
            }
        }
    }

    /// The editor and the help say how the gesture is made on this mouse, and the help that
    /// the mouse is switched to a mode where MacRazer handles the button while it runs, and
    /// back when it quits or DPI Cycle (default) is chosen.
    func testTheTextSaysHowTheGestureIsMadeAndHowTheMouseIsTakenOver() {
        let editor = RemapView.gestureEditorExplanation(longPress: true, followsPointer: false)
        XCTAssertEqual(editor, "Hold the DPI button until the gesture starts (about a second), then move the mouse up, "
                       + "down, left or right. A short press does Click.")
        let help = RemapView.dpiButtonHelpText(privateKeys: true)
        XCTAssertTrue(help.contains("the mouse is switched to a mode where MacRazer handles the DPI button while it runs."))
        XCTAssertTrue(help.contains("It goes back to normal when MacRazer quits or DPI Cycle (default) is chosen."))
        XCTAssertTrue(help.contains("Hold the DPI button until the gesture starts (about a second)"))
        XCTAssertFalse(help.contains("F20"), "F20 is the Basilisk's")
        for text in [editor, help, RemapView.gestureEditorExplanation(longPress: true, followsPointer: true)] {
            XCTAssertFalse(text.contains("\u{2014}"), "no em dash")
        }
    }
}
