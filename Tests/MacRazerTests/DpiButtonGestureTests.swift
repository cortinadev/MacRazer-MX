// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import CoreGraphics
import XCTest
@testable import MacRazer

/// The DPI button as a gesture button, on a Cobra HyperSpeed over Bluetooth. The mouse types
/// F20 for it; a hold is the F20 key down and up, and its movement comes as `.mouseMoved`,
/// as no mouse button is down. Synthetic events into `handle`, with the actions caught by
/// `actionEmitter` instead of posted, so nothing here needs Accessibility or reaches the
/// session. The bridge is set up as `DpiCycleSoftwareBridgeTests` does: a saved software
/// action and a read of the mouse confirming F20.
final class DpiButtonGestureTests: XCTestCase {
    private let bindings = GestureBindings(
        click: .mediaKey(code: 16, name: "Play / Pause"),
        up: .keystroke(keyCode: 126, modifiers: 0, name: "Up"),
        down: .keystroke(keyCode: 125, modifiers: 0, name: "Down"),
        left: .keystroke(keyCode: 123, modifiers: 0, name: "Left"),
        right: .keystroke(keyCode: 124, modifiers: 0, name: "Right"))

    private final class Emitted {
        var actions: [RemapAction] = []
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

    /// A remapper on the Cobra over Bluetooth whose DPI button does `action`, with the F20
    /// assignment confirmed, and whose actions land in `emitted`.
    private func remapper(_ emitted: Emitted, action: RemapAction? = nil, name: String = #function) -> ButtonRemapper {
        let r = ButtonRemapper(defaults: defaults(name), actionEmitter: { emitted.actions.append($0) })
        r.setActiveDevice("COBRA-BT", deviceID: 0x00DC)
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

    // MARK: The hold

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

    /// Pointer moves are the hot path: with no hold of the DPI button they go straight
    /// through, and one of a mouse button's hold doesn't feed it. A DPI hold's moves go
    /// through too: no app saw a button go down, so to them it's a plain move.
    func testPointerMovesAlwaysPassThrough() {
        let emitted = Emitted()
        let r = remapper(emitted)
        XCTAssertTrue(move(r, dy: 100), "no hold")
        r.beginGesture(bindings, trigger: 3)
        XCTAssertTrue(move(r, dy: 100), "a mouse button's hold")
        XCTAssertEqual(r.gestureHold?.recognizer, GestureRecognizer(), "which moves don't feed")
        r.cancelGesture()
        f20(r, down: true)
        XCTAssertTrue(move(r, dy: 100), "the DPI button's own hold")
        XCTAssertEqual(emitted.actions, [bindings.down])
    }

    /// Any other action still fires on the press, once, as before gestures.
    func testAnActionThatIsNotAGestureFiresOnThePress() {
        let emitted = Emitted()
        let media = RemapAction.mediaKey(code: 7, name: "Mute")
        let r = remapper(emitted, action: media)
        XCTAssertFalse(f20(r, down: true))
        XCTAssertEqual(emitted.actions, [media], "on the press, not the release")
        XCTAssertFalse(f20(r, down: true, repeating: true))
        XCTAssertNil(r.gestureHold, "no hold")
        XCTAssertTrue(move(r, dy: -100))
        XCTAssertFalse(f20(r, down: false))
        XCTAssertEqual(emitted.actions, [media])
    }

    // MARK: Ending a hold

    /// Whatever ends a hold early, the release of the press that was swallowed is swallowed
    /// too, and it fires no click: pausing, the F20 assignment no longer confirmed, the action
    /// changing, a mouse button going down, and the tap being switched off for a moment.
    func testAHoldEndedEarlyStillSwallowsItsRelease() {
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
        ]
        for (name, end) in endings {
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
        r.setActiveDevice("COBRA-BT-2", deviceID: 0x00DC)
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
