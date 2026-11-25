// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation
import IOKit
import IOKit.hid

/// The private keys a mouse's DPI button reports in driver mode (`RazerDevices.dpiButtonPrivateKeys`).
struct DpiButtonPrivateKeys: Equatable, Sendable {
    /// Reported when a short press is released, and held for about 55 ms.
    let short: UInt8
    /// Reported once the firmware recognises a long press, about a second after the button
    /// went down, and held until it comes up.
    let long: UInt8

    /// Synapse's "DPI cycle" and "AI launcher" keys, as the Cobra HyperSpeed reports them.
    static let cobraHyperSpeed = DpiButtonPrivateKeys(short: 0x52, long: 0xD2)
}

/// One change in the private keys held: `code` went down or came up.
struct PrivateKeyEvent: Equatable, Sendable {
    let code: UInt8
    let isDown: Bool
}

/// HID input report 4 of a mouse in driver mode: an array of the private keys held now, all
/// zero for none. Pure, so the layout is tested without a mouse.
enum PrivateKeyReport {
    static let reportID = 4

    /// The keys held, or nil for any other report. IOKit hands the report over with its id
    /// in front, and on the Cobra HyperSpeed over Bluetooth with the id twice
    /// (`04 04 d2 00 00 00 00 00 00`), so up to two leading ids are dropped. A key whose code
    /// is the report id itself can't be told from that, and is never one MacRazer acts on.
    static func heldKeys(reportID: Int, bytes: [UInt8]) -> Set<UInt8>? {
        guard reportID == Self.reportID else { return nil }
        let id = UInt8(Self.reportID)
        var keys = bytes[...]
        if keys.first == id { keys = keys.dropFirst() }
        if keys.first == id { keys = keys.dropFirst() }
        return Set(keys.filter { $0 != 0 })
    }
}

/// Turns the successive key arrays of report 4 into a down and an up per key. A frame that
/// holds what the last one held changes nothing, so a report delivered twice (the mouse
/// matches as two HID devices, and each delivers it) fires once.
struct PrivateKeyTracker: Equatable, Sendable {
    private(set) var held: Set<UInt8> = []

    /// The events from `keys`, the keys held now: releases first, then presses, each in code
    /// order so the result never depends on a set's order.
    mutating func update(_ keys: Set<UInt8>) -> [PrivateKeyEvent] {
        let released = held.subtracting(keys).sorted().map { PrivateKeyEvent(code: $0, isDown: false) }
        let pressed = keys.subtracting(held).sorted().map { PrivateKeyEvent(code: $0, isDown: true) }
        held = keys
        return released + pressed
    }
}

/// Where `ButtonRemapper` gets the DPI button's private keys from. The app's is
/// `DpiPrivateKeyWatcher`; tests hand the remapper the keys themselves.
protocol PrivateKeySource: AnyObject {
    var isRunning: Bool { get }
    /// Starts delivering the private keys of the Bluetooth mouse `productID`, on the main
    /// thread. False when it can't: Input Monitoring isn't granted, or the mouse's HID device
    /// wouldn't open. Starting again for the same mouse keeps what is running.
    func start(productID: Int, onEvent: @escaping (PrivateKeyEvent) -> Void) -> Bool
    func stop()
}

/// Watches HID input report 4 of one Bluetooth mouse (vendor 0x068E and its product id, so
/// nothing of any other device) and turns it into private-key events (`PrivateKeyTracker`).
/// Needs Input Monitoring, as every HID input read does. Only runs while the mouse is in
/// driver mode, which is when it sends that report.
///
/// An `IOHIDManager` finds the mouse's HID devices, now and whenever macOS enumerates them
/// again (a reconnect), and each is watched as the gesture trace watches it
/// (`GestureDebugHIDWatch`): its own buffer and an input report callback. All of them feed
/// one tracker, which is what makes a report that comes from two of them count once.
///
/// Main thread only, like the run loop it schedules on. `@unchecked Sendable` states that
/// discipline, the same as `HIDInputWatcher`.
final class DpiPrivateKeyWatcher: PrivateKeySource, @unchecked Sendable {
    private var manager: IOHIDManager?
    private var watched: [Watched] = []
    private var tracker = PrivateKeyTracker()
    private var onEvent: ((PrivateKeyEvent) -> Void)?
    private var productID: Int?
    /// Retained for the C callbacks' context while running, released by `stop()`.
    private var selfContext: UnsafeMutableRawPointer?
    /// Bumped by every start and stop, so events handed off before a stop are dropped.
    private var generation = 0

    /// One HID device of the mouse, and the buffer its reports land in, kept until it goes.
    private struct Watched {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
    }

    var isRunning: Bool { manager != nil }

    func start(productID: Int, onEvent: @escaping (PrivateKeyEvent) -> Void) -> Bool {
        if isRunning, self.productID == productID {
            self.onEvent = onEvent
            return true
        }
        stop()
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            GestureDebugLog.log("PRIVKEY watch not started: Input Monitoring is not granted")
            return false
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Int] = [kIOHIDVendorIDKey: BLEProtocol.vendorId, kIOHIDProductIDKey: productID]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DpiPrivateKeyWatcher>.fromOpaque(context).takeUnretainedValue().watch(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DpiPrivateKeyWatcher>.fromOpaque(context).takeUnretainedValue().unwatch(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        self.productID = productID
        self.onEvent = onEvent
        selfContext = context
        tracker = PrivateKeyTracker()
        generation &+= 1
        // The devices there now, at once, so a mouse whose device won't open says so here.
        // The matching callback brings the same ones again, and any that come later.
        let present = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        present.forEach(watch)
        GestureDebugLog.log(String(format: "PRIVKEY watch started for product %04x", productID)
                            + ": open=\(HIDDevice.HIDError.hex(opened)), \(watched.count) of \(present.count) devices opened")
        guard present.isEmpty || !watched.isEmpty else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        guard let manager else { return }
        for entry in watched { release(entry) }
        watched = []
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        productID = nil
        onEvent = nil
        tracker = PrivateKeyTracker()
        generation &+= 1
        if let context = selfContext {
            selfContext = nil
            Unmanaged<DpiPrivateKeyWatcher>.fromOpaque(context).release()
        }
        GestureDebugLog.log("PRIVKEY watch stopped")
    }

    private func watch(_ device: IOHIDDevice) {
        guard isRunning, !watched.contains(where: { CFEqual($0.device, device) }) else { return }
        let size = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        let open = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard size > 0, open == kIOReturnSuccess, let context = selfContext else {
            GestureDebugLog.log("PRIVKEY watch can't open a device: open=\(HIDDevice.HIDError.hex(open)) maxInputReport=\(size)")
            return
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            Unmanaged<DpiPrivateKeyWatcher>.fromOpaque(context).takeUnretainedValue()
                .received(reportID: Int(reportID), bytes: Array(UnsafeBufferPointer(start: report, count: max(0, length))))
        }, context)
        watched.append(Watched(device: device, buffer: buffer, size: size))
    }

    private func unwatch(_ device: IOHIDDevice) {
        guard let index = watched.firstIndex(where: { CFEqual($0.device, device) }) else { return }
        release(watched.remove(at: index))
    }

    /// Stops a device's reports and closes it. Its buffer goes on the next turn of the run
    /// loop, never inside IOKit's own call (the removal callback is one).
    private func release(_ entry: Watched) {
        IOHIDDeviceRegisterInputReportCallback(entry.device, entry.buffer, entry.size, nil, nil)
        IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
        let buffer = UncheckedBuffer(pointer: entry.buffer)
        DispatchQueue.main.async { buffer.pointer.deallocate() }
    }

    /// A buffer handed to the next turn of the main run loop to be freed there.
    private struct UncheckedBuffer: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<UInt8>
    }

    /// Inside IOKit's dispatch of the report: the events go to `onEvent` on the next turn of
    /// the run loop, so whatever they lead to (a stop among them) never runs in here.
    private func received(reportID: Int, bytes: [UInt8]) {
        guard isRunning, let keys = PrivateKeyReport.heldKeys(reportID: reportID, bytes: bytes) else { return }
        let events = tracker.update(keys)
        guard !events.isEmpty else { return }
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, self.generation == generation else { return }
            for event in events {
                GestureDebugLog.log(String(format: "PRIVKEY %@ %02x", event.isDown ? "down" : "up", event.code))
                self.onEvent?(event)
            }
        }
    }

    deinit { stop() }
}
