// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Where the DPI button's driver mode stands, for the Buttons page and `ButtonRemapper`, on
/// a mouse that reports the button as private keys (`RazerDevices.dpiButtonPrivateKeys`).
enum DpiDriverModeState: Equatable, Sendable {
    /// Not wanted, or no such mouse is connected: the firmware handles the button.
    case off
    /// Being read and written now.
    case engaging
    /// Read back from the mouse in driver mode: its private keys are MacRazer's to act on.
    case engaged
    /// It couldn't be set, in a plain sentence for the page (`MouseController.dpiDriverModeErrorText`).
    case unavailable(String)
}

/// When the DPI button's driver mode is read and written, apart from the device so the rules
/// are tested without one. `MouseController` keeps one on its device queue and runs `step`
/// whenever it has a moment (`Occasion`), and does what it says.
///
/// Driver mode is volatile: the mouse is back in normal mode after it sleeps, reconnects or
/// is switched off and on. So what was verified belongs to one connection
/// (`connectionChanged`), and a wake makes it doubtful (`doubtful`). While it is wanted, it is
/// engaged on each new connection and after each wake (a read first, so a mouse still in it
/// isn't written), and read again at most every `recheckInterval` from the poll, to put it
/// back if the mouse fell back to normal mode. A change that fails isn't retried at once:
/// the poll tries again `recheckInterval` later, at most `maxAttempts` times per connection,
/// then not until the next connection, wake or change of mind. When it isn't wanted, normal
/// mode is written back only where this run may have left driver mode (`maybeSet`).
struct DpiDriverModeBook: Equatable, Sendable {
    /// How often the poll reads the mode while it is engaged, and how long a failed change
    /// waits before the poll tries it again.
    static let recheckInterval: TimeInterval = 30
    /// Failed changes on one connection before the poll stops trying.
    static let maxAttempts = 3

    /// What prompts a look at the mode.
    enum Occasion: Equatable, Sendable {
        /// `ButtonRemapper` started or stopped wanting it: an explicit change, tried at once.
        case wantChanged
        /// A read of the mouse went through: the poll, a connection, a wake check.
        case mouseAnswered
    }

    enum Step: Equatable, Sendable {
        case nothing
        /// Read the mode and write driver mode if it isn't (`BluetoothDevice.setDeviceMode`).
        /// It isn't known to be engaged now, so the page shows it being set up.
        case engage
        /// The same, while it is known to be engaged: a quiet check that the mouse is still in
        /// it, which puts it back if not. A read that goes unanswered changes nothing: the
        /// mouse is most likely still in the mode, and the next poll reads again.
        case recheck
        /// Write normal mode and read it back.
        case restore
    }

    /// `ButtonRemapper` needs driver mode: the DPI button has an action MacRazer carries out.
    private(set) var wanted = false
    /// When driver mode was last read back on this connection. Nil when it isn't known to be
    /// engaged now.
    private(set) var verifiedAt: TimeInterval?
    /// Changes that failed on this connection since the last success, and when the last was.
    private(set) var failures = 0
    private(set) var lastFailureAt: TimeInterval?
    /// This run may have left the mouse in driver mode: set before a write of it, or when a
    /// read finds it, and cleared once normal mode reads back. Quitting restores normal mode
    /// only then.
    private(set) var maybeSet = false

    /// What to do now.
    func step(for occasion: Occasion, now: TimeInterval) -> Step {
        if wanted {
            if let verifiedAt {
                return now - verifiedAt >= Self.recheckInterval ? .recheck : .nothing
            }
            return mayTry(occasion, now: now) ? .engage : .nothing
        }
        return maybeSet && mayTry(occasion, now: now) ? .restore : .nothing
    }

    /// A first try, or a retry the poll is allowed (see the type's notes).
    private func mayTry(_ occasion: Occasion, now: TimeInterval) -> Bool {
        guard failures > 0, let lastFailureAt else { return true }
        return occasion == .mouseAnswered && failures < Self.maxAttempts
            && now - lastFailureAt >= Self.recheckInterval
    }

    /// A change of mind is a fresh start: what failed before is tried again at once.
    mutating func setWanted(_ wanted: Bool) {
        self.wanted = wanted
        failures = 0
        lastFailureAt = nil
    }

    /// Another connection to the mouse, or none: nothing verified on the last one holds.
    mutating func connectionChanged() {
        verifiedAt = nil
        failures = 0
        lastFailureAt = nil
    }

    /// The Mac woke, or the mouse came back: it may have lost the mode, and deserves a try.
    mutating func doubtful() { connectionChanged() }

    /// A write of driver mode is about to go out, or a read found the mouse in it.
    mutating func mayHaveSet() { maybeSet = true }

    mutating func engaged(at now: TimeInterval) {
        verifiedAt = now
        failures = 0
        lastFailureAt = nil
        maybeSet = true
    }

    mutating func restored() {
        verifiedAt = nil
        failures = 0
        lastFailureAt = nil
        maybeSet = false
    }

    mutating func failed(at now: TimeInterval) {
        verifiedAt = nil
        failures += 1
        lastFailureAt = now
    }

    /// What the page shows after `step` has run. While the change is under way it's
    /// `engaging`, which `MouseController` publishes itself.
    func state(lastError: String?) -> DpiDriverModeState {
        guard wanted else { return .off }
        if verifiedAt != nil { return .engaged }
        if failures > 0, let lastError { return .unavailable(lastError) }
        return .off
    }
}
