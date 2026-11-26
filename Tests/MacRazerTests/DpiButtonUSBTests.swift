// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import IOKit.hid
import XCTest
@testable import MacRazer

/// The DPI button of the Cobra HyperSpeed on its cable (0x00DA): the device mode over the USB
/// feature report, the software DPI cycle there, which of the mouse's HID interfaces its keys
/// come from, what the trace may log of that interface, and how the Buttons page offers the
/// button. Bytes marked as captured are what a real Cobra by cable answered (firmware v1.0,
/// transaction id 0x1f, control interface). Nothing here opens a HID device.
final class DpiButtonUSBTests: XCTestCase {
    private let cable = 0x00DA
    private let dongle = 0x00DB
    private let bluetooth = 0x00DC
    private let huntsman = 0x026B
    private let keys = DpiButtonPrivateKeys.cobraHyperSpeed

    /// The DeviceUsagePairs of the cable's four interfaces, as macOS lists them.
    private let pointerPairs: [[String: Int]] = [[kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2],
                                                 [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 1]]
    private let bootKeyboardPairs: [[String: Int]] = [[kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6]]
    private let privateKeyPairs: [[String: Int]] = [[kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6],
                                                    [kIOHIDDeviceUsagePageKey: 12, kIOHIDDeviceUsageKey: 1],
                                                    [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 0x80],
                                                    [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 0]]
    private let lampPairs: [[String: Int]] = [[kIOHIDDeviceUsagePageKey: 0x59, kIOHIDDeviceUsageKey: 1]]

    /// A 90-byte answer with `header` at the front, its CRC set, as `HIDDevice.send` hands it on.
    private func reply(_ header: [UInt8]) throws -> RazerReport {
        var bytes = [UInt8](repeating: 0, count: RazerReport.wireSize)
        bytes.replaceSubrange(0..<header.count, with: header)
        bytes[88] = RazerReport.crc(of: bytes)
        return try XCTUnwrap(RazerReport.parse(bytes))
    }

    // MARK: The device mode over USB

    /// The read and the two writes, byte for byte as sent to the mouse (the transaction id is
    /// stamped later, by `HIDDevice.send`). Only `DeviceMode` values can be built into a write.
    func testTheDeviceModeCommandsAreTheOnesTheCableTook() {
        let read = RazerCommands.getDeviceMode().serialized()
        XCTAssertEqual(Array(read[4..<10]), [0x00, 0x02, 0x00, 0x84, 0x00, 0x00])
        let driver = RazerCommands.setDeviceMode(.driver).serialized()
        XCTAssertEqual(Array(driver[4..<10]), [0x00, 0x02, 0x00, 0x04, 0x03, 0x00])
        let normal = RazerCommands.setDeviceMode(.normal).serialized()
        XCTAssertEqual(Array(normal[4..<10]), [0x00, 0x02, 0x00, 0x04, 0x00, 0x00])
        XCTAssertEqual(driver[88], RazerReport.crc(of: driver))
        XCTAssertEqual(RazerDevices.transactionId(pid: cable, commandClass: 0x00, commandId: 0x04), 0x1f,
                       "the id the cable answered on")
    }

    /// The answers as captured: normal mode, driver mode, the write's echo. The same u16 as over
    /// Bluetooth. A refusal, or an answer to another command, is no mode.
    func testTheCapturedAnswersReadAsTheMode() throws {
        XCTAssertEqual(RazerCommands.parseDeviceMode(try reply([0x02, 0x1f, 0, 0, 0, 0x02, 0x00, 0x84, 0x00, 0x00])), 0)
        XCTAssertEqual(RazerCommands.parseDeviceMode(try reply([0x02, 0x1f, 0, 0, 0, 0x02, 0x00, 0x84, 0x03, 0x00])),
                       BLEProtocol.DeviceMode.driver.value)
        XCTAssertEqual(RazerCommands.parseDeviceMode(try reply([0x02, 0x1f, 0, 0, 0, 0x02, 0x00, 0x04, 0x03, 0x00])), 3,
                       "the write's echo")
        XCTAssertEqual(RazerCommands.parseDeviceMode(try reply([0x02, 0x1f, 0, 0, 0, 0x02, 0x00, 0x84, 0x03, 0x00])),
                       BLEProtocol.parseDeviceMode([0x03, 0x00]), "the same value as over Bluetooth")
        XCTAssertNil(RazerCommands.parseDeviceMode(try reply([0x03, 0x1f, 0, 0, 0, 0x02, 0x00, 0x84, 0x03, 0x00])),
                     "a failure")
        XCTAssertNil(RazerCommands.parseDeviceMode(try reply([0x05, 0x1f, 0, 0, 0, 0x02, 0x00, 0x84, 0x00, 0x00])),
                     "not supported")
        XCTAssertNil(RazerCommands.parseDeviceMode(try reply([0x02, 0x1f, 0, 0, 0, 0x02, 0x00, 0x81, 0x01, 0x00])),
                     "the firmware version")
    }

    /// The cable as `FakeMouse`: what is written to 00/04 is what 00/84 answers.
    private func cableMouse(mode: BLEProtocol.DeviceMode = .normal) -> FakeMouse {
        let mouse = FakeMouse()
        mouse.holds(RazerCommands.setDeviceMode(mode))
        return mouse
    }

    private func set(_ mode: BLEProtocol.DeviceMode, on mouse: FakeMouse, readFirst: Bool = true) throws -> DeviceModeChange {
        try DeviceModeChange.apply(mode, readFirst: readFirst,
                                   read: { try HIDDevice.readDeviceMode(send: mouse.send) },
                                   write: { try HIDDevice.writeDeviceMode($0, send: mouse.send) })
    }

    /// Driver mode over the cable as over Bluetooth: read first, one write, read back, each a
    /// single exchange (never the retry ladder). Then normal mode back, write first.
    func testDriverModeGoesOverTheCableReadFirstWrittenOnceAndReadBack() throws {
        let mouse = cableMouse()
        XCTAssertEqual(try set(.driver, on: mouse), .written)
        XCTAssertEqual(mouse.calls, [.once(0x00, 0x84), .once(0x00, 0x04), .once(0x00, 0x84)])
        XCTAssertEqual(mouse.sent[1].arguments.prefix(2), [0x03, 0x00])
        XCTAssertEqual(try HIDDevice.readDeviceMode(send: mouse.send), 3)

        let already = cableMouse(mode: .driver)
        XCTAssertEqual(try set(.driver, on: already), .alreadySet)
        XCTAssertEqual(already.calls, [.once(0x00, 0x84)], "a mouse still in it isn't written")

        XCTAssertEqual(try set(.normal, on: mouse, readFirst: false), .written)
        XCTAssertEqual(mouse.sent.suffix(2).map(\.commandId), [0x04, 0x84])
        XCTAssertEqual(mouse.sent[mouse.sent.count - 2].arguments.prefix(2), [0x00, 0x00])
        XCTAssertEqual(try HIDDevice.readDeviceMode(send: mouse.send), 0)
    }

    /// A refused write, a write the mouse doesn't keep, and a read that fails before anything is
    /// written all throw as over Bluetooth, and no second write follows.
    func testACableThatDoesntTakeTheModeThrowsAndIsntWrittenAgain() {
        let refusing = cableMouse()
        refusing.refuse = { $0.commandId == 0x04 }
        XCTAssertThrowsError(try set(.driver, on: refusing)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .notTaken)
        }
        XCTAssertEqual(refusing.sent.filter { $0.commandId == 0x04 }.count, 1)

        let ignoring = cableMouse()
        ignoring.clamp = { _ in RazerCommands.setDeviceMode(.normal) }
        XCTAssertThrowsError(try set(.driver, on: ignoring)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .notReadBack(0))
        }
        XCTAssertEqual(ignoring.sent.filter { $0.commandId == 0x04 }.count, 1)

        let silent = cableMouse()
        silent.refuse = { $0.commandId == 0x84 }
        XCTAssertThrowsError(try set(.driver, on: silent)) { error in
            XCTAssertEqual(error as? BLEProtocol.DeviceModeError, .unreadable)
        }
        XCTAssertEqual(silent.sent.filter { $0.commandId == 0x04 }.count, 0, "nothing written")
    }

    /// An answer that isn't a success is no mode and no write, even where `HIDDevice.send`
    /// passes an unknown status through.
    func testOnlyASuccessCountsOverTheCable() {
        var status: UInt8 = 0x00
        let send: (RazerReport) throws -> RazerReport = { request in
            var answer = request
            answer.status = status
            return answer
        }
        XCTAssertThrowsError(try HIDDevice.readDeviceMode(send: send))
        XCTAssertThrowsError(try HIDDevice.writeDeviceMode(.driver, send: send))
        status = RazerStatus.successful.rawValue
        XCTAssertEqual(try HIDDevice.readDeviceMode(send: send), 0)
        XCTAssertNoThrow(try HIDDevice.writeDeviceMode(.driver, send: send))
    }

    /// The book that runs driver mode is the same for the cable: wanted, engaged over the
    /// feature report, settled, checked, restored, and a reopen of the interface is a new
    /// connection whose leftover read finds the mode an earlier run left.
    func testTheCableRunsTheSameBook() throws {
        let mouse = cableMouse()
        var book = DpiDriverModeBook()
        // `MouseController` opening the cable's control interface: a new connection.
        book.connectionChanged()
        book.setWanted(true)
        XCTAssertEqual(book.step(for: .wantChanged, now: 0), .engage)
        let change = try set(.driver, on: mouse)
        XCTAssertTrue(book.engaged(at: 0, wrote: change == .written), "a new connection settles")
        XCTAssertEqual(book.state(lastError: nil), .engaged)
        XCTAssertEqual(book.step(for: .earlyCheck, now: DpiDriverModeBook.firstSettlingCheckDelay), .recheck)
        XCTAssertEqual(try set(.driver, on: mouse), .alreadySet)

        book.setWanted(false)
        XCTAssertEqual(book.step(for: .wantChanged, now: 5), .restore)
        _ = try set(.normal, on: mouse, readFirst: false)
        book.restored()
        XCTAssertEqual(book.step(for: .mouseAnswered, now: 100), .nothing)

        // A run that crashed left the cable in driver mode; the next one finds it once.
        let left = cableMouse(mode: .driver)
        var next = DpiDriverModeBook()
        next.connectionChanged()
        next.answered(at: 0)
        XCTAssertEqual(next.step(for: .mouseAnswered, now: DpiDriverModeBook.leftoverCheckDelay), .checkLeftover)
        XCTAssertTrue(next.leftoverRead(try HIDDevice.readDeviceMode(send: left.send)))
    }

    /// `setDeviceMode` on any link says a write is going out just before it does, and not when
    /// the mouse is already in the mode.
    func testALinkSaysAWriteIsGoingOutOnlyWhenOneDoes() throws {
        final class Link: DeviceModeLink {
            let productID = 0x00DA
            var mode: UInt16 = 0
            func readDeviceMode() throws -> UInt16 { mode }
            func writeDeviceMode(_ mode: BLEProtocol.DeviceMode) throws { self.mode = mode.value }
        }
        let link = Link()
        var told = 0
        XCTAssertEqual(try link.setDeviceMode(.driver, readFirst: true, beforeWrite: { told += 1 }), .written)
        XCTAssertEqual(told, 1)
        XCTAssertEqual(try link.setDeviceMode(.driver, readFirst: true, beforeWrite: { told += 1 }), .alreadySet)
        XCTAssertEqual(told, 1)
    }

    // MARK: The software DPI cycle over USB

    /// A five-stage table as the cable answers it, stages numbered from 1, the second active.
    private func stages(_ values: [Int] = [400, 800, 1600, 3200, 6400], activeID: UInt8 = 2) -> RazerReport {
        var r = RazerCommands.setDPIStages(values, activeStage: 0)
        r.arguments[1] = activeID
        for i in values.indices { r.arguments[3 + i * 7] = UInt8(i + 1) }
        return r
    }

    /// The next stage, after the last the first; an active byte that names no stage steps to
    /// the first; one stage has nowhere to go.
    func testTheNextStageWrapsAndStartsOverFromAnUnknownActiveByte() throws {
        let table = try XCTUnwrap(RazerCommands.parseDPIStageTable(stages()))
        XCTAssertEqual(table.nextStage()?.activeID, 3)
        XCTAssertEqual(table.nextStage()?.values, table.values, "only the active stage moves")
        let last = try XCTUnwrap(RazerCommands.parseDPIStageTable(stages(activeID: 5)))
        XCTAssertEqual(last.nextStage()?.activeID, 1)
        let unknown = try XCTUnwrap(RazerCommands.parseDPIStageTable(stages(activeID: 9)))
        XCTAssertEqual(unknown.nextStage()?.activeID, 1)
        let one = try XCTUnwrap(RazerCommands.parseDPIStageTable(stages([800], activeID: 1)))
        XCTAssertNil(one.nextStage())
    }

    /// A short press in driver mode over USB: the DPI of the next stage first, then the table's
    /// active stage, then a read back. Pressed again from the last stage, it goes to the first.
    func testTheCycleSetsTheNextStagesDpiThenItsTableAndReadsItBack() throws {
        let mouse = FakeMouse()
        mouse.holds(stages())
        let back = try XCTUnwrap(MouseController.cycleUSBStage(send: { try mouse.sendWithRetry($0, attempts: 1) }))
        XCTAssertEqual(back.activeIndex, 2)
        XCTAssertEqual(mouse.sent.map(\.commandId), [0x86, 0x05, 0x06, 0x86])
        XCTAssertEqual(RazerCommands.parseDPI(mouse.sent[1]).x, 1600)
        XCTAssertEqual(RazerCommands.parseDPI(mouse.sent[1]).y, 1600)

        let fromLast = FakeMouse()
        fromLast.holds(stages(activeID: 5))
        XCTAssertEqual(try MouseController.cycleUSBStage(send: { try fromLast.sendWithRetry($0, attempts: 1) })?.activeID, 1)
        XCTAssertEqual(RazerCommands.parseDPI(fromLast.sent[1]).x, 400)
    }

    /// One stage: nothing is written. A table that doesn't read back as written throws.
    func testTheCycleWritesNothingWithOneStageAndChecksTheReadBack() throws {
        let single = FakeMouse()
        single.holds(stages([800], activeID: 1))
        XCTAssertNil(try MouseController.cycleUSBStage(send: { try single.sendWithRetry($0, attempts: 1) }))
        XCTAssertEqual(single.sent.map(\.commandId), [0x86])

        let stuck = FakeMouse()
        stuck.holds(stages())
        stuck.clamp = { report in
            guard report.commandId == 0x06 else { return report }
            var kept = report
            kept.arguments[1] = 2
            return kept
        }
        XCTAssertThrowsError(try MouseController.cycleUSBStage(send: { try stuck.sendWithRetry($0, attempts: 1) }))
    }

    // MARK: Which interface the keys come from

    /// On the cable the keys are watched on the one interface that declares reports 4 and 5,
    /// by Razer's USB vendor and the exact product; over Bluetooth on every device of the mouse.
    func testTheCablesKeysAreMatchedOnTheOneInterfaceThatCarriesThem() {
        XCTAssertEqual(PrivateKeyInterface.matching(productID: cable),
                       [kIOHIDVendorIDKey: 0x1532, kIOHIDProductIDKey: cable,
                        kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: 0])
        XCTAssertEqual(PrivateKeyInterface.matching(productID: bluetooth),
                       [kIOHIDVendorIDKey: 0x068E, kIOHIDProductIDKey: bluetooth])
    }

    /// Of the cable's four interfaces only that one is accepted; nothing of another product,
    /// the Razer keyboard plugged in beside it among them, whatever it declares; and a cable's
    /// product id under Bluetooth's vendor isn't the cable.
    func testOnlyThatInterfaceOfThatMouseIsEverOpened() {
        func accepts(_ vendor: Int, _ product: Int, _ pairs: [[String: Int]], watching: Int) -> Bool {
            PrivateKeyInterface.accepts(vendorID: vendor, productID: product, usagePairs: pairs, watching: watching)
        }
        XCTAssertTrue(accepts(0x1532, cable, privateKeyPairs, watching: cable))
        for pairs in [pointerPairs, bootKeyboardPairs, lampPairs] {
            XCTAssertFalse(accepts(0x1532, cable, pairs, watching: cable), "\(pairs)")
        }
        XCTAssertFalse(accepts(0x1532, huntsman, privateKeyPairs, watching: cable), "the keyboard")
        XCTAssertFalse(accepts(0x1532, huntsman, privateKeyPairs, watching: huntsman), "the keyboard, asked for itself")
        XCTAssertFalse(accepts(0x068E, cable, privateKeyPairs, watching: cable), "Bluetooth's vendor")
        XCTAssertTrue(accepts(0x068E, bluetooth, pointerPairs, watching: bluetooth), "every device over Bluetooth")
        XCTAssertFalse(accepts(0x1532, bluetooth, pointerPairs, watching: bluetooth))
    }

    /// Report 4 over the cable carries its id once, then a 15-byte array: the keys are read as
    /// over Bluetooth, and the interface's keyboard report is never taken for keys.
    func testTheCablesReport4IsReadAsOverBluetooth() {
        var down = [UInt8](repeating: 0, count: 16)
        down[0] = 0x04
        down[1] = keys.long
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: down), [keys.long])
        down[1] = keys.short
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: down), [keys.short])
        down[1] = 0
        XCTAssertEqual(PrivateKeyReport.heldKeys(reportID: 4, bytes: down), [])
        var typed = [UInt8](repeating: 0, count: 16)
        typed[0] = 0x01
        typed[2] = 0x04
        XCTAssertNil(PrivateKeyReport.heldKeys(reportID: 1, bytes: typed))
    }

    // MARK: What the trace logs of that interface

    /// The trace watches that interface on the cable only: never on the keyboard, the dongle,
    /// or any other interface of the cable.
    func testTheTraceWatchesTheCablesKeyInterfaceAndNothingElse() {
        XCTAssertEqual(GestureDebugHIDWatch.privateKeyUSBProducts, [cable])
        XCTAssertTrue(GestureDebugHIDWatch.watchesPrivateKeyInterface(vendorID: 0x1532, productID: cable,
                                                                       usagePairs: privateKeyPairs))
        for pairs in [pointerPairs, bootKeyboardPairs, lampPairs] {
            XCTAssertFalse(GestureDebugHIDWatch.watchesPrivateKeyInterface(vendorID: 0x1532, productID: cable,
                                                                            usagePairs: pairs), "\(pairs)")
        }
        for (vendor, product) in [(0x1532, huntsman), (0x1532, dongle), (0x068E, cable), (0x068E, bluetooth)] {
            XCTAssertFalse(GestureDebugHIDWatch.watchesPrivateKeyInterface(vendorID: vendor, productID: product,
                                                                            usagePairs: privateKeyPairs),
                           String(format: "%04x:%04x", vendor, product))
        }
        XCTAssertFalse(GestureDebugHIDWatch.watches(vendorID: 0x1532, productID: cable,
                                                     primaryUsagePage: kHIDPage_GenericDesktop,
                                                     primaryUsage: kHIDUsage_GD_Keyboard),
                       "the general watch still takes no keyboard interface")
    }

    /// Reports 4 and 5 are logged whole; report 1 only when it holds nothing but F13 to F20,
    /// and the consumer and system reports the same way.
    func testTheKeyInterfaceLogsOnlyKeysAndNotices() {
        func line(_ id: Int, _ bytes: [UInt8]) -> String? {
            GestureDebugReportFilter.privateKeyInterfaceLine(reportID: id, bytes: bytes)
        }
        let zeros = [UInt8](repeating: 0, count: 14)
        XCTAssertEqual(line(4, [0x04, 0x52] + zeros), "HIDREPORT id=4 len=16 04 52" + String(repeating: " 00", count: 14))
        XCTAssertEqual(line(5, [0x05, 0x02, 0x03, 0x20] + [UInt8](repeating: 0, count: 12))?.hasPrefix("HIDREPORT id=5 len=16 05 02"),
                       true)
        XCTAssertEqual(line(1, [0x01, 0x00, 0x6F] + [UInt8](repeating: 0, count: 13))?.hasPrefix("HIDREPORT id=1 len=16"),
                       true, "F20")
        XCTAssertEqual(line(1, [0x01, 0x00, 0x04] + [UInt8](repeating: 0, count: 13)), "HIDREPORT id=1 (not recorded)")
        XCTAssertEqual(line(1, [0x01, 0x02, 0x6F] + [UInt8](repeating: 0, count: 13)), "HIDREPORT id=1 (not recorded)",
                       "a modifier with it")
        XCTAssertEqual(line(2, [0x02, 0xE9, 0x00] + [UInt8](repeating: 0, count: 13)), "HIDREPORT id=2 (not recorded)",
                       "volume up")
        XCTAssertEqual(line(3, [0x03, 0x01] + zeros), "HIDREPORT id=3 (not recorded)", "system power")
    }

    /// No keyboard usage but F13 to F20 ever reaches the log from that interface's keyboard
    /// report, in any of its 14 key slots or as a modifier.
    func testNothingTypedEverReachesTheLogFromTheCable() {
        for usage in UInt8(1)...UInt8(0xFF) where !GestureDebugReportFilter.loggableKeys.contains(usage) {
            for position in 1..<16 {
                var report = [UInt8](repeating: 0, count: 16)
                report[0] = 0x01
                report[position] = usage
                XCTAssertEqual(GestureDebugReportFilter.privateKeyInterfaceLine(reportID: 1, bytes: report),
                               "HIDREPORT id=1 (not recorded)", "usage \(usage) at \(position)")
            }
        }
    }

    // MARK: How the Buttons page offers the button

    /// The cable's button is driver mode alone; over Bluetooth the entry wins; the dongle, an
    /// unknown mouse and the keyboard have no section.
    func testTheCableGetsTheDriverModeSection() {
        XCTAssertEqual(ButtonRemapper.dpiButtonSection(pid: cable, bluetooth: false), .driverModeOnly)
        XCTAssertEqual(ButtonRemapper.dpiButtonSection(pid: bluetooth, bluetooth: true), .onboardEntry)
        XCTAssertNil(ButtonRemapper.dpiButtonSection(pid: bluetooth, bluetooth: false), "not yet known to be Bluetooth")
        XCTAssertEqual(ButtonRemapper.dpiButtonSection(pid: 0x00BA, bluetooth: true), .onboardEntry, "the Basilisk")
        for pid: Int? in [dongle, 0x9999, huntsman, nil] {
            XCTAssertNil(ButtonRemapper.dpiButtonSection(pid: pid, bluetooth: false), "\(pid.map(String.init) ?? "none")")
        }
    }

    /// Without an entry to write, the firmware's DPI Cycle is all the mouse runs: None and DPI
    /// Cycle give the button back, and every other action is MacRazer's, a mouse button or a
    /// key the mouse could type over Bluetooth included.
    func testOnTheCableEveryActionButDpiCycleIsMacRazers() {
        let copy = ButtonRemapper.presets.first { $0.id == "copy" }!.action
        let actions: [RemapAction] = [copy, .mouseButton(button: 3, name: "Back Button"), .doubleClick,
                                      .mediaKey(code: 16, name: "Play / Pause"), .launchpad,
                                      .gesture(.defaults(for: ButtonRemapper.dpiButton))]
        for action in actions {
            let a = ButtonRemapper.dpiButtonAssignment(for: action, privateKeys: true, onboardEntry: false)
            XCTAssertEqual(a.binding, .dpiCycle, action.label)
            XCTAssertEqual(a.softwareAction, action, action.label)
        }
        for action in [RemapAction.passthrough, .dpiCycle] {
            let a = ButtonRemapper.dpiButtonAssignment(for: action, privateKeys: true, onboardEntry: false)
            XCTAssertEqual(a.binding, .dpiCycle)
            XCTAssertNil(a.softwareAction, "the firmware's own DPI Cycle")
        }
        XCTAssertEqual(ButtonRemapper.dpiButtonAssignment(for: copy, privateKeys: true).softwareAction, nil,
                       "over Bluetooth the mouse types it")
    }

    /// The help says every choice but DPI Cycle needs MacRazer on a cable, and how the gesture
    /// is made, as over Bluetooth.
    func testTheCablesHelpSaysEveryChoiceButDpiCycleNeedsMacRazer() {
        let text = RemapView.dpiButtonHelpText(privateKeys: true, onboardEntry: false)
        XCTAssertTrue(text.hasPrefix("On a cable the mouse keeps only its own DPI Cycle, so every other choice needs MacRazer"))
        XCTAssertTrue(text.contains("Accessibility and Input Monitoring"))
        XCTAssertTrue(text.contains(RemapView.gestureEditorExplanation(longPress: true, followsPointer: false)))
        XCTAssertFalse(text.contains("\u{2014}"), "no em dash")
        XCTAssertEqual(RemapView.dpiButtonHelpText(privateKeys: true),
                       RemapView.dpiButtonHelpText(privateKeys: true, onboardEntry: true), "Bluetooth's is as it was")
    }

    // MARK: The remapper on the cable

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "MacRazerTests.DpiButtonUSB.\(name)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A `PrivateKeySource` that opens nothing and records which product it was started for.
    private final class FakeSource: PrivateKeySource {
        private(set) var starts: [Int] = []
        private(set) var isRunning = false
        private var onEvent: ((PrivateKeyEvent) -> Void)?

        func start(productID: Int, onEvent: @escaping (PrivateKeyEvent) -> Void,
                   onNotice: @escaping (MouseNotice) -> Void) -> Bool {
            starts.append(productID)
            isRunning = true
            self.onEvent = onEvent
            return true
        }

        func stop() {
            isRunning = false
            onEvent = nil
        }

        func canWatch(productID: Int) -> Bool { true }
        func send(_ code: UInt8, down: Bool) { onEvent?(PrivateKeyEvent(code: code, isDown: down)) }
    }

    /// On the cable the same remapper takes the keys: the watch starts for the cable's product
    /// once driver mode is engaged, a short press fires Click, and a long press holds. Driver
    /// mode is wanted by the same rules, here waiting for Accessibility, as tests have none.
    func testTheCablesKeysDriveTheSameGesture() {
        var actions: [RemapAction] = []
        let source = FakeSource()
        let r = ButtonRemapper(defaults: defaults(#function), actionEmitter: { actions.append($0) }, privateKeys: source)
        r.setActiveDevice("COBRA-CABLE", deviceID: cable)
        var bindings = GestureBindings.defaults(for: ButtonRemapper.dpiButton)
        bindings.click = .mediaKey(code: 16, name: "Play / Pause")
        r.saveDpiSoftwareAction(.gesture(bindings))
        XCTAssertEqual(r.currentDpiDriverModeNeed, .accessibility)
        XCTAssertEqual(source.starts, [])
        r.dpiDriverModeChanged(.engaged)
        XCTAssertEqual(source.starts, [cable])
        source.send(keys.short, down: true)
        source.send(keys.short, down: false)
        XCTAssertEqual(actions, [bindings.click])
        source.send(keys.long, down: true)
        XCTAssertEqual(r.gestureHold?.trigger, ButtonRemapper.dpiButton)
        source.send(keys.long, down: false)
        XCTAssertNil(r.gestureHold)
        XCTAssertEqual(r.dpiCycleLabel(for: .dpiCycle), "Gesture (MacRazer)")

        r.setActiveDevice("COBRA-DONGLE", deviceID: dongle)
        XCTAssertFalse(source.isRunning, "the dongle has no keys")
        XCTAssertEqual(r.currentDpiDriverModeNeed, .none)
    }
}
