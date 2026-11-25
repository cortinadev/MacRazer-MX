// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// A diagnostic trace of gesture holds, off unless asked for:
///
///     defaults write com.cortinadev.macrazer-mx gestureDebugLog -bool true
///
/// then relaunch. Lines go to `~/Library/Logs/MacRazer MX/gesture.log`. It exists because
/// nothing outside the app can watch what its event tap receives: another process needs its
/// own Input Monitoring grant to see the same events. It records button and F20 timing and
/// pointer deltas only, never what is typed.
enum GestureDebugLog {
    static let defaultsKey = "gestureDebugLog"

    /// Read once: the tap's hot path must not ask UserDefaults per event.
    static let enabled = UserDefaults.standard.bool(forKey: defaultsKey)

    private static let start = Date()
    nonisolated(unsafe) private static var handle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacRazer MX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gesture.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    /// Main thread only, like the tap that calls it. The message is an autoclosure so a
    /// disabled log costs one boolean test.
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = String(format: "%9.3f %@\n", Date().timeIntervalSince(start), message())
        handle?.write(Data(line.utf8))
    }
}
