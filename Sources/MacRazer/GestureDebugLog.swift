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
/// pointer deltas only, never what is typed (see `GestureDebugHIDWatch` for how the raw HID
/// watch keeps to that).
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

import IOKit.hid

/// With the trace on, also record what the mouse itself reports at the HID level, apart from
/// pointer and wheel movement: a button the firmware handles on its own (the Cobra's DPI
/// button) may still say something when it goes down, which only shows here.
enum GestureDebugHIDWatch {
    nonisolated(unsafe) private static var manager: IOHIDManager?

    /// Main thread, once. Needs Input Monitoring, which the F20 bridge needs anyway.
    static func startIfEnabled() {
        guard GestureDebugLog.enabled, manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let vendors = [0x1532, 0x068E].map { [kIOHIDVendorIDKey: $0] as CFDictionary }
        IOHIDManagerSetDeviceMatchingMultiple(manager, vendors as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { _, _, _, value in
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            // Generic Desktop is the pointer and wheel, at the polling rate: not wanted.
            guard page != kHIDPage_GenericDesktop else { return }
            // Never which key: the match is by vendor, so a keyboard of the same make is
            // watched too, and what is typed on it must not reach a log. F13 to F20 are the
            // exception, being what a remapped mouse button types.
            if page == kHIDPage_KeyboardOrKeypad, !(0x68...0x6F).contains(usage) {
                GestureDebugLog.log("HID keyboard key (not recorded)")
                return
            }
            // The wheel's sideways axis reports with every packet and says nothing.
            if page == kHIDPage_Consumer, usage == kHIDUsage_Csmr_ACPan { return }
            GestureDebugLog.log(String(format: "HID page=%02x usage=%02x value=%ld len=%ld",
                                       page, usage, IOHIDValueGetIntegerValue(value), IOHIDValueGetLength(value)))
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        GestureDebugLog.log("HID watch open result=\(result)")
        self.manager = manager
    }
}
