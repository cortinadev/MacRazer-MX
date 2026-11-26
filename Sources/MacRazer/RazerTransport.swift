// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// What `MouseController` needs from a connected mouse, whichever link it is on: the USB
/// HID feature report (cable or 2.4 GHz dongle) or Razer's Bluetooth LE service.
/// Both speak `RazerReport`, so every command builder and parser is shared.
protocol RazerTransport: AnyObject {
    var productID: Int { get }
    var productName: String { get }
    /// Identifies the physical port for the serial cache. 0 on Bluetooth, where the
    /// product id alone tells a reconnect apart from a different mouse.
    var locationID: Int { get }
    var isBluetooth: Bool { get }
    func sendWithRetry(_ report: RazerReport) throws -> RazerReport
    func close()
}

extension HIDDevice: RazerTransport {
    var isBluetooth: Bool { false }
    func sendWithRetry(_ report: RazerReport) throws -> RazerReport {
        try sendWithRetry(report, attempts: HIDDevice.defaultAttempts)
    }
}

/// The device mode over a cable or dongle (`RazerCommands.getDeviceMode`, `setDeviceMode`), for
/// the DPI button's driver mode (`DeviceModeLink`). Each read and write is one `send`, never the
/// retry ladder, as over Bluetooth: a background check that goes unanswered is tried again by
/// the book (`DpiDriverModeBook`), and a write is sent once and then read back.
extension HIDDevice: DeviceModeLink {
    func readDeviceMode() throws -> UInt16 {
        try Self.readDeviceMode(send: { try self.send($0) })
    }

    func writeDeviceMode(_ mode: BLEProtocol.DeviceMode) throws {
        try Self.writeDeviceMode(mode, send: { try self.send($0) })
    }

    /// The read, apart from the device so tests can drive it: `send` is one exchange.
    static func readDeviceMode(send: (RazerReport) throws -> RazerReport) throws -> UInt16 {
        let reply: RazerReport
        do {
            reply = try send(RazerCommands.getDeviceMode())
        } catch {
            GestureDebugLog.log("DEVMODE read 00 84 over USB -> \(error)")
            throw error
        }
        GestureDebugLog.log("DEVMODE read 00 84 over USB -> \(deviceModeReplyText(reply))")
        guard let mode = RazerCommands.parseDeviceMode(reply) else { throw HIDError.badResponse }
        return mode
    }

    /// The write, the same way. Throws unless the answer is a success.
    static func writeDeviceMode(_ mode: BLEProtocol.DeviceMode, send: (RazerReport) throws -> RazerReport) throws {
        let request = RazerCommands.setDeviceMode(mode)
        let written = GestureDebugLog.hex(request.arguments.prefix(2))
        let reply: RazerReport
        do {
            reply = try send(request)
        } catch {
            GestureDebugLog.log("DEVMODE write 00 04 [\(written)] over USB -> \(error)")
            throw error
        }
        GestureDebugLog.log("DEVMODE write 00 04 [\(written)] over USB -> \(deviceModeReplyText(reply))")
        // `send` passes a status it doesn't know through; only a success counts here.
        guard reply.status == RazerStatus.successful.rawValue else { throw HIDError.commandFailed }
    }

    /// The trace's text for an answer: its status and the two mode bytes.
    private static func deviceModeReplyText(_ reply: RazerReport) -> String {
        String(format: "status=%02x args=", reply.status) + GestureDebugLog.hex(reply.arguments.prefix(2))
    }
}

/// The retry ladder both transports share, so a policy change can't drift between them.
/// Falls through to the last error.
enum RazerRetry {
    static func run<T>(attempts: Int, _ body: () throws -> T) throws -> T {
        var lastError: Error = HIDDevice.HIDError.timeout
        for attempt in 0..<attempts {
            do {
                return try body()
            } catch HIDDevice.HIDError.notSupported {
                // Deterministic per model/command — retrying can't change the answer, and
                // the backoffs would just delay every poll on models lacking the feature.
                throw HIDDevice.HIDError.notSupported
            } catch HIDDevice.HIDError.notFound {
                // The device is gone (a Bluetooth link dropped); only a reopen can help.
                throw HIDDevice.HIDError.notFound
            } catch {
                lastError = error
                // No backoff after the final attempt: it would only delay reporting the
                // failure (offline detection, queued user writes on the serial queue).
                if attempt < attempts - 1 {
                    usleep(useconds_t(50_000 * (attempt + 1))) // 50ms, 100ms...
                }
            }
        }
        throw lastError
    }
}
