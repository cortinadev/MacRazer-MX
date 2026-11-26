// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// A hidden test switch that keeps the app's main thread busy on purpose, to see what a busy
/// app costs the drags its event tap holds (`DragTiming` measures it). The tap runs on the main
/// run loop, so while the thread is blocked every drag it asks for waits, for every app.
///
///     defaults write com.cortinadev.macrazer-mx dragTimingBusy -string 20/50/60
///
/// blocks the main thread for 20 ms in every 50 ms, for 60 seconds, at once
/// (`DefaultsKeyWatcher`); deleting the key stops it early. It can't be left on by accident: it
/// stops after the seconds asked for, at most `Plan.maxSeconds`, and clears its key then, and
/// a launch clears a key left behind (by a quit or a crash mid-run) before anything reads it.
/// `Scripts/stress-drag-test.sh busy` sets and clears it.
///
/// Main thread only.
enum MainThreadBusy {
    static let defaultsKey = "dragTimingBusy"

    /// What the key asks for: "block/every/seconds", whole numbers, the first two in
    /// milliseconds. Pure, so the limits are tested.
    struct Plan: Equatable, Sendable {
        /// Well under the second or so after which macOS turns off a tap that hasn't answered,
        /// so the test shows late drags rather than a tap switched off.
        static let maxBlockMilliseconds = 500
        static let maxEveryMilliseconds = 10_000
        static let maxSeconds = 300

        let blockMilliseconds: Int
        let everyMilliseconds: Int
        let seconds: Int

        /// Nil for anything but three whole numbers with a block from 1 ms to
        /// `maxBlockMilliseconds`, a period longer than the block and at most
        /// `maxEveryMilliseconds`, and from 1 to `maxSeconds` seconds.
        init?(_ text: String) {
            let parts = text.trimmingCharacters(in: .whitespaces)
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3, let block = parts[0], let every = parts[1], let seconds = parts[2],
                  (1...Self.maxBlockMilliseconds).contains(block),
                  every > block, every <= Self.maxEveryMilliseconds,
                  (1...Self.maxSeconds).contains(seconds) else { return nil }
            blockMilliseconds = block
            everyMilliseconds = every
            self.seconds = seconds
        }
    }

    nonisolated(unsafe) private static var timer: Timer?
    nonisolated(unsafe) private static var watcher: DefaultsKeyWatcher?

    /// Main thread, once.
    static func start() {
        guard watcher == nil else { return }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        watcher = DefaultsKeyWatcher(key: defaultsKey) { changed() }
    }

    /// The key changed: whatever was running stops, and a new plan starts. Removing the key
    /// from in here comes back through this at once (KVO), finding nothing to do.
    private static func changed() {
        let text = UserDefaults.standard.string(forKey: defaultsKey)
        if timer != nil { stop(text == nil ? "stopped" : "replaced") }
        guard let text else { return }
        guard let plan = Plan(text) else {
            // The text itself isn't written: the trace keeps to numbers.
            DragTiming.note("busy ignored: expected block/every/seconds, block 1 to \(Plan.maxBlockMilliseconds) ms, "
                            + "every longer than block and at most \(Plan.maxEveryMilliseconds) ms, "
                            + "1 to \(Plan.maxSeconds) s")
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        run(plan)
    }

    private static func run(_ plan: Plan) {
        let end = ProcessInfo.processInfo.systemUptime + Double(plan.seconds)
        let block = useconds_t(plan.blockMilliseconds * 1000)
        // Asleep rather than spinning: either way the run loop can't serve the tap, and asleep
        // it doesn't add its own CPU load to the test.
        let timer = Timer(timeInterval: Double(plan.everyMilliseconds) / 1000, repeats: true) { _ in
            guard ProcessInfo.processInfo.systemUptime < end else {
                finish()
                return
            }
            usleep(block)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DragTiming.note("busy on: main thread blocked \(plan.blockMilliseconds) ms every "
                        + "\(plan.everyMilliseconds) ms for \(plan.seconds) s")
    }

    private static func finish() {
        stop("done")
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func stop(_ reason: String) {
        timer?.invalidate()
        timer = nil
        DragTiming.note("busy off (\(reason))")
    }
}
