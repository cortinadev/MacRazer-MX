// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics
import Foundation

/// How late events reach an event tap and how long its callback keeps them, gathered over a
/// window of `length` seconds and summed up once per window. Pure: times come in as seconds on
/// one monotonic clock, so tests drive it with plain numbers.
///
/// The delay runs from the event's own time (when macOS stamped it) to when the callback starts
/// on it. That is what a busy thread costs: an active tap holds each event it asks for, for
/// every app, until its callback returns, so a late callback is a late drag everywhere.
struct TapTimingWindow {
    struct Summary: Equatable, Sendable {
        /// Events in the window.
        let count: Int
        /// How many of them had a time to measure the delay from (`TapEventClock`).
        let timed: Int
        /// Events a second, from the first arrival to the last; nil with fewer than two.
        let perSecond: Double?
        /// Delays in seconds, nil when no event in the window was timed.
        let delayP50: TimeInterval?
        let delayP95: TimeInterval?
        let delayMax: TimeInterval?
        /// The longest time one event spent in the callback, in seconds.
        let callbackMax: TimeInterval

        /// Key=value pairs with every key distinct and times in milliseconds, so a script can
        /// pick the numbers out with no context. `-` for a number there is none of.
        var line: String {
            func ms(_ seconds: TimeInterval?) -> String { seconds.map { String(format: "%.2f", $0 * 1000) } ?? "-" }
            var text = "n=\(count) per_s=\(perSecond.map { String(Int($0.rounded())) } ?? "-")"
            text += " delay_p50_ms=\(ms(delayP50)) delay_p95_ms=\(ms(delayP95)) delay_max_ms=\(ms(delayMax))"
            text += String(format: " callback_max_ms=%.3f", callbackMax * 1000)
            if timed < count { text += " untimed=\(count - timed)" }
            return text
        }
    }

    let length: TimeInterval
    private var start: TimeInterval?
    private var firstArrival: TimeInterval = 0
    private var lastArrival: TimeInterval = 0
    private var count = 0
    private var delays: [TimeInterval] = []
    private var callbackMax: TimeInterval = 0

    init(length: TimeInterval = 1) {
        self.length = length
    }

    var isEmpty: Bool { count == 0 }

    /// One event that reached the callback at `arrival` and spent `callback` seconds in it.
    /// `eventTime`: when macOS stamped it, nil when that isn't known. An `arrival` past the
    /// window closes it first, and its summary is returned for the caller to write: after the
    /// event's own timing is taken, so writing it never counts against an event.
    mutating func record(arrival: TimeInterval, eventTime: TimeInterval?, callback: TimeInterval) -> Summary? {
        let closed = closeIfDue(at: arrival)
        if start == nil {
            start = arrival
            firstArrival = arrival
        }
        count += 1
        lastArrival = arrival
        // A stamp a hair after the arrival is rounding between two readings of the clock.
        if let eventTime { delays.append(max(0, arrival - eventTime)) }
        callbackMax = max(callbackMax, callback)
        return closed
    }

    /// The summary once `time` is past the window, which then starts over empty; nil while it
    /// is still open or holds nothing. For a timer, so the last second of a drag is written
    /// once the events stop coming.
    mutating func closeIfDue(at time: TimeInterval) -> Summary? {
        guard let start, time >= start + length else { return nil }
        return close()
    }

    /// The summary of whatever the window holds, which then starts over empty; nil when it
    /// holds nothing.
    mutating func close() -> Summary? {
        defer {
            start = nil
            count = 0
            delays.removeAll(keepingCapacity: true)
            callbackMax = 0
        }
        guard count > 0 else { return nil }
        let sorted = delays.sorted()
        let span = lastArrival - firstArrival
        return Summary(count: count, timed: sorted.count,
                       perSecond: count > 1 && span > 0 ? Double(count - 1) / span : nil,
                       delayP50: sorted.isEmpty ? nil : Self.percentile(50, of: sorted),
                       delayP95: sorted.isEmpty ? nil : Self.percentile(95, of: sorted),
                       delayMax: sorted.last, callbackMax: callbackMax)
    }

    /// Nearest rank: the smallest value with at least `percent` of them at or below it.
    /// `sorted` is ascending and not empty.
    static func percentile(_ percent: Double, of sorted: [TimeInterval]) -> TimeInterval {
        let rank = Int((percent / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// When an event was stamped, on the mach absolute time clock. A CGEvent's timestamp is
/// documented as nanoseconds since startup, and AppKit reads it that way
/// (`NSEvent(cgEvent:)` divides it by 10^9), but it has also been reported to carry mach
/// absolute time ticks, which on Apple Silicon are 125/3 ns each, not one. Which of the two an
/// event carries shows by itself: only one reading puts it a moment before now. Pure, with the
/// clock's timebase passed in.
enum TapEventClock {
    /// `timestamp` as seconds on the clock `nowTicks` was read from, or nil when it is zero (an
    /// event made by a process and never stamped) or neither reading is within `plausible`
    /// seconds before now. Ten seconds tells the two apart for any Mac up longer than that.
    static func seconds(ofTimestamp timestamp: UInt64, nowTicks: UInt64, numer: UInt32, denom: UInt32,
                        plausible: TimeInterval = 10) -> TimeInterval? {
        guard timestamp > 0, numer > 0, denom > 0 else { return nil }
        let nanosecondsPerTick = Double(numer) / Double(denom)
        let now = Double(nowTicks) * nanosecondsPerTick / 1e9
        for candidate in [Double(timestamp) / 1e9, Double(timestamp) * nanosecondsPerTick / 1e9] {
            // A millisecond of slack ahead of now, for two clocks read a moment apart.
            let age = now - candidate
            if age >= -0.001, age <= plausible { return candidate }
        }
        return nil
    }
}

/// Calls `changed` on the main thread whenever `key` changes in `defaults`, whether this
/// process changed it or another one did (`defaults write`): KVO on UserDefaults hears both.
/// It lets a hidden test switch act at once, with no relaunch.
final class DefaultsKeyWatcher: NSObject, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let changed: @Sendable () -> Void

    init(defaults: UserDefaults = .standard, key: String, changed: @escaping @Sendable () -> Void) {
        self.defaults = defaults
        self.key = key
        self.changed = changed
        super.init()
        defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
    }

    deinit {
        defaults.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == key else { return }
        // A change from another process has come on the main thread so far; one made on
        // another thread of this process comes on that thread.
        if Thread.isMainThread { changed() } else { DispatchQueue.main.async(execute: changed) }
    }
}

/// The hidden drag timing: while the defaults key `dragTimingLog` is on, every extra-button
/// drag that goes through the event tap is timed (`TapTimingWindow`), and about once a second
/// while drags come a `DRAGTIMING n=... per_s=... delay_p50_ms=...` line goes to the gesture
/// trace's file, `~/Library/Logs/MacRazer MX/gesture.log`. Only numbers: no position, no
/// button, nothing typed, and never a line per event.
///
///     defaults write com.cortinadev.macrazer-mx dragTimingLog -bool true
///
/// turns it on, `defaults delete` off, both at once (`DefaultsKeyWatcher`); it is read at
/// launch too. Drags go through the tap only while some button is a gesture
/// (`ButtonRemapper.eventMask`), so with none there is nothing to time. Off, it costs the tap
/// one boolean test per event. `Scripts/stress-drag-test.sh` turns it on and off around a run.
///
/// Main thread only, like the tap.
enum DragTiming {
    static let defaultsKey = "dragTimingLog"

    /// What the tap tests per event.
    nonisolated(unsafe) private(set) static var isOn = false
    nonisolated(unsafe) private static var window = TapTimingWindow()
    nonisolated(unsafe) private static var timer: Timer?
    nonisolated(unsafe) private static var watcher: DefaultsKeyWatcher?
    /// Whether the tap asks for drags now, for the line that says it is on.
    nonisolated(unsafe) private static var dragsTapped: () -> Bool = { false }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Lines are formatted and written here, in order, so the main thread never waits on the file.
    private static let writer = DispatchQueue(label: "DragTiming.writer", qos: .utility)

    /// Main thread, once: reads the key and watches it.
    static func start(dragsTapped: @escaping () -> Bool) {
        guard watcher == nil else { return }
        self.dragsTapped = dragsTapped
        watcher = DefaultsKeyWatcher(key: defaultsKey) { refresh() }
        refresh()
    }

    private static func refresh() {
        let wanted = UserDefaults.standard.bool(forKey: defaultsKey)
        guard wanted != isOn else { return }
        isOn = wanted
        if wanted {
            window = TapTimingWindow()
            // Writes the last window of a drag once the drags stop: while they come, the next
            // drag past the window does.
            let timer = Timer(timeInterval: 1, repeats: true) { _ in flushIfDue() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            let tapped = dragsTapped()
            note("on, drags go through the tap: \(tapped ? "yes" : "no, no button is a gesture")")
        } else {
            timer?.invalidate()
            timer = nil
            if let summary = window.close() { note { summary.line } }
            note("off")
        }
    }

    /// Runs the tap's own handling of an event while the timing is on, timing it when it is a
    /// drag. A tap macOS turned off for being slow is noted too: that is the worst a busy app
    /// does, and its events went by untimed.
    static func measure(type: CGEventType, event: CGEvent,
                        _ handle: () -> Unmanaged<CGEvent>?) -> Unmanaged<CGEvent>? {
        switch type {
        case .otherMouseDragged:
            let entered = mach_absolute_time()
            let stamp = event.timestamp
            let result = handle()
            let left = mach_absolute_time()
            let eventTime = TapEventClock.seconds(ofTimestamp: stamp, nowTicks: entered,
                                                  numer: timebase.numer, denom: timebase.denom)
            if let summary = window.record(arrival: seconds(entered), eventTime: eventTime,
                                           callback: seconds(left &- entered)) {
                note { summary.line }
            }
            return result
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            note("tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            return handle()
        default:
            return handle()
        }
    }

    /// A `DRAGTIMING` line, written off the main thread. For `MainThreadBusy` too, so its lines
    /// keep their place among these.
    static func note(_ text: @escaping @Sendable () -> String) {
        writer.async { GestureDebugLog.write("DRAGTIMING " + text()) }
    }

    static func note(_ text: String) {
        note { text }
    }

    private static func flushIfDue() {
        if let summary = window.closeIfDue(at: seconds(mach_absolute_time())) { note { summary.line } }
    }

    private static func seconds(_ ticks: UInt64) -> TimeInterval {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
}
