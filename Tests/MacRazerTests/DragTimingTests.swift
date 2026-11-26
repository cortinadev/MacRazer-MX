// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// The hidden drag timing's pure parts: the per-second window (`TapTimingWindow`), reading an
/// event's timestamp (`TapEventClock`), and the limits of the busy main thread
/// (`MainThreadBusy.Plan`).
final class DragTimingTests: XCTestCase {
    // MARK: Percentiles

    func testPercentileIsNearestRank() {
        let hundred = (1...100).map(Double.init)
        XCTAssertEqual(TapTimingWindow.percentile(50, of: hundred), 50)
        XCTAssertEqual(TapTimingWindow.percentile(95, of: hundred), 95)
        XCTAssertEqual(TapTimingWindow.percentile(100, of: hundred), 100)
        XCTAssertEqual(TapTimingWindow.percentile(50, of: [1, 2, 3, 4]), 2)
        XCTAssertEqual(TapTimingWindow.percentile(95, of: [1, 2, 3, 4]), 4)
        XCTAssertEqual(TapTimingWindow.percentile(50, of: [7]), 7)
        XCTAssertEqual(TapTimingWindow.percentile(0, of: [3, 9]), 3, "never below the first value")
    }

    // MARK: Window

    func testEmptyWindowWritesNothing() {
        var window = TapTimingWindow()
        XCTAssertTrue(window.isEmpty)
        XCTAssertNil(window.close())
        XCTAssertNil(window.closeIfDue(at: 1_000))
    }

    func testSummaryOfOneWindow() throws {
        var window = TapTimingWindow()
        // 100 events over 0.99 s, the i-th 1 ms × i late; the callback longest on the 40th.
        for i in 1...100 {
            let arrival = 10 + Double(i - 1) * 0.01
            XCTAssertNil(window.record(arrival: arrival, eventTime: arrival - Double(i) / 1000,
                                       callback: i == 40 ? 0.0005 : 0.00002))
        }
        let summary = try XCTUnwrap(window.close())
        XCTAssertEqual(summary.count, 100)
        XCTAssertEqual(summary.timed, 100)
        XCTAssertEqual(try XCTUnwrap(summary.perSecond), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.delayP50), 0.050, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summary.delayP95), 0.095, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summary.delayMax), 0.100, accuracy: 1e-9)
        XCTAssertEqual(summary.callbackMax, 0.0005, accuracy: 1e-12)
        XCTAssertEqual(summary.line, "n=100 per_s=100 delay_p50_ms=50.00 delay_p95_ms=95.00 "
                       + "delay_max_ms=100.00 callback_max_ms=0.500")
        XCTAssertTrue(window.isEmpty, "a closed window starts over")
        XCTAssertNil(window.close())
    }

    func testWindowRollsOverAtItsLength() throws {
        var window = TapTimingWindow(length: 1)
        XCTAssertNil(window.record(arrival: 5.0, eventTime: 4.999, callback: 0))
        XCTAssertNil(window.record(arrival: 5.5, eventTime: 5.499, callback: 0))
        XCTAssertNil(window.record(arrival: 5.999, eventTime: 5.998, callback: 0))
        // The first event a whole length after the window began closes it and starts the next.
        let first = try XCTUnwrap(window.record(arrival: 6.0, eventTime: 5.996, callback: 0))
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(try XCTUnwrap(first.delayMax), 0.001, accuracy: 1e-9,
                       "the event that closed it belongs to the next window")
        XCTAssertFalse(window.isEmpty)
        XCTAssertNil(window.closeIfDue(at: 6.9), "still open")
        let second = try XCTUnwrap(window.closeIfDue(at: 7.0), "the timer closes it once the drags stop")
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(try XCTUnwrap(second.delayP95), 0.004, accuracy: 1e-9)
        XCTAssertNil(second.perSecond, "one event has no rate")
        XCTAssertTrue(window.isEmpty)
        XCTAssertNil(window.closeIfDue(at: 100))
    }

    func testEventsWithoutATimeCountButAreNotTimed() throws {
        var window = TapTimingWindow()
        _ = window.record(arrival: 1.0, eventTime: nil, callback: 0.001)
        _ = window.record(arrival: 1.5, eventTime: 1.498, callback: 0)
        var summary = try XCTUnwrap(window.close())
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.timed, 1)
        XCTAssertEqual(summary.line, "n=2 per_s=2 delay_p50_ms=2.00 delay_p95_ms=2.00 delay_max_ms=2.00 "
                       + "callback_max_ms=1.000 untimed=1")

        _ = window.record(arrival: 3.0, eventTime: nil, callback: 0)
        summary = try XCTUnwrap(window.close())
        XCTAssertNil(summary.delayP50)
        XCTAssertEqual(summary.line, "n=1 per_s=- delay_p50_ms=- delay_p95_ms=- delay_max_ms=- "
                       + "callback_max_ms=0.000 untimed=1")
    }

    func testAStampJustAfterTheArrivalIsNoDelay() throws {
        var window = TapTimingWindow()
        _ = window.record(arrival: 2.0, eventTime: 2.0005, callback: 0)
        XCTAssertEqual(try XCTUnwrap(window.close()?.delayMax), 0)
    }

    // MARK: Event clock

    /// Apple Silicon: 125/3 ns per tick of mach absolute time.
    private let numer: UInt32 = 125, denom: UInt32 = 3
    /// About 17.7 hours up, in ticks of 125/3 ns: 63,645 s.
    private let nowTicks: UInt64 = 1_527_480_000_000

    func testTimestampInNanoseconds() throws {
        let nowNanoseconds = UInt64(Double(nowTicks) * 125 / 3)
        let seconds = try XCTUnwrap(TapEventClock.seconds(ofTimestamp: nowNanoseconds - 2_000_000, nowTicks: nowTicks,
                                                          numer: numer, denom: denom))
        XCTAssertEqual(Double(nowNanoseconds) / 1e9 - seconds, 0.002, accuracy: 1e-6)
    }

    func testTimestampInMachTicks() throws {
        // 2 ms is 48,000 ticks of 125/3 ns.
        let seconds = try XCTUnwrap(TapEventClock.seconds(ofTimestamp: nowTicks - 48_000, nowTicks: nowTicks,
                                                          numer: numer, denom: denom))
        XCTAssertEqual(Double(nowTicks) * 125 / 3 / 1e9 - seconds, 0.002, accuracy: 1e-6)
    }

    func testTimestampOnAClockOfOneNanosecondPerTick() throws {
        let seconds = try XCTUnwrap(TapEventClock.seconds(ofTimestamp: 5_000_000_000_000 - 3_000_000,
                                                          nowTicks: 5_000_000_000_000, numer: 1, denom: 1))
        XCTAssertEqual(seconds, 4999.997, accuracy: 1e-6)
    }

    func testTimestampWithNoTimeOrOutOfRangeIsNil() {
        XCTAssertNil(TapEventClock.seconds(ofTimestamp: 0, nowTicks: nowTicks, numer: numer, denom: denom),
                     "an event made in a process, never stamped")
        XCTAssertNil(TapEventClock.seconds(ofTimestamp: nowTicks + 48_000_000, nowTicks: nowTicks,
                                           numer: numer, denom: denom), "a second in the future either way")
        XCTAssertNil(TapEventClock.seconds(ofTimestamp: nowTicks / 2, nowTicks: nowTicks, numer: numer, denom: denom),
                     "hours ago either way")
        XCTAssertNil(TapEventClock.seconds(ofTimestamp: 1, nowTicks: nowTicks, numer: numer, denom: 0))
    }

    // MARK: Busy main thread

    func testBusyPlanReadsBlockEveryAndSeconds() {
        let plan = MainThreadBusy.Plan("20/50/60")
        XCTAssertEqual(plan?.blockMilliseconds, 20)
        XCTAssertEqual(plan?.everyMilliseconds, 50)
        XCTAssertEqual(plan?.seconds, 60)
        XCTAssertEqual(MainThreadBusy.Plan(" 500 / 10000 / 300 ")?.seconds, 300, "the limits themselves")
        XCTAssertEqual(MainThreadBusy.Plan("1/2/1")?.blockMilliseconds, 1)
    }

    func testBusyPlanRefusesAnythingUnboundedOrMalformed() {
        for text in ["", "20/50", "20/50/60/1", "20/50/0", "20/50/301", "0/50/60", "501/1000/60",
                     "20/20/60", "50/20/60", "20/10001/60", "-5/50/60", "20.5/50/60", "a/b/c", "20//60"] {
            XCTAssertNil(MainThreadBusy.Plan(text), text)
        }
    }
}
