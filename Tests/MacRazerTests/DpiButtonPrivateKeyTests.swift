// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import IOKit
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

    /// A `PrivateKeySource` that opens nothing: it records starts, stops and open checks, can
    /// refuse to start (and then to pass a check), and hands on keys as the watcher would.
    private final class FakeSource: PrivateKeySource {
        var refuses = false
        private(set) var starts: [Int] = []
        private(set) var stops = 0
        private(set) var checks: [Int] = []
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

        func canWatch(productID: Int) -> Bool {
            checks.append(productID)
            return !refuses
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

    /// The two HID devices' copies of a short press don't always alternate: IOKit hands over
    /// all of one device's waiting reports at once, so after the main thread was busy for
    /// longer than the 55 ms pulse one device's press and release come before the other's.
    /// One shared array took that for two presses (two DPI steps, or the click twice); only
    /// the first device to deliver counts now, whatever the order.
    func testOneShortPressIsOnePressWhicheverWayTheTwoDevicesCopiesArrive() {
        let down = Set<UInt8>([keys.short]), none = Set<UInt8>()
        let press = [PrivateKeyEvent(code: keys.short, isDown: true), PrivateKeyEvent(code: keys.short, isDown: false)]
        let orders: [(String, [(Set<UInt8>, Int)])] = [
            ("alternating", [(down, 1), (down, 2), (none, 1), (none, 2)]),
            ("one device's frames, then the other's", [(down, 1), (none, 1), (down, 2), (none, 2)]),
            ("the second device first", [(down, 2), (none, 2), (down, 1), (none, 1)]),
        ]
        for (name, frames) in orders {
            var tracker = PrivateKeyTracker()
            let events = frames.flatMap { tracker.update($0.0, from: $0.1) }
            XCTAssertEqual(events, press, name)
        }

        var tracker = PrivateKeyTracker()
        let twoPresses = [(down, 1), (none, 1), (down, 2), (none, 2), (down, 1), (none, 1), (down, 2), (none, 2)]
        XCTAssertEqual(twoPresses.flatMap { tracker.update($0.0, from: $0.1) }, press + press, "two presses are two")
    }

    /// The device whose frames count goes away while it holds a key (the mouse disconnected
    /// mid-hold): the key comes up, so a hold of the DPI button can't outlive the mouse and
    /// turn the next pointer movement into a swipe. Then the next device to deliver counts.
    /// Another device going away changes nothing.
    func testTheCountedDeviceGoingAwayReleasesWhatItHeld() {
        var tracker = PrivateKeyTracker()
        XCTAssertEqual(tracker.update([keys.long], from: 1), [PrivateKeyEvent(code: keys.long, isDown: true)])
        XCTAssertEqual(tracker.update([keys.long], from: 2), [])
        XCTAssertEqual(tracker.sourceGone(2), [], "not the counted one")
        XCTAssertEqual(tracker.held, [keys.long])
        XCTAssertEqual(tracker.sourceGone(1), [PrivateKeyEvent(code: keys.long, isDown: false)])
        XCTAssertNil(tracker.source)
        XCTAssertEqual(tracker.sourceGone(1), [], "once")
        XCTAssertEqual(tracker.update([keys.short], from: 3), [PrivateKeyEvent(code: keys.short, isDown: true)],
                       "the next device to deliver counts")
        XCTAssertEqual(tracker.update([], from: 1), [], "a device that went away and came back doesn't")
    }

    /// The release that comes with a disconnect ends the hold through the remapper as the long
    /// key's own release would: an open dock swipe ends, and no click fires.
    func testAReleaseFromADisconnectEndsTheHold() {
        let emitted = Emitted()
        let r = remapper(emitted)
        var tracker = PrivateKeyTracker()
        tracker.update([keys.long], from: 7).forEach(r.handlePrivateKey)
        XCTAssertEqual(r.gestureHold?.trigger, ButtonRemapper.dpiButton)
        tracker.sourceGone(7).forEach(r.handlePrivateKey)
        XCTAssertNil(r.gestureHold)
        XCTAssertTrue(move(r, dy: -200))
        XCTAssertEqual(emitted.actions, [], "the pointer moved by anything else after that is no swipe")
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

    /// With Click on None a short press does nothing at all: no action, and no DPI cycle,
    /// which the firmware doesn't do either in driver mode.
    func testAShortPressWithClickOnNoneDoesNothing() {
        let emitted = Emitted()
        var quiet = bindings
        quiet.click = .passthrough
        let r = remapper(emitted, action: .gesture(quiet))
        shortPress(r)
        shortPress(r)
        XCTAssertEqual(emitted.dpiCycles, 0, "None asks for no cycle")
        XCTAssertEqual(emitted.actions, [])
        XCTAssertNil(r.gestureHold)
    }

    /// With Click on DPI Cycle a short press steps the DPI stage as the firmware would have:
    /// exactly one cycle per press, and nothing else. The short key's release adds none.
    func testAShortPressWithClickOnDpiCycleCyclesOncePerPress() {
        let emitted = Emitted()
        var cycling = bindings
        cycling.click = .dpiCycle
        let r = remapper(emitted, action: .gesture(cycling))
        key(r, keys.short, down: true)
        XCTAssertEqual(emitted.dpiCycles, 1, "at the press")
        key(r, keys.short, down: false)
        XCTAssertEqual(emitted.dpiCycles, 1, "nothing at the release")
        shortPress(r)
        shortPress(r)
        XCTAssertEqual(emitted.dpiCycles, 3, "one cycle per press")
        XCTAssertEqual(emitted.actions, [], "DPI Cycle is never posted as an action")
    }

    /// DPI Cycle in a direction steps the DPI stage once, when the swipe fires, as any other
    /// action in a slot does.
    func testDpiCycleInADirectionCyclesOncePerSwipe() {
        let emitted = Emitted()
        var cycling = bindings
        cycling.up = .dpiCycle
        let r = remapper(emitted, action: .gesture(cycling))
        key(r, keys.long, down: true)
        move(r, dy: -80)
        move(r, dy: -80)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.dpiCycles, 1)
        XCTAssertEqual(emitted.actions, [])
        key(r, keys.long, down: true)
        move(r, dy: 80)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [bindings.down], "the other directions are unchanged")
        XCTAssertEqual(emitted.dpiCycles, 1)
    }

    /// DPI Cycle does nothing anywhere but a slot of this mouse's DPI gesture in driver mode:
    /// as the DPI button's whole action, before driver mode is engaged, in a side button's
    /// gesture or as a side button's mapping. No action is posted and no cycle is asked for.
    func testDpiCycleIsInertAnywhereElse() {
        let everywhere = GestureBindings(click: .dpiCycle, up: .dpiCycle, down: .dpiCycle, left: .dpiCycle,
                                         right: .dpiCycle)
        let emitted = Emitted()
        let whole = remapper(emitted, action: .dpiCycle, name: "\(#function)-whole")
        shortPress(whole)
        key(whole, keys.long, down: true)
        move(whole, dy: -100)
        key(whole, keys.long, down: false)

        let notEngaged = remapper(emitted, action: .gesture(everywhere), engaged: false,
                                  name: "\(#function)-not engaged")
        shortPress(notEngaged)

        let side = remapper(emitted, action: nil, name: "\(#function)-side")
        side.saveDpiSoftwareAction(nil)
        side.setAction(.gesture(everywhere), for: 3)
        side.setAction(.dpiCycle, for: 4)
        func click(_ button: CGMouseButton, dy: Int64 = 0) {
            let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                               mouseButton: button)!
            down.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
            _ = side.handle(type: .otherMouseDown, event: down)
            if dy != 0 {
                let drag = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDragged, mouseCursorPosition: .zero,
                                   mouseButton: button)!
                drag.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
                drag.setIntegerValueField(.mouseEventDeltaY, value: dy)
                _ = side.handle(type: .otherMouseDragged, event: drag)
            }
            let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero,
                             mouseButton: button)!
            up.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
            _ = side.handle(type: .otherMouseUp, event: up)
        }
        let back = CGMouseButton(rawValue: 3)!, forward = CGMouseButton(rawValue: 4)!
        click(back)
        click(back, dy: -100)
        click(forward)

        XCTAssertEqual(emitted.actions, [])
        XCTAssertEqual(emitted.dpiCycles, 0)
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

    /// Keys that can't be watched (the mouse's HID device wouldn't open) are remembered, so
    /// driver mode is no longer wanted (the button goes back to cycling DPI rather than doing
    /// nothing), and the controller hears so. Not for the rest of the run: a look at the
    /// permissions tries to open the mouse again, without touching it, and once it opens the
    /// block is gone.
    func testKeysThatCantBeWatchedGiveTheButtonBackUntilTheyOpen() {
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
        XCTAssertEqual(wanted, [false])

        r.retryBlockedPrivateKeys()
        XCTAssertEqual(source.checks, [cobra], "an open check, not a start")
        XCTAssertTrue(r.privateKeyInputBlocked, "still refused")
        source.refuses = false
        r.retryBlockedPrivateKeys()
        XCTAssertEqual(source.checks, [cobra, cobra])
        XCTAssertFalse(r.privateKeyInputBlocked, "it opens now: driver mode can be wanted again")
        r.retryBlockedPrivateKeys()
        XCTAssertEqual(source.checks, [cobra, cobra], "nothing to check once unblocked")
        XCTAssertEqual(source.starts, [cobra], "the keys are watched again only once driver mode is")
    }

    /// What a start of the watcher counts as working: any of the mouse's devices open. With
    /// none there, a manager that opened waits for the mouse; one refused for Input Monitoring
    /// is a failure, to be tried again, rather than a watch that never delivers a key.
    func testAWatchWorksOnlyWithADeviceOpenOrAManagerWaitingForOne() {
        let notPermitted = IOReturn(bitPattern: 0xE00002E2)
        XCTAssertTrue(DpiPrivateKeyWatcher.startWorks(managerOpen: kIOReturnSuccess, present: 2, opened: 2))
        XCTAssertTrue(DpiPrivateKeyWatcher.startWorks(managerOpen: notPermitted, present: 2, opened: 1),
                      "one device is enough")
        XCTAssertTrue(DpiPrivateKeyWatcher.startWorks(managerOpen: kIOReturnSuccess, present: 0, opened: 0),
                      "waiting for the mouse to show up")
        XCTAssertFalse(DpiPrivateKeyWatcher.startWorks(managerOpen: notPermitted, present: 0, opened: 0),
                       "refused, with nothing to see")
        XCTAssertFalse(DpiPrivateKeyWatcher.startWorks(managerOpen: notPermitted, present: 2, opened: 0))
        XCTAssertFalse(DpiPrivateKeyWatcher.startWorks(managerOpen: kIOReturnSuccess, present: 2, opened: 0))
    }

    // MARK: Wanting driver mode

    /// Driver mode is wanted only for a mouse with private keys, with an action of MacRazer's,
    /// and with what it takes to carry it out. Input Monitoring is asked last, and only then.
    /// What is missing is named, in that order: Accessibility, Input Monitoring, a reopen.
    func testDriverModeIsWantedOnlyWithEverythingItNeeds() {
        var asked = 0
        func need(_ privateKeys: Bool, _ action: RemapAction?, _ permissions: Bool, _ monitoring: Bool,
                  blocked: Bool = false) -> DpiDriverModeNeed {
            DpiDriverModeNeed(privateKeys: privateKeys, action: action, permissions: permissions,
                              inputMonitoring: { asked += 1; return monitoring }, keysBlocked: blocked)
        }
        let gesture = RemapAction.gesture(bindings)
        XCTAssertEqual(need(true, gesture, true, true), .ready)
        XCTAssertEqual(need(true, .doubleClick, true, true), .ready)
        asked = 0
        XCTAssertEqual(need(false, gesture, true, true), DpiDriverModeNeed.none, "the Basilisk")
        XCTAssertEqual(need(true, nil, true, true), DpiDriverModeNeed.none,
                       "DPI Cycle (default), or a function the mouse runs itself")
        XCTAssertEqual(need(true, gesture, false, true), .accessibility, "no event tap")
        XCTAssertEqual(need(true, gesture, false, false, blocked: true), .accessibility)
        XCTAssertEqual(asked, 0, "Input Monitoring isn't asked when something else is missing")
        XCTAssertEqual(need(true, gesture, true, false), .inputMonitoring)
        XCTAssertEqual(need(true, gesture, true, false, blocked: true), .inputMonitoring,
                       "not granted is what is missing, whatever a start said earlier")
        XCTAssertEqual(need(true, gesture, true, true, blocked: true), .relaunch)
        XCTAssertEqual(asked, 3)

        let all: [DpiDriverModeNeed] = [.none, .ready, .accessibility, .inputMonitoring, .relaunch]
        XCTAssertEqual(all.filter(\.wantsDriverMode), [.ready])
        XCTAssertEqual(all.filter(\.waitsForPermission), [.accessibility, .inputMonitoring])
    }

    /// The permissions are looked at every few seconds only while driver mode waits for one
    /// of them and the mouse is connected: not when it is wanted and ready, not needed, nor
    /// waiting for a reopen that looking again can't bring.
    func testThePermissionsAreLookedAtAgainOnlyWhileOneIsAllThatsMissing() {
        XCTAssertTrue(DpiDriverModeNeed.accessibility.rechecksPermissions(paused: false))
        XCTAssertTrue(DpiDriverModeNeed.inputMonitoring.rechecksPermissions(paused: false))
        for need: DpiDriverModeNeed in [.accessibility, .inputMonitoring] {
            XCTAssertFalse(need.rechecksPermissions(paused: true), "\(need): the mouse is away")
        }
        for need: DpiDriverModeNeed in [.none, .ready, .relaunch] {
            XCTAssertFalse(need.rechecksPermissions(paused: false), "\(need)")
        }
        XCTAssertGreaterThanOrEqual(ButtonRemapper.permissionRecheckInterval, 1)
        XCTAssertLessThanOrEqual(ButtonRemapper.permissionRecheckInterval, 10, "a few seconds")
    }

    /// The remapper waits for a permission exactly while the rules above say so: here, where
    /// tests have no event tap, while the DPI button has an action of MacRazer's on a
    /// connected Cobra. It stops as the action goes, the mouse goes offline or is another.
    func testTheRemapperWaitsForAPermissionOnlyWhileItMatters() {
        let emitted = Emitted()
        let r = remapper(emitted, engaged: false)
        var wanted: [Bool] = []
        r.onDpiDriverModeWanted = { wanted.append($0) }
        XCTAssertFalse(r.waitsForPermission, "nothing has looked yet")
        r.saveDpiSoftwareAction(.doubleClick)
        XCTAssertTrue(r.waitsForPermission, "no Accessibility in tests")
        XCTAssertEqual(r.currentDpiDriverModeNeed, .accessibility)
        r.remappingPaused = true
        XCTAssertFalse(r.waitsForPermission, "the mouse is away")
        r.remappingPaused = false
        XCTAssertTrue(r.waitsForPermission)
        r.saveDpiSoftwareAction(nil)
        XCTAssertFalse(r.waitsForPermission, "DPI Cycle (default) needs nothing")
        r.saveDpiSoftwareAction(.gesture(bindings))
        XCTAssertTrue(r.waitsForPermission)
        r.setActiveDevice("PM2533", deviceID: basilisk)
        XCTAssertFalse(r.waitsForPermission, "the Basilisk has no driver mode")
        XCTAssertEqual(wanted, [false], "never wanted without the permissions")
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
        for privateKeys in [true, false] {
            let a = ButtonRemapper.dpiButtonAssignment(for: .dpiCycle, privateKeys: privateKeys)
            XCTAssertEqual(a.binding, .dpiCycle, "the whole button cycling DPI is the firmware's DPI Cycle")
            XCTAssertNil(a.softwareAction)
        }
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

    /// The gesture editor's menus start with None and, for the DPI button on this mouse, DPI
    /// Cycle beside it as a choice of its own, in every slot. No other button, and the DPI
    /// button of no other mouse, offers DPI Cycle.
    func testTheDpiGestureMenusOfferNoneAndDpiCycleOnThisMouseOnly() {
        let dpi = ButtonRemapper.dpiButton
        XCTAssertEqual(ButtonRemapper.gestureSlotLeadingChoices(button: dpi, privateKeys: true), [.passthrough, .dpiCycle])
        XCTAssertEqual(ButtonRemapper.gestureSlotLeadingChoices(button: dpi, privateKeys: true).map(\.label),
                       ["None", "DPI Cycle"])
        XCTAssertEqual(ButtonRemapper.gestureSlotLeadingChoices(button: dpi, privateKeys: false), [.passthrough],
                       "the Basilisk: software can't cycle its DPI")
        for button in [2, 3, 4, 5] {
            XCTAssertEqual(ButtonRemapper.gestureSlotLeadingChoices(button: button, privateKeys: true), [.passthrough],
                           ButtonRemapper.label(for: button))
        }

        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertEqual(r.gestureSlotLeadingChoices(of: dpi), [.passthrough, .dpiCycle])
        XCTAssertEqual(r.gestureSlotLeadingChoices(of: 3), [.passthrough])
        let basilisk = ButtonRemapper(defaults: defaults("\(#function)-basilisk"), actionEmitter: { _ in })
        basilisk.setActiveDevice("PM2533", deviceID: self.basilisk)
        XCTAssertEqual(basilisk.gestureSlotLeadingChoices(of: dpi), [.passthrough])
    }

    /// Each slot shows its action's label: None for none, DPI Cycle for DPI Cycle, which are
    /// two different choices now.
    func testTheEditorNamesNoneAndDpiCycleApart() {
        let dpi = ButtonRemapper.dpiButton
        let emitted = Emitted()
        var quiet = GestureBindings.defaults(for: dpi, privateKeys: true)
        quiet.down = .passthrough
        let r = remapper(emitted, action: .gesture(quiet))
        XCTAssertEqual(r.gestureSlotLabel(.click, of: dpi), "DPI Cycle")
        XCTAssertEqual(r.gestureSlotLabel(.down, of: dpi), "None")
        XCTAssertEqual(r.gestureSlotLabel(.up, of: dpi), quiet.up.label)
        r.setGestureAction(.passthrough, for: .click, of: dpi)
        XCTAssertEqual(r.gestureSlotLabel(.click, of: dpi), "None")
        r.setGestureAction(.dpiCycle, for: .left, of: dpi)
        XCTAssertEqual(r.gestureSlotLabel(.left, of: dpi), "DPI Cycle")
        r.setGestureAction(.doubleClick, for: .click, of: dpi)
        XCTAssertEqual(r.gestureSlotLabel(.click, of: dpi), "Double Click")
        XCTAssertEqual(r.gestureSlotLabel(.click, of: 3), "None", "not a gesture")
    }

    // MARK: A new gesture, and one saved before

    /// A new DPI gesture on this mouse clicks DPI Cycle, so a short press steps DPI as it does
    /// stock. On the Basilisk, and for any other button, the click is what it was.
    func testANewDpiGestureClicksDpiCycleOnThisMouse() {
        let dpi = ButtonRemapper.dpiButton
        XCTAssertEqual(GestureBindings.defaults(for: dpi, privateKeys: true).click, .dpiCycle)
        XCTAssertEqual(GestureBindings.defaults(for: dpi).click, .passthrough)
        XCTAssertEqual(GestureBindings.defaults(for: 3, privateKeys: true).click, ButtonRemapper.originalClick(for: 3))
        XCTAssertEqual(GestureBindings.defaults(for: dpi, privateKeys: true).up,
                       GestureBindings.defaults(for: dpi).up, "the directions are the usual defaults")

        let emitted = Emitted()
        let r = remapper(emitted, action: nil)
        XCTAssertEqual(r.newDpiGesture, .gesture(.defaults(click: .dpiCycle)))
        r.saveDpiSoftwareAction(r.newDpiGesture)
        shortPress(r)
        XCTAssertEqual(emitted.dpiCycles, 1, "a short press of a new gesture cycles DPI")
        XCTAssertEqual(emitted.actions, [])

        let bridge = ButtonRemapper(defaults: defaults("\(#function)-basilisk"), actionEmitter: { _ in })
        bridge.setActiveDevice("PM2533", deviceID: basilisk)
        XCTAssertEqual(bridge.newDpiGesture, .gesture(.defaults(click: .passthrough)))
    }

    /// What a build from before DPI Cycle was its own choice saved for the DPI gesture: Click
    /// on None, as `{"passthrough":{}}`. It reads as it was written, and a short press of it
    /// does nothing now, no DPI cycle included; it isn't turned into DPI Cycle. DPI Cycle
    /// itself is saved under a key of its own, and reads back.
    func testAGestureSavedBeforeDpiCycleKeepsNone() throws {
        let saved = #"""
        {"gesture":{"_0":{
          "click":{"passthrough":{}},
          "up":{"keystroke":{"keyCode":126,"modifiers":10747904,"name":"Mission Control  ⌃↑"}},
          "down":{"keystroke":{"keyCode":125,"modifiers":10747904,"name":"App Exposé  ⌃↓"}},
          "left":{"keystroke":{"keyCode":123,"modifiers":10747904,"name":"Space Left  ⌃←"}},
          "right":{"keystroke":{"keyCode":124,"modifiers":10747904,"name":"Space Right  ⌃→"}}
        }}}
        """#
        let decoded = try JSONDecoder().decode(RemapAction.self, from: Data(saved.utf8))
        XCTAssertEqual(decoded, .gesture(.defaults(click: .passthrough)))
        XCTAssertEqual(try JSONDecoder().decode(RemapAction.self, from: Data(#"{"passthrough":{}}"#.utf8)), .passthrough)

        let store = defaults(#function)
        store.set(Data(saved.utf8), forKey: "dpiCycleSoftwareAction-COBRA-BT")
        let emitted = Emitted()
        let r = ButtonRemapper(defaults: store, actionEmitter: { emitted.actions.append($0) })
        r.onDpiCycleRequest = { emitted.dpiCycles += 1 }
        r.setActiveDevice("COBRA-BT", deviceID: cobra)
        r.dpiDriverModeChanged(.engaged)
        XCTAssertEqual(r.dpiCycleSoftwareAction, decoded, "loaded as saved")
        XCTAssertEqual(r.gestureSlotLabel(.click, of: ButtonRemapper.dpiButton), "None")
        shortPress(r)
        XCTAssertEqual(emitted.dpiCycles, 0)
        XCTAssertEqual(emitted.actions, [])
        key(r, keys.long, down: true)
        move(r, dy: -80)
        key(r, keys.long, down: false)
        XCTAssertEqual(emitted.actions, [GestureBindings.defaults(click: .passthrough).up],
                       "the gesture itself works as before")

        let encoded = try JSONEncoder().encode(RemapAction.dpiCycle)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"dpiCycle":{}}"#)
        XCTAssertEqual(try JSONDecoder().decode(RemapAction.self, from: encoded), .dpiCycle)
        let withDpiCycle = RemapAction.gesture(.defaults(click: .dpiCycle))
        XCTAssertEqual(try JSONDecoder().decode(RemapAction.self, from: JSONEncoder().encode(withDpiCycle)), withDpiCycle)
        XCTAssertEqual(RemapAction.dpiCycle.label, "DPI Cycle")
        XCTAssertFalse(RemapAction.dpiCycle.isGesture)
    }

    // MARK: What the page says

    /// The status line: what is missing first, then where driver mode stands, its error as it
    /// came. A missing Input Monitoring no longer asks for a relaunch, as it is picked up by
    /// itself; a grant macOS hasn't applied to this run says plainly to quit and reopen.
    func testTheStatusLineSaysWhatIsMissingThenWhereDriverModeStands() {
        func status(_ mode: DpiDriverModeState, need: DpiDriverModeNeed = .ready, paused: Bool = false) -> String {
            ButtonRemapper.dpiPrivateKeyStatus(need: need, paused: paused, driverMode: mode)
        }
        XCTAssertEqual(status(.engaged, need: .accessibility), "MacRazer needs Accessibility to carry out this action.")
        XCTAssertEqual(status(.off, need: .inputMonitoring),
                       "MacRazer needs Input Monitoring to see the DPI button. Turn it on in System Settings.")
        XCTAssertEqual(status(.off, need: .relaunch),
                       "Input Monitoring is on, but macOS hasn't applied it to MacRazer MX yet. Quit and reopen MacRazer MX.")
        XCTAssertEqual(status(.off, need: .relaunch, paused: true), status(.off, need: .relaunch), "first")
        XCTAssertEqual(status(.engaged, paused: true), "Waiting for mouse connection")
        XCTAssertEqual(status(.engaged), "Ready")
        XCTAssertEqual(status(.engaging), "Setting up the DPI button…")
        XCTAssertEqual(status(.off), "Setting up the DPI button…", "wanted, not yet started")
        XCTAssertEqual(status(.unavailable("The mouse didn't accept it.")), "The mouse didn't accept it.")
        let needs: [DpiDriverModeNeed] = [.ready, .accessibility, .inputMonitoring, .relaunch]
        for mode: DpiDriverModeState in [.engaged, .engaging, .off] {
            for text in needs.map({ status(mode, need: $0) }) {
                XCTAssertFalse(text.contains("\u{2014}"), text)
                XCTAssertFalse(text.contains("relaunch"), text)
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
