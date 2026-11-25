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

    /// The same on a Cobra over Bluetooth, whose DPI button is the gesture, in driver mode:
    /// its private keys are handed to `handlePrivateKey` (`longKey`).
    private func cobraRemapper(_ recorded: Recorded, bindings: GestureBindings? = nil, clock: Clock,
                               name: String = #function) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults(name), actionEmitter: { recorded.actions.append($0) },
                               dockSwipes: output(recorded), clock: { clock.now })
        r.setActiveDevice("COBRA-BT", deviceID: cobra)
        r.saveDpiSoftwareAction(.gesture(bindings ?? self.bindings))
        r.dpiDriverModeChanged(.engaged)
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

    /// The Cobra's long private key going down (the firmware recognised a long press of the
    /// DPI button) or up (the button came up).
    private func longKey(_ r: ButtonRemapper, down: Bool) {
        r.handlePrivateKey(PrivateKeyEvent(code: DpiButtonPrivateKeys.cobraHyperSpeed.long, isDown: down))
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
        for longPress in [false, true] {
            let text = RemapView.gestureEditorExplanation(longPress: longPress, followsPointer: true)
            XCTAssertTrue(text.contains("Mission Control, App Exposé, Space Left and Space Right follow the pointer while you hold it."))
            XCTAssertFalse(text.contains("\u{2014}"), "no em dash")
            XCTAssertFalse(RemapView.gestureEditorExplanation(longPress: longPress, followsPointer: false)
                .contains("follow the pointer"), "not where they stay shortcuts")
        }
    }

    // MARK: The Cobra's DPI button: a long press, then the swipe

    /// Held until the long key comes, then moved up: the same swipe as a mouse button's, its
    /// moves arriving as plain pointer moves that go through, and the long key's release ends
    /// it with the hand's velocity. No shortcut is typed and no click follows.
    func testOnTheCobraALongPressDragsTheSwipeAndItsReleaseEndsIt() throws {
        let recorded = Recorded()
        let clock = Clock()
        let r = cobraRemapper(recorded, clock: clock)
        longKey(r, down: true)
        XCTAssertEqual(r.gestureHold?.trigger, ButtonRemapper.dpiButton)
        XCTAssertTrue(move(r, clock, dy: -10), "moves go through")
        XCTAssertEqual(recorded.frames, [], "inside the dead zone")
        move(r, clock, dy: -10)
        XCTAssertEqual(recorded.phases, [.began])
        XCTAssertEqual(recorded.frames.first?.kind, .vertical)
        for _ in 0..<10 { move(r, clock, dy: -10) }
        XCTAssertEqual(recorded.phases.filter { $0 == .changed }.count, 10)

        longKey(r, down: false)
        let end = try XCTUnwrap(recorded.frames.last)
        XCTAssertEqual(end.phase, .ended)
        XCTAssertEqual(end.progress, -0.24, accuracy: 1e-9, "12 moves of 10 points up")
        XCTAssertLessThan(end.velocity, 0, "still moving up")
        XCTAssertEqual(recorded.actions, [], "no Mission Control shortcut and no click")
        XCTAssertNil(r.gestureHold)
        XCTAssertTrue(move(r, clock, dy: -10))
        XCTAssertEqual(recorded.phases.filter { $0 == .ended }.count, 1, "nothing after the release")
    }

    /// The gesture starts when the long press is recognised: movement before the long key
    /// comes is not part of it.
    func testOnTheCobraMovementBeforeTheLongKeyDoesNotCount() {
        let recorded = Recorded()
        let clock = Clock()
        let r = cobraRemapper(recorded, clock: clock)
        for _ in 0..<5 { move(r, clock, dx: 10) }
        longKey(r, down: true)
        XCTAssertEqual(recorded.frames, [], "50 points before the hold began")
        move(r, clock, dx: 10)
        XCTAssertEqual(recorded.frames, [], "10 since: inside the dead zone")
        move(r, clock, dx: 10)
        XCTAssertEqual(recorded.phases, [.began])
    }

    /// Since the long key comes only after a second, a long hold is never the click: released
    /// without a swipe, it fires Hold, None here, so nothing, and sends nothing to the Dock.
    func testOnTheCobraALongHoldWithoutASwipeFiresNothing() {
        let recorded = Recorded()
        let clock = Clock()
        let r = cobraRemapper(recorded, clock: clock)
        longKey(r, down: true)
        move(r, clock, dx: 8, dy: -6)
        clock.now += 3
        longKey(r, down: false)
        XCTAssertEqual(recorded.actions, [], "Click is the short press's")
        XCTAssertEqual(recorded.frames, [])
        XCTAssertNil(r.gestureHold)
    }

    /// Hold fires for a long press released inside the dead zone, once, with nothing sent to
    /// the Dock. Once a dock swipe began, a swipe happened: its release fires no Hold, even
    /// when it was taken back to the start and snapped back.
    func testOnTheCobraHoldFiresOnlyWhenNoSwipeBegan() {
        let recorded = Recorded()
        let clock = Clock()
        let mute = RemapAction.mediaKey(code: 7, name: "Mute")
        var holding = bindings
        holding.hold = mute
        let r = cobraRemapper(recorded, bindings: holding, clock: clock)
        longKey(r, down: true)
        move(r, clock, dx: 8, dy: -6)
        clock.now += 3
        longKey(r, down: false)
        XCTAssertEqual(recorded.actions, [mute], "Hold")
        XCTAssertEqual(recorded.frames, [], "nothing for the Dock")

        longKey(r, down: true)
        move(r, clock, dx: 40)
        move(r, clock, dx: -40)
        longKey(r, down: false)
        XCTAssertEqual(recorded.phases, [.began, .changed, .cancelled])
        XCTAssertEqual(recorded.actions, [mute], "no Hold after a swipe taken back")

        longKey(r, down: true)
        move(r, clock, dy: -30)
        longKey(r, down: false)
        XCTAssertEqual(recorded.phases.last, .ended)
        XCTAssertEqual(recorded.actions, [mute], "no Hold after a swipe")
    }

    /// A slot that isn't a system swipe fires once during the movement, and the hold goes on
    /// until the release, which fires nothing more.
    func testOnTheCobraAnotherActionStillFiresOnce() {
        let recorded = Recorded()
        let clock = Clock()
        var mixed = bindings
        mixed.right = copy
        let r = cobraRemapper(recorded, bindings: mixed, clock: clock)
        longKey(r, down: true)
        move(r, clock, dx: 30)
        move(r, clock, dx: 30)
        XCTAssertEqual(recorded.actions, [copy])
        XCTAssertNotNil(r.gestureHold, "the release ends the hold, not the swipe")
        move(r, clock, dx: 200)
        longKey(r, down: false)
        XCTAssertEqual(recorded.actions, [copy])
        XCTAssertEqual(recorded.frames, [])
    }

    /// Whatever ends a hold early cancels its swipe, the driver mode going away among them,
    /// and the long key's release after it sends nothing more and fires nothing.
    func testOnTheCobraEarlyEndingsCancelTheSwipe() {
        let endings: [(String, (ButtonRemapper) -> Void)] = [
            ("paused", { $0.remappingPaused = true }),
            ("driver mode lost", { $0.dpiDriverModeChanged(.off) }),
            ("driver mode failed", { $0.dpiDriverModeChanged(.unavailable("The mouse didn't confirm.")) }),
            ("action changed", { $0.saveDpiSoftwareAction(.doubleClick) }),
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
            let recorded = Recorded()
            let clock = Clock()
            let r = cobraRemapper(recorded, clock: clock, name: "\(#function)-\(name)")
            longKey(r, down: true)
            move(r, clock, dy: 30)
            end(r)
            XCTAssertNil(r.gestureHold, name)
            XCTAssertEqual(recorded.phases, [.began, .cancelled], name)
            XCTAssertEqual(recorded.frames.last?.progress ?? 0, 0.06, accuracy: 1e-9, name)
            XCTAssertEqual(recorded.frames.last?.velocity, 0, name)
            longKey(r, down: false)
            move(r, clock, dy: 30)
            XCTAssertEqual(recorded.frames.count, 2, "\(name): nothing more")
            XCTAssertEqual(recorded.actions, [], "\(name): no click")
        }
    }
}
