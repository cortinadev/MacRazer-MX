// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// A gesture whose slots hold the system swipes, through the tap: Mission Control, App
/// Exposé and the Spaces follow the pointer as a dock swipe while the hold lasts, and every
/// other slot keeps firing once. Synthetic events into `handle`; the actions land in
/// `actionEmitter` and the swipe's frames in a recorder (`DockSwipeOutput`), with time from a
/// clock the test moves, so nothing needs Accessibility, reaches the session or waits.
final class InteractiveSwipeTests: XCTestCase {
    private let back = 3
    private let cobra = 0x00DC
    /// 1 point is 0.001 of progress sideways and 0.002 up or down.
    private let scale = DockSwipe.Scale(horizontal: 0.001, vertical: 0.002)
    private let playPause = RemapAction.mediaKey(code: 16, name: "Play / Pause")
    private let copy = RemapAction.keystroke(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue, name: "Copy  ⌘C")

    /// The defaults (Mission Control, App Exposé, Space Left, Space Right) with Play / Pause
    /// as the click, so a click shows up.
    private var bindings: GestureBindings { .defaults(click: playPause) }

    private final class Recorded {
        var actions: [RemapAction] = []
        var frames: [DockSwipe.Frame] = []
        var phases: [DockSwipe.Phase] { frames.map(\.phase) }
    }

    private final class Clock {
        var now: TimeInterval = 1000
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "MacRazerTests.InteractiveSwipe.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func output(_ recorded: Recorded) -> DockSwipeOutput {
        let scale = scale
        return DockSwipeOutput(send: { recorded.frames.append($0) }, scale: { scale })
    }

    /// A remapper with Back as a gesture of `bindings` (the defaults unless given).
    private func remapper(_ recorded: Recorded, bindings: GestureBindings? = nil, clock: Clock = Clock(),
                          name: String = #function) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults(name), actionEmitter: { recorded.actions.append($0) },
                               dockSwipes: output(recorded), clock: { clock.now })
        r.setMappings([back: .gesture(bindings ?? self.bindings)])
        return r
    }

    /// The same on a Cobra over Bluetooth, whose DPI button is the gesture, with F20 confirmed.
    private func cobraRemapper(_ recorded: Recorded, bindings: GestureBindings? = nil, clock: Clock,
                               name: String = #function) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults(name), actionEmitter: { recorded.actions.append($0) },
                               dockSwipes: output(recorded), clock: { clock.now })
        r.setActiveDevice("COBRA-BT", deviceID: cobra)
        r.saveDpiSoftwareAction(.gesture(bindings ?? self.bindings))
        r.confirmDpiBridge(binding: .softwareBridge)
        return r
    }

    /// Whether the tap let the event through, answered while `event` is still alive.
    @discardableResult
    private func send(_ r: ButtonRemapper, _ type: CGEventType, button: Int? = nil,
                      dx: Int64 = 0, dy: Int64 = 0) -> Bool {
        let mouseButton = type == .mouseMoved ? CGMouseButton.left : CGMouseButton(rawValue: UInt32(button ?? back))!
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                            mouseButton: mouseButton)!
        event.setIntegerValueField(.mouseEventDeltaX, value: dx)
        event.setIntegerValueField(.mouseEventDeltaY, value: dy)
        return r.handle(type: type, event: event) != nil
    }

    /// A drag of the held button, 10 ms after the last event.
    @discardableResult
    private func drag(_ r: ButtonRemapper, _ clock: Clock, dx: Int64 = 0, dy: Int64 = 0) -> Bool {
        clock.now += 0.01
        return send(r, .otherMouseDragged, dx: dx, dy: dy)
    }

    /// The pointer moving with no button down, 10 ms after the last event.
    @discardableResult
    private func move(_ r: ButtonRemapper, _ clock: Clock, dx: Int64 = 0, dy: Int64 = 0) -> Bool {
        clock.now += 0.01
        return send(r, .mouseMoved, dx: dx, dy: dy)
    }

    /// The Cobra's click of its DPI button: F20 down and up.
    private func pulse(_ r: ButtonRemapper) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 90, keyDown: down)!
            event.flags = []
            _ = r.handle(type: down ? .keyDown : .keyUp, event: event)
        }
    }

    // MARK: A mouse button's hold

    /// Holding the button and moving left drags the desktop towards the previous Space: one
    /// `began` as the hold leaves the dead zone, a `changed` for each movement after it with
    /// the total so far, and the release ends it with the hand's velocity, for the Dock to
    /// finish or snap back. No shortcut is typed, and apps see none of it.
    func testAHoldDragsTheSwipeAndTheReleaseEndsIt() throws {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        XCTAssertFalse(send(r, .otherMouseDown))
        XCTAssertFalse(drag(r, clock, dx: -8), "swallowed while held, as before")
        XCTAssertEqual(recorded.frames, [], "inside the dead zone")
        drag(r, clock, dx: -8)
        XCTAssertEqual(recorded.phases, [.began])
        XCTAssertEqual(recorded.frames.first?.kind, .horizontal)
        for _ in 0..<3 { drag(r, clock, dx: -20) }
        XCTAssertEqual(recorded.phases, [.began, .changed, .changed, .changed])
        let progress = recorded.frames.map(\.progress)
        for (got, expected) in zip(progress, [-0.016, -0.036, -0.056, -0.076]) {
            XCTAssertEqual(got, expected, accuracy: 1e-9)
        }
        XCTAssertFalse(drag(r, clock, dy: -40), "the other axis is the swipe's too, and swallowed")
        XCTAssertEqual(recorded.frames.count, 4, "but moves nothing")

        XCTAssertFalse(send(r, .otherMouseUp))
        let end = try XCTUnwrap(recorded.frames.last)
        XCTAssertEqual(end.phase, .ended)
        XCTAssertEqual(end.progress, -0.076, accuracy: 1e-9)
        XCTAssertLessThan(end.velocity, 0, "still moving left")
        XCTAssertEqual(recorded.phases.filter { $0 == .began }.count, 1)
        XCTAssertEqual(recorded.actions, [], "no Space Left shortcut, and no click")
        XCTAssertNil(r.gestureHold)
        XCTAssertTrue(drag(r, clock, dx: -20), "no hold to feed")
        XCTAssertEqual(recorded.frames.count, 5)
    }

    /// Each default direction heads for its slot: up opens Mission Control (negative), down
    /// App Exposé, right the next Space.
    func testEachDefaultDirectionHeadsForItsSlot() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        for (dx, dy) in [(Int64(0), Int64(-30)), (0, 30), (30, 0)] {
            send(r, .otherMouseDown)
            drag(r, clock, dx: dx, dy: dy)
            send(r, .otherMouseUp)
        }
        let began = recorded.frames.filter { $0.phase == .began }
        XCTAssertEqual(began.map(\.kind), [.vertical, .vertical, .horizontal])
        XCTAssertEqual(began.map { $0.progress < 0 }, [true, false, false])
        XCTAssertEqual(recorded.actions, [])
    }

    /// The click still fires for a press and release inside the dead zone, and nothing is
    /// sent to the Dock.
    func testAPressInsideTheDeadZoneIsStillTheClick() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dx: 12, dy: 8)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [playPause])
        XCTAssertEqual(recorded.frames, [])
    }

    /// Out and back to the start is no longer a click once the swipe began: it snaps back
    /// (cancelled), as a trackpad's swipe taken back does.
    func testASwipeTakenBackIsCancelledAndNoClick() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dx: 40)
        drag(r, clock, dx: -40)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.phases, [.began, .changed, .cancelled])
        XCTAssertEqual(recorded.frames.last?.progress, 0)
        XCTAssertEqual(recorded.actions, [])
    }

    /// A slot that isn't a system swipe keeps the discrete swipe: it fires once at 50 points,
    /// and no dock swipe begins, even across the opposite slot that is one.
    func testAnotherActionStillFiresOnce() {
        let recorded = Recorded()
        let clock = Clock()
        var mixed = bindings
        mixed.up = copy
        let r = remapper(recorded, bindings: mixed, clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dy: -30)
        XCTAssertEqual(recorded.actions, [])
        drag(r, clock, dy: -30)
        XCTAssertEqual(recorded.actions, [copy], "fired during the movement")
        drag(r, clock, dy: 200)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [copy], "once, and not App Exposé after it")
        XCTAssertEqual(recorded.frames, [])

        // The same hold going left is the Space swipe.
        send(r, .otherMouseDown)
        drag(r, clock, dx: -30)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.phases, [.began, .ended])
        XCTAssertEqual(recorded.actions, [copy])
    }

    /// With nowhere for dock swipes to go (a macOS that ignores them), the presets are the
    /// keyboard shortcuts they always were.
    func testWithoutDockSwipesThePresetsStayShortcuts() {
        let recorded = Recorded()
        let r = ButtonRemapper(defaults: defaults(#function), actionEmitter: { recorded.actions.append($0) })
        r.setMappings([back: .gesture(bindings)])
        send(r, .otherMouseDown)
        send(r, .otherMouseDragged, dy: -60)
        send(r, .otherMouseUp)
        XCTAssertEqual(recorded.actions, [bindings.up])
        XCTAssertNil(r.gestureHold)
    }

    /// The ways a hold ends early. Each must cancel the open swipe, so the Dock is never
    /// left halfway between two Spaces.
    private var earlyEndings: [(String, (ButtonRemapper) -> Void)] {
        [
            ("paused", { $0.remappingPaused = true }),
            ("tap disabled", { _ = $0.handle(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!) }),
            ("device change", { $0.setActiveDevice("OTHER-MOUSE") }),
            ("action changed", { $0.setAction(.passthrough, for: 3) }),
            ("slot changed", { $0.setGestureAction(.doubleClick, for: .left, of: 3) }),
            ("profile", { $0.setMappings([:]) }),
            ("another button", { r in
                let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                    mouseButton: .center)!
                _ = r.handle(type: .otherMouseDown, event: event)
            }),
            ("wake", { $0.cancelGesture() }),
        ]
    }

    /// Every reset of a hold cancels its swipe, once, with the progress it had; the release
    /// after it sends nothing more and fires nothing.
    func testEveryEarlyEndingCancelsTheSwipe() {
        for (name, end) in earlyEndings {
            let recorded = Recorded()
            let clock = Clock()
            let r = remapper(recorded, clock: clock, name: "\(#function)-\(name)")
            send(r, .otherMouseDown)
            drag(r, clock, dx: 30)
            drag(r, clock, dx: 10)
            end(r)
            XCTAssertNil(r.gestureHold, name)
            XCTAssertEqual(recorded.phases, [.began, .changed, .cancelled], name)
            XCTAssertEqual(recorded.frames.last?.progress ?? 0, 0.04, accuracy: 1e-9, name)
            XCTAssertEqual(recorded.frames.last?.velocity, 0, name)
            XCTAssertFalse(send(r, .otherMouseUp), "\(name): the release of a swallowed press")
            drag(r, clock, dx: 30)
            XCTAssertEqual(recorded.frames.count, 3, "\(name): nothing after the cancel")
            XCTAssertEqual(recorded.actions, [], "\(name): no click")
        }
    }

    /// A reset before the swipe began has nothing to cancel.
    func testAResetInsideTheDeadZoneSendsNothing() {
        let recorded = Recorded()
        let clock = Clock()
        let r = remapper(recorded, clock: clock)
        send(r, .otherMouseDown)
        drag(r, clock, dx: 5)
        r.cancelGesture()
        XCTAssertEqual(recorded.frames, [])
    }

    /// The editor says the four follow the pointer, where they do.
    func testTheEditorSaysTheSystemSwipesFollowThePointer() {
        for clickThenSwipe in [false, true] {
            let text = RemapView.gestureEditorExplanation(clickThenSwipe: clickThenSwipe, followsPointer: true)
            XCTAssertTrue(text.contains("Mission Control, App Exposé, Space Left and Space Right follow the pointer"))
            XCTAssertFalse(text.contains("\u{2014}"), "no em dash")
            XCTAssertFalse(RemapView.gestureEditorExplanation(clickThenSwipe: clickThenSwipe, followsPointer: false)
                .contains("follow the pointer"), "not where they stay shortcuts")
        }
    }

    // MARK: The Cobra's DPI button: a click, then the swipe

    /// After the click, movement drives the same swipe. With no release to end it, it ends
    /// once the pointer has been still for `latchedSwipeStillness`, with the velocity it had
    /// when it last moved (a flick stays a flick), and no click.
    func testOnTheCobraTheSwipeEndsWhenThePointerStops() throws {
        let recorded = Recorded()
        let clock = Clock()
        let r = cobraRemapper(recorded, clock: clock)
        pulse(r)
        XCTAssertNotNil(r.gestureHold?.latchDeadline)
        XCTAssertTrue(move(r, clock, dy: -10), "moves go through, as before")
        XCTAssertEqual(recorded.frames, [])
        move(r, clock, dy: -10)
        XCTAssertEqual(recorded.phases, [.began])
        XCTAssertEqual(recorded.frames.first?.kind, .vertical)
        for _ in 0..<10 { move(r, clock, dy: -10) }
        XCTAssertEqual(recorded.phases.filter { $0 == .changed }.count, 10)
        let lastMove = clock.now
        XCTAssertEqual(r.gestureHold?.latchDeadline ?? 0, lastMove + ButtonRemapper.latchedSwipeStillness,
                       accuracy: 1e-9, "the deadline follows the pointer")
        XCTAssertEqual(r.latchTimer?.isValid, true)

        XCTAssertFalse(r.expireLatchedGesture(now: lastMove + ButtonRemapper.latchedSwipeStillness - 0.01))
        XCTAssertTrue(r.expireLatchedGesture(now: lastMove + ButtonRemapper.latchedSwipeStillness))
        let end = try XCTUnwrap(recorded.frames.last)
        XCTAssertEqual(end.phase, .ended)
        XCTAssertEqual(end.progress, -0.24, accuracy: 1e-9, "12 moves of 10 points up")
        XCTAssertEqual(end.velocity, -2.0, accuracy: 0.25, "about 1000 points a second, not faded by the wait")
        XCTAssertEqual(recorded.actions, [], "no Mission Control shortcut and no click")
        XCTAssertNil(r.gestureHold)
        XCTAssertNil(r.latchTimer)
        XCTAssertTrue(move(r, clock, dy: -10))
        XCTAssertEqual(recorded.phases.filter { $0 == .ended }.count, 1)
    }

    /// The timer runs the same end. Fired before the pointer has been still long enough, it
    /// waits for the rest; the click's window is no longer what it waits for.
    func testOnTheCobraTheTimerEndsTheSwipe() {
        let recorded = Recorded()
        let clock = Clock()
        let r = cobraRemapper(recorded, clock: clock)
        pulse(r)
        clock.now += 0.5
        move(r, clock, dx: 30)
        XCTAssertEqual(recorded.phases, [.began], "late in the window is still in time")
        for _ in 0..<20 { move(r, clock, dx: 5) }
        XCTAssertEqual(recorded.frames.count, 21, "on past the window's end")
        clock.now += ButtonRemapper.latchedSwipeStillness / 2
        r.latchTimer?.fire()
        XCTAssertNotNil(r.gestureHold, "not still long enough yet")
        XCTAssertEqual(r.latchTimer?.isValid, true, "and a timer waits for the rest")
        clock.now += ButtonRemapper.latchedSwipeStillness / 2 + 0.001
        r.latchTimer?.fire()
        XCTAssertNil(r.gestureHold)
        XCTAssertNil(r.latchTimer)
        XCTAssertEqual(recorded.phases.last, .ended)
        XCTAssertEqual(recorded.actions, [])
    }

    /// A move that comes after the pointer has been still long enough, before the timer ran,
    /// ends the swipe instead of moving it.
    func testOnTheCobraALateMoveEndsTheSwipe() {
        let recorded = Recorded()
        let clock = Clock()
        let r = cobraRemapper(recorded, clock: clock)
        pulse(r)
        move(r, clock, dx: -30)
        clock.now += ButtonRemapper.latchedSwipeStillness
        XCTAssertTrue(move(r, clock, dx: -300))
        XCTAssertEqual(recorded.phases, [.began, .ended])
        XCTAssertEqual(recorded.frames.last?.progress ?? 0, -0.03, accuracy: 1e-9, "the late move didn't count")
        XCTAssertEqual(recorded.actions, [])
    }

    /// A pointer that never stops still ends the swipe, `latchedSwipeMaximum` after it began.
    func testOnTheCobraTheSwipeEndsAtItsLongest() {
        let recorded = Recorded()
        let clock = Clock()
        let r = cobraRemapper(recorded, clock: clock)
        pulse(r)
        move(r, clock, dx: 20)
        let began = clock.now
        while clock.now < began + ButtonRemapper.latchedSwipeMaximum + 0.1 {
            move(r, clock, dx: 2)
        }
        XCTAssertEqual(recorded.phases.filter { $0 == .ended }.count, 1)
        XCTAssertNil(r.gestureHold)
        let changes = recorded.phases.filter { $0 == .changed }.count
        XCTAssertEqual(Double(changes) * 0.01, ButtonRemapper.latchedSwipeMaximum, accuracy: 0.02)
    }

    /// The window still only waits for the movement to start: with none, its end fires the
    /// click and nothing goes to the Dock.
    func testOnTheCobraNoMovementIsStillTheClick() {
        let recorded = Recorded()
        let clock = Clock()
        let r = cobraRemapper(recorded, clock: clock)
        let start = clock.now
        pulse(r)
        move(r, clock, dx: 8, dy: -6)
        XCTAssertTrue(r.expireLatchedGesture(now: start + ButtonRemapper.latchedGestureWindow))
        XCTAssertEqual(recorded.actions, [playPause])
        XCTAssertEqual(recorded.frames, [])
    }

    /// A discrete slot on the Cobra fires once and ends the hold, as before.
    func testOnTheCobraAnotherActionStillFiresOnce() {
        let recorded = Recorded()
        let clock = Clock()
        var mixed = bindings
        mixed.right = copy
        let r = cobraRemapper(recorded, bindings: mixed, clock: clock)
        pulse(r)
        move(r, clock, dx: 30)
        move(r, clock, dx: 30)
        XCTAssertEqual(recorded.actions, [copy])
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(recorded.frames, [])
    }

    /// Whatever ends a latched hold early cancels its swipe too, with its timer, and a second
    /// click starts over from a cancelled swipe.
    func testOnTheCobraEarlyEndingsCancelTheSwipe() {
        let endings: [(String, (ButtonRemapper) -> Void)] = [
            ("paused", { $0.remappingPaused = true }),
            ("unconfirmed", { $0.confirmDpiBridge(binding: .dpiCycle) }),
            ("action changed", { $0.saveDpiSoftwareAction(.doubleClick) }),
            ("mouse button", { r in
                let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                    mouseButton: .center)!
                _ = r.handle(type: .otherMouseDown, event: event)
            }),
            ("tap disabled", { _ = $0.handle(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!) }),
            ("device change", { $0.setActiveDevice("OTHER-BT", deviceID: 0x00DC) }),
            ("wake", { $0.cancelGesture() }),
            ("second click", { [self] r in pulse(r) }),
        ]
        for (name, end) in endings {
            let recorded = Recorded()
            let clock = Clock()
            let r = cobraRemapper(recorded, clock: clock, name: "\(#function)-\(name)")
            pulse(r)
            move(r, clock, dy: 30)
            let timer = r.latchTimer
            XCTAssertEqual(timer?.isValid, true, name)
            end(r)
            XCTAssertEqual(recorded.phases, [.began, .cancelled], name)
            XCTAssertEqual(recorded.frames.last?.progress ?? 0, 0.06, accuracy: 1e-9, name)
            XCTAssertEqual(recorded.frames.last?.velocity, 0, name)
            XCTAssertEqual(timer?.isValid, false, "\(name): the swipe's timer is stopped")
            XCTAssertEqual(recorded.actions, [], "\(name): no click")
            if name == "second click" {
                XCTAssertNotNil(r.gestureHold?.latchDeadline, "a new window, from the second click")
            } else {
                XCTAssertNil(r.gestureHold, name)
                move(r, clock, dy: 30)
                XCTAssertFalse(r.expireLatchedGesture(now: clock.now + 10), name)
                XCTAssertEqual(recorded.frames.count, 2, "\(name): nothing more")
            }
        }
    }
}
