import Foundation
import IOKit.ps

/// Pure scheduling rules, kept separate from I/O so they can be tested.
public enum Policy {
    /// Minutes to wait after a failed scheduled attempt before trying again.
    public static let retryAfterFailureMinutes = 15

    public static func isBackupDue(lastBackup: Date?, now: Date, intervalMinutes: Int, lastFailure: Date? = nil) -> Bool {
        if let failure = lastFailure, now.timeIntervalSince(failure) < TimeInterval(retryAfterFailureMinutes * 60) {
            return false
        }
        guard let last = lastBackup else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(max(intervalMinutes, 5) * 60)
    }

    public static func isVerificationDue(last: VerificationSummary?, now: Date, everyDays: Int) -> Bool {
        guard everyDays > 0 else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last.date) >= TimeInterval(everyDays * 86_400)
    }

    public enum Staleness: Equatable, Sendable {
        case fresh
        case neverBackedUp
        case stale(days: Int)
    }

    /// With rotating disks, a Mac counts as protected when any disk has a recent backup.
    public static func staleness(disks: [KnownDisk], now: Date, remindAfterDays: Int) -> Staleness {
        guard !disks.isEmpty else { return .fresh }
        guard let newest = disks.compactMap(\.lastBackup).max() else { return .neverBackedUp }
        let days = Int(now.timeIntervalSince(newest) / 86_400)
        return days >= remindAfterDays ? .stale(days: days) : .fresh
    }

    /// Disks that were not backed up for much longer than the newest one. Useful for rotation reminders.
    public static func neglectedDisks(disks: [KnownDisk], now: Date, afterDays: Int) -> [KnownDisk] {
        guard disks.count > 1 else { return [] }
        return disks.filter { d in
            guard let last = d.lastBackup else { return false }
            return now.timeIntervalSince(last) >= TimeInterval(afterDays * 86_400)
        }
    }

    public static func canRunOnPower(onBattery: Bool, percent: Int?, pauseOnLowBattery: Bool) -> Bool {
        guard pauseOnLowBattery, onBattery else { return true }
        return (percent ?? 100) >= 20
    }

    public static func shouldReminder(now: Date, lastReminder: Date?) -> Bool {
        guard let last = lastReminder else { return true }
        return now.timeIntervalSince(last) >= 86_400
    }
}

public enum PowerState {
    public static func current() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (false, nil)
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                let onBattery = state == kIOPSBatteryPowerValue
                return (onBattery, desc[kIOPSCurrentCapacityKey] as? Int)
            }
        }
        return (false, nil)
    }
}
