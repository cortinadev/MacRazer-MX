// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// The DPI button as a gesture button, over Bluetooth. The mouse types F20 for it, and its
/// movement comes as `.mouseMoved`, as no mouse button is down. On the Basilisk V3 X a hold
/// is the F20 key down and up. The Cobra HyperSpeed only sends F20 as a pulse when a short
/// press is released (`RazerDevices.dpiButtonActsOnRelease`), so there its gesture is a click,
/// then a swipe within `ButtonRemapper.latchedGestureWindow`. Synthetic events into `handle`,
/// with the actions caught by `actionEmitter` instead of posted and time from a clock the
/// test moves, so nothing here needs Accessibility, reaches the session or waits. The bridge
/// is set up as `DpiCycleSoftwareBridgeTests` does: a saved software action and a read of the
/// mouse confirming F20.
final class DpiButtonGestureTests: XCTestCase {
    private let basilisk = 0x00BA
    private let cobra = 0x00DC
    private let bindings = GestureBindings(
        click: .mediaKey(code: 16, name: "Play / Pause"),
        up: .keystroke(keyCode: 126, modifiers: 0, name: "Up"),
        down: .keystroke(keyCode: 125, modifiers: 0, name: "Down"),
        left: .keystroke(keyCode: 123, modifiers: 0, name: "Left"),
        right: .keystroke(keyCode: 124, modifiers: 0, name: "Right"))

    private final class Emitted {
        var actions: [RemapAction] = []
    }

    /// Seconds since some start, moved by the test.
    private final class Clock {
        var now: TimeInterval = 1000
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "MacRazerTests.DpiButtonGesture.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A remapper on a mouse over Bluetooth (the Basilisk unless `pid` says otherwise) whose
    /// DPI button does `action`, with the F20 assignment confirmed, whose actions land in
    /// `emitted` and whose time is `clock`'s.
    private func remapper(_ emitted: Emitted, action: RemapAction? = nil, pid: Int? = nil,
                          clock: Clock = Clock(), name: String = #function) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults(name), actionEmitter: { emitted.actions.append($0) },
                               clock: { clock.now })
        let pid = pid ?? basilisk
        r.setActiveDevice(pid == cobra ? "COBRA-BT" : "PM2533", deviceID: pid)
        r.saveDpiSoftwareAction(action ?? .gesture(bindings))
        r.confirmDpiBridge(binding: .softwareBridge)
        return r
    }

    /// The DPI button's F20 going down or up. Whether the tap let it through, answered while
    /// the event is still alive: the tap returns it unretained.
    @discardableResult
    private func f20(_ r: ButtonRemapper, down: Bool, repeating: Bool = false) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 90, keyDown: down)!
        event.flags = []
        if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return r.handle(type: down ? .keyDown : .keyUp, event: event) != nil
    }

    /// What the Cobra sends for a click of its DPI button: F20 down and up. Whether the tap
    /// let either through.
    @discardableResult
    private func pulse(_ r: ButtonRemapper) -> Bool {
        let down = f20(r, down: true)
        let up = f20(r, down: false)
        return down || up
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

    @discardableResult
    private func click(_ r: ButtonRemapper, _ type: CGEventType, button: Int) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
        return r.handle(type: type, event: event) != nil
    }

    /// The ways a hold ends early, each the way the app gets there: pausing, the F20 assignment
    /// no longer confirmed, the action changing, a mouse button going down, the tap being
    /// switched off for a moment, a profile applied, another mouse, and the Mac waking.
    private var earlyEndings: [(String, (ButtonRemapper) -> Void)] {
        [
            ("paused", { $0.remappingPaused = true }),
            ("unconfirmed", { $0.confirmDpiBridge(binding: .dpiCycle) }),
            ("action changed", { $0.saveDpiSoftwareAction(.doubleClick) }),
            ("mouse button", { r in
                let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                    mouseButton: .center)!
                _ = r.handle(type: .otherMouseDown, event: event)
            }),
            ("tap disabled", { _ = $0.handle(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!) }),
            ("profile", { $0.setMappings([:]) }),
            ("device change", { $0.setActiveDevice("OTHER-BT", deviceID: 0x00DC) }),
            ("wake", { $0.cancelGesture() }),
        ]
    }

    // MARK: The hold (Basilisk V3 X)

    /// A hold fires nothing until the movement is a swipe, then exactly one action, while
    /// the hand is still moving. Apps see neither the key-down nor the key-up of F20.
    func testAHoldFiresOneSwipeOnceTheMovementIsFarEnough() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertFalse(f20(r, down: true), "the press is swallowed")
        XCTAssertEqual(emitted.actions, [], "nothing on the press")
        move(r, dy: -30)
        XCTAssertEqual(emitted.actions, [], "30 points is not a swipe yet")
        move(r, dy: -30)
        XCTAssertEqual(emitted.actions, [bindings.up], "fired during the movement, upward as y shrinks")
        move(r, dy: -200)
        move(r, dx: 300)
        XCTAssertFalse(f20(r, down: false), "the release is swallowed")
        XCTAssertEqual(emitted.actions, [bindings.up], "once per hold, and no click after a swipe")
        XCTAssertNil(r.gestureHold)
    }

    /// Each direction is its own action, as for a mouse button's gesture.
    func testEachDirectionFiresItsOwnAction() {
        let emitted = Emitted()
        let r = remapper(emitted)
        for (dx, dy) in [(Int64(0), Int64(80)), (-80, 0), (80, 0)] {
            f20(r, down: true)
            move(r, dx: dx, dy: dy)
            f20(r, down: false)
        }
        XCTAssertEqual(emitted.actions, [bindings.down, bindings.left, bindings.right])
    }

    /// A press and release in place fires the click, at the release.
    func testAPressWithoutMovementFiresTheClickOnRelease() {
        let emitted = Emitted()
        let r = remapper(emitted)
        f20(r, down: true)
        move(r, dx: 12, dy: -8)
        XCTAssertEqual(emitted.actions, [], "nothing on the press, nor for a small drift")
        f20(r, down: false)
        XCTAssertEqual(emitted.actions, [bindings.click])
    }

    /// Software can't cycle DPI, so a DPI gesture's click starts as None, which fires nothing.
    func testTheDefaultClickIsNoneAndFiresNothing() {
        let emitted = Emitted()
        let defaults = GestureBindings.defaults(for: ButtonRemapper.dpiButton)
        XCTAssertEqual(defaults.click, .passthrough)
        let r = remapper(emitted, action: .gesture(defaults))
        XCTAssertFalse(f20(r, down: true))
        XCTAssertFalse(f20(r, down: false), "swallowed even with nothing to fire")
        XCTAssertEqual(emitted.actions, [])
    }

    /// The key repeats while the button is held. A repeat is the same press: it's swallowed
    /// and doesn't start the hold over, so the movement before it still counts.
    func testKeyRepeatsDoNotRestartTheHold() {
        let emitted = Emitted()
        let r = remapper(emitted)
        f20(r, down: true)
        move(r, dy: 30)
        for _ in 0..<3 { XCTAssertFalse(f20(r, down: true, repeating: true), "a repeat is swallowed") }
        move(r, dy: 30)
        XCTAssertEqual(emitted.actions, [bindings.down], "60 points since the press, not 30 since a repeat")
        f20(r, down: false)
        XCTAssertEqual(emitted.actions, [bindings.down])
    }

    /// A hold has no window: it lasts as long as the button is held, however long that is,
    /// and only its release ends it. No timer is started for it.
    func testAHoldHasNoWindow() {
        let emitted = Emitted()
        let clock = Clock()
        let r = remapper(emitted, clock: clock)
        f20(r, down: true)
        XCTAssertNil(r.gestureHold?.latchDeadline)
        XCTAssertNil(r.latchTimer)
        clock.now += 5
        XCTAssertFalse(r.expireLatchedGesture(now: clock.now), "nothing latched to expire")
        XCTAssertNotNil(r.gestureHold, "still held after five seconds")
        move(r, dx: -80)
        XCTAssertEqual(emitted.actions, [bindings.left])
        XCTAssertNotNil(r.gestureHold, "a swipe doesn't end a hold: its release does")
        f20(r, down: false)
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [bindings.left])
    }

    /// Pointer moves are the hot path: with no hold of the DPI button they go straight
    /// through, and one of a mouse button's hold doesn't feed it. A DPI hold's moves go
    /// through too: no app saw a button go down, so to them it's a plain move.
    func testPointerMovesAlwaysPassThrough() {
        for pid in [basilisk, cobra] {
            let emitted = Emitted()
            let r = remapper(emitted, pid: pid, name: "\(#function)-\(pid)")
            XCTAssertTrue(move(r, dy: 100), "no hold")
            r.beginGesture(bindings, trigger: 3)
            XCTAssertTrue(move(r, dy: 100), "a mouse button's hold")
            XCTAssertEqual(r.gestureHold?.recognizer, GestureRecognizer(), "which moves don't feed")
            r.cancelGesture()
            f20(r, down: true)
            XCTAssertTrue(move(r, dy: 100), "the DPI button's own hold")
            XCTAssertEqual(emitted.actions, [bindings.down], "PID \(pid)")
        }
    }

    /// Any other action still fires on the press, once, as before gestures. On the Cobra
    /// too: a click is all an action that isn't a gesture needs.
    func testAnActionThatIsNotAGestureFiresOnThePress() {
        for pid in [basilisk, cobra] {
            let emitted = Emitted()
            let media = RemapAction.mediaKey(code: 7, name: "Mute")
            let r = remapper(emitted, action: media, pid: pid, name: "\(#function)-\(pid)")
            XCTAssertFalse(f20(r, down: true))
            XCTAssertEqual(emitted.actions, [media], "on the press, not the release")
            XCTAssertFalse(f20(r, down: true, repeating: true))
            XCTAssertNil(r.gestureHold, "no hold")
            XCTAssertNil(r.latchTimer, "no window")
            XCTAssertTrue(move(r, dy: -100))
            XCTAssertFalse(f20(r, down: false))
            XCTAssertEqual(emitted.actions, [media], "PID \(pid)")
        }
    }

    // MARK: Ending a hold

    /// Whatever ends a hold early, the release of the press that was swallowed is swallowed
    /// too, and it fires no click.
    func testAHoldEndedEarlyStillSwallowsItsRelease() {
        for (name, end) in earlyEndings {
            let emitted = Emitted()
            let r = remapper(emitted, name: "\(#function)-\(name)")
            XCTAssertFalse(f20(r, down: true), name)
            XCTAssertNotNil(r.gestureHold, name)
            end(r)
            XCTAssertNil(r.gestureHold, "\(name) ends the hold")
            XCTAssertFalse(f20(r, down: true, repeating: true), "\(name): its repeats are still swallowed")
            XCTAssertTrue(move(r, dy: -100), name)
            XCTAssertFalse(f20(r, down: false), "\(name): its release is still swallowed")
            XCTAssertEqual(emitted.actions, [], "\(name): no swipe, no click")
        }
    }

    /// A device change ends a hold too: the next mouse's DPI button may do something else.
    func testADeviceChangeEndsTheHold() {
        let emitted = Emitted()
        let r = remapper(emitted)
        f20(r, down: true)
        r.setActiveDevice("PM2533-2", deviceID: basilisk)
        XCTAssertNil(r.gestureHold)
        XCTAssertFalse(f20(r, down: false), "the release of the swallowed press")
        XCTAssertEqual(emitted.actions, [])
    }

    /// A press let through (here, paused) lets its repeats and release through as well, and
    /// a later press works again.
    func testAPressLetThroughLetsItsReleaseThrough() {
        let emitted = Emitted()
        let r = remapper(emitted)
        r.remappingPaused = true
        XCTAssertTrue(f20(r, down: true))
        XCTAssertTrue(f20(r, down: true, repeating: true))
        XCTAssertNil(r.gestureHold)
        XCTAssertTrue(f20(r, down: false))
        r.remappingPaused = false
        f20(r, down: true)
        XCTAssertNotNil(r.gestureHold)
        f20(r, down: false)
        XCTAssertEqual(emitted.actions, [bindings.click])
    }

    // MARK: Click, then swipe (Cobra HyperSpeed)

    /// The F20 pulse opens the window; its key-up, swallowed like any whose key-down was,
    /// leaves it open. A swipe in the window fires its direction during the movement, once,
    /// and ends the hold there and then: no click, and nothing left for the timer.
    func testOnTheCobraAClickThenASwipeFiresOneDirectionAndNoClick() {
        let emitted = Emitted()
        let clock = Clock()
        let r = remapper(emitted, pid: cobra, clock: clock)
        XCTAssertTrue(r.dpiButtonActsOnRelease)
        XCTAssertFalse(f20(r, down: true), "the pulse's key-down is swallowed")
        XCTAssertEqual(r.gestureHold?.latchDeadline, clock.now + ButtonRemapper.latchedGestureWindow)
        XCTAssertNotNil(r.latchTimer)
        clock.now += 0.05
        XCTAssertFalse(f20(r, down: false), "its key-up is swallowed")
        XCTAssertNotNil(r.gestureHold, "and leaves the window open")
        XCTAssertEqual(emitted.actions, [], "nothing on the click")

        clock.now += 0.2
        XCTAssertTrue(move(r, dy: -30), "moves go through")
        XCTAssertEqual(emitted.actions, [], "30 points is not a swipe yet")
        clock.now += 0.1
        move(r, dy: -30)
        XCTAssertEqual(emitted.actions, [bindings.up], "fired during the movement")
        XCTAssertNil(r.gestureHold, "the swipe ends the hold")
        XCTAssertNil(r.latchTimer, "and its timer")

        move(r, dy: -200)
        move(r, dx: 300)
        XCTAssertFalse(r.expireLatchedGesture(now: clock.now + 10), "nothing left to expire")
        XCTAssertEqual(emitted.actions, [bindings.up], "one swipe, and no click after it")
    }

    /// Movement between the pulse's key-down and key-up counts with the movement after it:
    /// the key-up doesn't end or restart anything.
    func testOnTheCobraTheKeyUpInsideTheWindowDoesNotEndIt() {
        let emitted = Emitted()
        let r = remapper(emitted, pid: cobra)
        f20(r, down: true)
        move(r, dx: 30)
        XCTAssertFalse(f20(r, down: false))
        XCTAssertNotNil(r.gestureHold)
        move(r, dx: 30)
        XCTAssertEqual(emitted.actions, [bindings.right], "60 points since the click")
    }

    /// Each direction is its own action, as with a hold.
    func testOnTheCobraEachDirectionFiresItsOwnAction() {
        let emitted = Emitted()
        let clock = Clock()
        let r = remapper(emitted, pid: cobra, clock: clock)
        for (dx, dy) in [(Int64(0), Int64(80)), (-80, 0), (80, 0), (0, -80)] {
            pulse(r)
            clock.now += 0.3
            move(r, dx: dx, dy: dy)
            clock.now += 1
        }
        XCTAssertEqual(emitted.actions, [bindings.down, bindings.left, bindings.right, bindings.up])
    }

    /// With no swipe, the window's end fires the click, once, and not a moment before it.
    /// A small drift in the window isn't a swipe.
    func testOnTheCobraTheWindowEndingWithoutASwipeFiresTheClickOnce() {
        let emitted = Emitted()
        let clock = Clock()
        let r = remapper(emitted, pid: cobra, clock: clock)
        let start = clock.now
        XCTAssertFalse(pulse(r))
        move(r, dx: 12, dy: -8)
        XCTAssertFalse(r.expireLatchedGesture(now: start + ButtonRemapper.latchedGestureWindow - 0.01),
                       "still open")
        XCTAssertNotNil(r.gestureHold)
        XCTAssertEqual(emitted.actions, [])
        XCTAssertTrue(r.expireLatchedGesture(now: start + ButtonRemapper.latchedGestureWindow))
        XCTAssertEqual(emitted.actions, [bindings.click])
        XCTAssertNil(r.gestureHold)
        XCTAssertNil(r.latchTimer, "the timer goes with the hold")
        XCTAssertFalse(r.expireLatchedGesture(now: start + 10))
        XCTAssertEqual(emitted.actions, [bindings.click], "once")
    }

    /// The timer runs the same expiry. Fired early, before the clock reaches the window's end,
    /// it waits for the rest instead.
    func testOnTheCobraTheTimerEndsTheWindow() {
        let emitted = Emitted()
        let clock = Clock()
        let r = remapper(emitted, pid: cobra, clock: clock)
        let start = clock.now
        pulse(r)
        clock.now += ButtonRemapper.latchedGestureWindow / 2
        r.latchTimer?.fire()
        XCTAssertNotNil(r.gestureHold, "early: the window is still open")
        XCTAssertEqual(r.latchTimer?.isValid, true, "and a timer waits for the rest")
        XCTAssertEqual(emitted.actions, [])

        clock.now = start + ButtonRemapper.latchedGestureWindow
        r.latchTimer?.fire()
        XCTAssertNil(r.gestureHold)
        XCTAssertNil(r.latchTimer)
        XCTAssertEqual(emitted.actions, [bindings.click])
    }

    /// Movement after the window is no swipe. The first move past it ends the hold, as the
    /// timer would have (the click), when the timer hasn't run yet; later ones fire nothing.
    func testOnTheCobraMovementAfterTheWindowFiresNoSwipe() {
        let emitted = Emitted()
        let clock = Clock()
        let r = remapper(emitted, pid: cobra, clock: clock)
        pulse(r)
        clock.now += ButtonRemapper.latchedGestureWindow
        XCTAssertTrue(move(r, dy: -100), "moves go through")
        XCTAssertEqual(emitted.actions, [bindings.click], "the window's click, not Swipe Up")
        XCTAssertNil(r.gestureHold)
        XCTAssertNil(r.latchTimer)
        move(r, dy: -100)
        move(r, dx: 100)
        XCTAssertEqual(emitted.actions, [bindings.click])

        // The default click is None: then the late movement fires nothing at all.
        let quiet = Emitted()
        let q = remapper(quiet, action: .gesture(.defaults(for: ButtonRemapper.dpiButton)), pid: cobra,
                         clock: clock, name: "\(#function)-none")
        pulse(q)
        clock.now += ButtonRemapper.latchedGestureWindow + 1
        XCTAssertTrue(q.expireLatchedGesture(now: clock.now))
        move(q, dy: -100)
        move(q, dx: -100)
        XCTAssertEqual(quiet.actions, [])
    }

    /// A second click while the window is open starts it over, from that click: the window
    /// ends a full `latchedGestureWindow` after it, and only movement after it counts. The
    /// first click's own click doesn't fire.
    func testOnTheCobraASecondClickStartsTheWindowOver() {
        let emitted = Emitted()
        let clock = Clock()
        let r = remapper(emitted, pid: cobra, clock: clock)
        let window = ButtonRemapper.latchedGestureWindow
        pulse(r)
        clock.now += window * 0.8
        move(r, dy: 30)
        let firstTimer = r.latchTimer
        XCTAssertFalse(pulse(r), "the second pulse is swallowed too")
        let second = clock.now
        XCTAssertEqual(r.gestureHold?.latchDeadline, second + window)
        XCTAssertEqual(firstTimer?.isValid, false, "the first window's timer is stopped")
        XCTAssertEqual(r.latchTimer?.isValid, true, "and a new one waits")

        clock.now += window * 0.8
        XCTAssertFalse(r.expireLatchedGesture(now: clock.now), "past the first window, not the second")
        move(r, dy: 30)
        XCTAssertEqual(emitted.actions, [], "30 points since the second click, not 60 since the first")
        move(r, dy: 30)
        XCTAssertEqual(emitted.actions, [bindings.down])

        // Without a swipe: one click, a window after the last pulse.
        pulse(r)
        clock.now += window * 0.5
        pulse(r)
        let last = clock.now
        XCTAssertFalse(r.expireLatchedGesture(now: last + window * 0.75))
        XCTAssertEqual(emitted.actions, [bindings.down], "the first of the two clicks fires nothing")
        XCTAssertTrue(r.expireLatchedGesture(now: last + window))
        XCTAssertEqual(emitted.actions, [bindings.down, bindings.click])
    }

    /// Whatever ends a hold early ends a latched one too, with its timer: no swipe, no click,
    /// and the movement and the window's end that follow fire nothing. A pulse cut off
    /// between its key-down and key-up still has its key-up swallowed.
    func testOnTheCobraEarlyEndingsStopTheWindowAndItsTimer() {
        for (name, end) in earlyEndings {
            let emitted = Emitted()
            let clock = Clock()
            let r = remapper(emitted, pid: cobra, clock: clock, name: "\(#function)-\(name)")
            XCTAssertFalse(f20(r, down: true), name)
            XCTAssertNotNil(r.gestureHold?.latchDeadline, name)
            let timer = r.latchTimer
            XCTAssertEqual(timer?.isValid, true, name)
            end(r)
            XCTAssertNil(r.gestureHold, "\(name) ends the hold")
            XCTAssertNil(r.latchTimer, "\(name) stops its timer")
            XCTAssertEqual(timer?.isValid, false, "\(name): invalidated, not only forgotten")
            XCTAssertFalse(f20(r, down: false), "\(name): the pulse's key-up is still swallowed")
            XCTAssertTrue(move(r, dy: -100), name)
            clock.now += 10
            XCTAssertFalse(r.expireLatchedGesture(now: clock.now), name)
            XCTAssertEqual(emitted.actions, [], "\(name): no swipe, no click")
        }
    }

    /// A mouse button's hold replacing a latched one stops the window's timer: it is never
    /// latched, whatever the mouse.
    func testOnTheCobraAMouseButtonsHoldIsNeverLatched() {
        let emitted = Emitted()
        let clock = Clock()
        let r = remapper(emitted, pid: cobra, clock: clock)
        r.setMappings([3: .gesture(bindings)])
        pulse(r)
        XCTAssertNotNil(r.latchTimer)
        XCTAssertFalse(click(r, .otherMouseDown, button: 3), "Back starts its own hold")
        XCTAssertEqual(r.gestureHold?.trigger, 3)
        XCTAssertNil(r.gestureHold?.latchDeadline)
        XCTAssertNil(r.latchTimer)
        clock.now += 5
        XCTAssertFalse(r.expireLatchedGesture(now: clock.now))
        XCTAssertFalse(click(r, .otherMouseUp, button: 3))
        XCTAssertEqual(emitted.actions, [bindings.click], "Back's click at its release, none from the DPI button")
    }

    // MARK: Which mice

    /// Only the Cobra over Bluetooth has been seen sending F20 as a pulse on release. The
    /// Basilisk keeps the hold, unverified either way, and so does any mouse not in the list.
    func testOnlyTheCobraOverBluetoothActsOnRelease() {
        XCTAssertTrue(RazerDevices.dpiButtonActsOnRelease(pid: cobra))
        XCTAssertFalse(RazerDevices.dpiButtonActsOnRelease(pid: basilisk))
        XCTAssertFalse(RazerDevices.dpiButtonActsOnRelease(pid: 0x00DB), "its dongle can't bind the button")
        XCTAssertFalse(RazerDevices.dpiButtonActsOnRelease(pid: 0x00DA))
        XCTAssertFalse(RazerDevices.dpiButtonActsOnRelease(pid: 0x9999), "unknown")
        for row in RazerDevices.known where row.dpiButtonActsOnRelease {
            XCTAssertTrue(row.supportsDpiButtonBinding, "\(row.name): only a button MacRazer binds")
        }

        let emitted = Emitted()
        XCTAssertTrue(remapper(emitted, pid: cobra, name: "\(#function)-cobra").dpiButtonActsOnRelease)
        XCTAssertFalse(remapper(emitted, pid: basilisk, name: "\(#function)-basilisk").dpiButtonActsOnRelease)
        let none = ButtonRemapper(defaults: defaults("\(#function)-none"))
        none.setActiveDevice(nil)
        XCTAssertFalse(none.dpiButtonActsOnRelease, "no mouse")
    }

    /// The editor and the DPI button's help say how the gesture is made: clicked, then
    /// moved, on a mouse whose button only reports a click; held otherwise.
    func testTheTextSaysHowTheGestureIsMade() {
        let click = RemapView.gestureEditorExplanation(clickThenSwipe: true)
        let hold = RemapView.gestureEditorExplanation(clickThenSwipe: false)
        XCTAssertTrue(click.hasPrefix("Click the DPI button, then move the mouse up, down, left or right."))
        XCTAssertTrue(click.contains("Click runs"))
        XCTAssertTrue(hold.hasPrefix("Hold the button"), "mouse buttons keep the hold")
        XCTAssertTrue(RemapView.dpiButtonHelpText(clickThenSwipe: true).hasSuffix(click))
        XCTAssertFalse(RemapView.dpiButtonHelpText(clickThenSwipe: false).contains("Click the DPI button"))
        for text in [click, hold, RemapView.dpiButtonHelpText(clickThenSwipe: true)] {
            XCTAssertFalse(text.contains("\u{2014}"), "no em dash")
        }
    }

    // MARK: The tap's events

    /// Every move of the pointer goes through the tap while it asks for them, so it asks only
    /// while the DPI button is a gesture, and only with the keys: without F20 no hold of the
    /// DPI button can start.
    func testTheTapAsksForPointerMovesOnlyForADpiGesture() {
        let moved = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        for gestures in [false, true] {
            XCTAssertNotEqual(ButtonRemapper.eventMask(keyboard: true, gestures: gestures, dpiGesture: true) & moved, 0)
            XCTAssertEqual(ButtonRemapper.eventMask(keyboard: true, gestures: gestures, dpiGesture: false) & moved, 0)
            XCTAssertEqual(ButtonRemapper.eventMask(keyboard: false, gestures: gestures, dpiGesture: true) & moved, 0)
        }

        let emitted = Emitted()
        let r = remapper(emitted, action: .mediaKey(code: 16, name: "Play / Pause"))
        XCTAssertTrue(ButtonRemapper.includesKeyboardEvents(r.wantedEventMask))
        XCTAssertEqual(r.wantedEventMask & moved, 0, "a media key needs no movement")
        r.saveDpiSoftwareAction(.gesture(bindings))
        XCTAssertNotEqual(r.wantedEventMask & moved, 0, "a gesture does")
        r.saveDpiSoftwareAction(nil)
        XCTAssertEqual(r.wantedEventMask & moved, 0, "DPI Cycle (default) again")
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(r.wantedEventMask))
    }

    /// When macOS refuses the keyboard tap, the fallback drops the keys and the pointer moves,
    /// and is the mask the next check asks for, so the tap isn't reinstalled on every change.
    func testTheKeyboardFallbackDropsThePointerMovesToo() {
        for gestures in [false, true] {
            for dpiGesture in [false, true] {
                XCTAssertEqual(
                    ButtonRemapper.eventMask(keyboard: true, gestures: gestures, dpiGesture: dpiGesture)
                        & ~ButtonRemapper.bridgeEventsMask,
                    ButtonRemapper.eventMask(keyboard: false, gestures: gestures, dpiGesture: dpiGesture),
                    "gestures: \(gestures), dpiGesture: \(dpiGesture)")
            }
        }
    }

    // MARK: Choosing and editing

    /// A gesture as the DPI action survives the trip through UserDefaults, the way a relaunch
    /// reads it back.
    func testAGestureDpiActionIsSavedAndReadBack() {
        let shared = defaults()
        let first = ButtonRemapper(defaults: shared)
        first.setActiveDevice("COBRA-BT", deviceID: 0x00DC)
        first.saveDpiSoftwareAction(.gesture(bindings))

        let second = ButtonRemapper(defaults: shared)
        second.setActiveDevice("COBRA-BT", deviceID: 0x00DC)
        XCTAssertEqual(second.dpiCycleSoftwareAction, .gesture(bindings))
        XCTAssertEqual(second.gestureBindings(for: ButtonRemapper.dpiButton), bindings)
    }

    /// The gesture editor edits the DPI button's gesture as it does a mouse button's: each
    /// change is saved, nothing goes into the mouse buttons' table, and a nested gesture is
    /// refused.
    func testTheGestureEditorEditsTheDpiGesture() {
        let shared = defaults()
        let r = ButtonRemapper(defaults: shared)
        r.setActiveDevice("COBRA-BT", deviceID: 0x00DC)
        r.saveDpiSoftwareAction(.gesture(bindings))
        let dpi = ButtonRemapper.dpiButton
        r.setGestureAction(.doubleClick, for: .up, of: dpi)
        XCTAssertEqual(r.gestureBindings(for: dpi)?.up, .doubleClick)
        r.setGestureAction(.gesture(bindings), for: .down, of: dpi)
        XCTAssertEqual(r.gestureBindings(for: dpi)?.down, bindings.down, "no gesture inside a gesture")
        r.makeGesture(dpi)
        XCTAssertEqual(r.mappings, [:], "the DPI button is never a row of the mouse buttons' table")
        XCTAssertEqual(ButtonRemapper.label(for: dpi), "DPI Button")

        let reread = ButtonRemapper(defaults: shared)
        reread.setActiveDevice("COBRA-BT", deviceID: 0x00DC)
        XCTAssertEqual(reread.gestureBindings(for: dpi)?.up, .doubleClick, "saved as it's made")
    }

    /// The menu's choices go to the mouse when it can carry them out itself, so they work
    /// without MacRazer, and through F20 otherwise.
    func testAChoiceIsTheMousesOwnFunctionWhenItHasOne() {
        func assignment(_ action: RemapAction) -> (BLEProtocol.DPIButtonBinding, RemapAction?) {
            let a = ButtonRemapper.dpiButtonAssignment(for: action)
            return (a.binding, a.softwareAction)
        }
        let copy = ButtonRemapper.presets.first { $0.id == "copy" }!.action
        XCTAssertEqual(assignment(copy).0, .keyboardShortcut(hidUsage: 0x06, modifiers: 0x08), "⌘C, typed by the mouse")
        XCTAssertNil(assignment(copy).1)
        XCTAssertEqual(assignment(.mouseButton(button: 2, name: "Middle Click")).0, .middleClick)
        XCTAssertEqual(assignment(.mouseButton(button: 3, name: "Back Button")).0, .back)
        XCTAssertEqual(assignment(.mouseButton(button: 0, name: "Left Click")).0, .leftClick)

        let f13 = RemapAction.keystroke(keyCode: 105, modifiers: 0, name: "F13")
        let gesture = RemapAction.gesture(bindings)
        for action in [f13, .doubleClick, .mediaKey(code: 16, name: "Play / Pause"), gesture,
                       .mouseButton(button: 8, name: "Button 9")] {
            XCTAssertEqual(assignment(action).0, .softwareBridge, action.label)
            XCTAssertEqual(assignment(action).1, action, action.label)
        }
    }
}
