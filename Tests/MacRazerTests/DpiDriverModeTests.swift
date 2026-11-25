// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The DPI button's driver mode on a mouse with private keys: when it is read and written
/// (`DpiDriverModeBook`), how one change goes (`BluetoothDevice.setDeviceMode`, driven with a
/// mouse made of closures), and what the page says when it fails. Nothing here talks to a
/// mouse: the mode is volatile and writing it changes how the real button behaves, so every
/// rule about when it is written is checked here instead.
final class DpiDriverModeTests: XCTestCase {
    private typealias Book = DpiDriverModeBook
    private let interval = DpiDriverModeBook.recheckInterval

    // MARK: When

    /// Not wanted and never set: nothing goes to the mouse, whatever happens.
    func testNothingIsSentWhileItIsNotWanted() {
        var book = Book()
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 0), .nothing)
        XCTAssertEqual(book.step(for: .wantChanged, now: 0), .nothing)
        book.connectionChanged()
        book.doubtful()
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100), .nothing)
        XCTAssertEqual(book.state(lastError: nil), .off)
    }

    /// Wanted: engaged at once, from the change itself or the first read of the mouse after
    /// it, and then only checked again every `recheckInterval`, quietly.
    func testItIsEngagedAtOnceThenCheckedEveryInterval() {
        var book = Book()
        book.setWanted(true)
        XCTAssertEqual(book.step(for: .wantChanged, now: 10), .engage)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 10), .engage, "or at the first read")
        XCTAssertEqual(book.state(lastError: nil), .off, "not set up yet")
        book.engaged(at: 10)
        XCTAssertEqual(book.state(lastError: nil), .engaged)
        XCTAssertTrue(book.maybeSet)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 10 + interval - 1), .nothing, "every poll would be too often")
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 10 + interval), .recheck)
        book.engaged(at: 10 + interval)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 11 + interval), .nothing)
    }

    /// A new connection, or a wake, may have lost the mode: it is engaged again at once
    /// (`BluetoothDevice.setDeviceMode` reads first, so a mouse still in it isn't written).
    func testANewConnectionOrAWakeEngagesItAgain() {
        let changes: [(String, (inout Book) -> Void)] = [("connection", { $0.connectionChanged() }),
                                                         ("wake", { $0.doubtful() })]
        for (name, change) in changes {
            var book = Book()
            book.setWanted(true)
            book.engaged(at: 0)
            change(&book)
            XCTAssertEqual(book.step(for: .mouseAnswered, now: 1), .engage, name)
            XCTAssertEqual(book.state(lastError: nil), .off, name)
            XCTAssertTrue(book.maybeSet, "\(name): quitting still writes normal mode back")
        }
    }

    /// A failed change isn't retried at once: the poll tries again an interval later, at most
    /// `maxAttempts` times on one connection, then not until the next connection, wake or
    /// change of mind. The page says why meanwhile.
    func testAFailureIsRetriedSlowlyAndThenLeftAlone() {
        var book = Book()
        book.setWanted(true)
        var now: TimeInterval = 0
        for attempt in 1...Book.maxAttempts {
            XCTAssertEqual(book.step(for: .mouseAnswered, now: now), .engage, "attempt \(attempt)")
            book.failed(at: now)
            XCTAssertEqual(book.state(lastError: "No."), .unavailable("No."))
            XCTAssertEqual(book.step(for: .mouseAnswered, now: now + 1), .nothing, "not in a tight loop")
            XCTAssertEqual(book.step(for: .wantChanged, now: now + 1), .nothing)
            now += interval
        }
        XCTAssertEqual(book.step(for: .mouseAnswered, now: now + 1000), .nothing, "given up on this connection")

        var woke = book
        woke.doubtful()
        XCTAssertEqual(woke.step(for: .mouseAnswered, now: now), .engage, "a wake is a fresh chance")
        var reconnected = book
        reconnected.connectionChanged()
        XCTAssertEqual(reconnected.step(for: .mouseAnswered, now: now), .engage, "so is a new connection")
        var rechosen = book
        rechosen.setWanted(true)
        XCTAssertEqual(rechosen.step(for: .wantChanged, now: now), .engage, "and choosing the action again")
    }

    /// No longer wanted: normal mode is written back, but only where this run may have left
    /// driver mode, and once it reads back nothing more is sent.
    func testNormalModeIsRestoredOnlyWhereItMayHaveBeenSet() {
        var book = Book()
        book.setWanted(true)
        book.setWanted(false)
        XCTAssertEqual(book.step(for: .wantChanged, now: 0), .nothing, "never set: nothing to undo")

        book.setWanted(true)
        book.engaged(at: 0)
        book.setWanted(false)
        XCTAssertEqual(book.state(lastError: nil), .off)
        XCTAssertEqual(book.step(for: .wantChanged, now: 1), .restore)
        book.restored()
        XCTAssertFalse(book.maybeSet)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100), .nothing)
    }

    /// A write that went out unanswered may still have landed, so it counts as set: an engage
    /// that failed after its write is undone like one that worked.
    func testAWriteThatMayHaveLandedIsUndoneToo() {
        var book = Book()
        book.setWanted(true)
        book.mayHaveSet()
        book.failed(at: 0)
        book.setWanted(false)
        XCTAssertEqual(book.step(for: .wantChanged, now: 1), .restore)
    }

    /// A restore that fails is tried again by the poll, slowly, as an engage is.
    func testAFailedRestoreIsRetriedSlowly() {
        var book = Book()
        book.setWanted(true)
        book.engaged(at: 0)
        book.setWanted(false)
        book.failed(at: 5)
        XCTAssertTrue(book.maybeSet)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 6), .nothing)
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 5 + interval), .restore)
    }

    /// Losing the connection forgets what was verified and what failed, but not what is
    /// wanted, nor that the mode may have been set.
    func testLosingTheConnectionKeepsWhatIsWanted() {
        var book = Book()
        book.setWanted(true)
        book.engaged(at: 0)
        book.connectionChanged()
        XCTAssertTrue(book.wanted)
        XCTAssertTrue(book.maybeSet)
        XCTAssertNil(book.verifiedAt)
        XCTAssertEqual(book.failures, 0)
    }

    // MARK: How

    /// A mouse made of closures: the mode it reads, what it does with a write, and every
    /// read and write it got.
    private final class Mouse {
        var mode: UInt16 = 0
        var readFails = false
        var readBackFails = false
        var refusesWrites = false
        var ignoresWrites = false
        private(set) var reads = 0
        private(set) var writes: [BLEProtocol.DeviceMode] = []

        func read() throws -> UInt16 {
            reads += 1
            if readFails || (readBackFails && !writes.isEmpty) { throw HIDDevice.HIDError.timeout }
            return mode
        }

        func write(_ mode: BLEProtocol.DeviceMode) throws {
            writes.append(mode)
            if refusesWrites { throw HIDDevice.HIDError.commandFailed }
            if !ignoresWrites { self.mode = mode.value }
        }

        func set(_ mode: BLEProtocol.DeviceMode, readFirst: Bool = true) throws -> BluetoothDevice.DeviceModeChange {
            try BluetoothDevice.setDeviceMode(mode, readFirst: readFirst, read: read, write: write)
        }
    }

    /// A mouse already in driver mode is read and left alone; one in normal mode gets one
    /// write and a read back.
    func testDriverModeIsReadFirstAndWrittenOnlyWhenItIsntThere() throws {
        let already = Mouse()
        already.mode = 3
        XCTAssertEqual(try already.set(.driver), .alreadySet)
        XCTAssertEqual(already.writes, [])
        XCTAssertEqual(already.reads, 1)

        let normal = Mouse()
        XCTAssertEqual(try normal.set(.driver), .written)
        XCTAssertEqual(normal.writes, [.driver])
        XCTAssertEqual(normal.reads, 2, "the read before and the read back")
    }

    /// A read that fails before the write means nothing is written.
    func testNothingIsWrittenWhenTheFirstReadFails() {
        let mouse = Mouse()
        mouse.readFails = true
        XCTAssertThrowsError(try mouse.set(.driver)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .unreadable)
        }
        XCTAssertEqual(mouse.writes, [])
    }

    /// A refused write, or a read back that differs or fails, throws, and no second write
    /// follows.
    func testAWriteThatDoesntReadBackThrowsAndIsntRepeated() {
        let refusing = Mouse()
        refusing.refusesWrites = true
        XCTAssertThrowsError(try refusing.set(.driver)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .notTaken)
        }
        XCTAssertEqual(refusing.writes, [.driver])

        let ignoring = Mouse()
        ignoring.ignoresWrites = true
        XCTAssertThrowsError(try ignoring.set(.driver)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .notReadBack(0))
        }
        XCTAssertEqual(ignoring.writes, [.driver])

        let silent = Mouse()
        silent.readBackFails = true
        XCTAssertThrowsError(try silent.set(.driver)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .notReadBack(nil))
        }
        XCTAssertEqual(silent.writes, [.driver])
    }

    /// Normal mode goes back with a write first and a read back: writing it again is harmless,
    /// and quitting has little time.
    func testNormalModeIsWrittenThenReadBack() throws {
        let mouse = Mouse()
        mouse.mode = 3
        XCTAssertEqual(try mouse.set(.normal, readFirst: false), .written)
        XCTAssertEqual(mouse.writes, [.normal])
        XCTAssertEqual(mouse.reads, 1)
        XCTAssertEqual(mouse.mode, 0)
    }

    // MARK: What the page says

    /// Each failure is a plain sentence that says what the button does meanwhile, never an
    /// error's debug text.
    func testTheErrorsArePlainSentences() {
        let errors: [Error] = [
            BLEProtocol.DeviceModeError.unreadable, BLEProtocol.DeviceModeError.notTaken,
            BLEProtocol.DeviceModeError.notReadBack(0), BLEProtocol.DeviceModeError.notReadBack(nil),
            HIDDevice.HIDError.timeout, HIDDevice.HIDError.notFound,
        ]
        for error in errors {
            let text = MouseController.dpiDriverModeErrorText(error)
            XCTAssertTrue(text.hasSuffix("."), text)
            XCTAssertTrue(text.contains("DPI"), text)
            XCTAssertFalse(text.contains("\u{2014}"), text)
            XCTAssertFalse(text.contains("Error") || text.contains("0x") || text.contains("HID"), text)
        }
    }
}
