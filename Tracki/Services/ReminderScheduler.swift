import Foundation

/// How often to interrupt with a flyby while a timer is running.
enum ReminderInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case hour = 60

    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var seconds: Int { rawValue * 60 }

    var label: String {
        switch self {
        case .off: return "Off"
        case .hour: return "Every hour"
        default: return "Every \(minutes) min"
        }
    }

    /// Falls back to `.off` for any unrecognised stored value.
    static func stored(_ raw: Int) -> ReminderInterval {
        ReminderInterval(rawValue: raw) ?? .off
    }
}

/// Decides *when* a running timer should fire a reminder, in elapsed-seconds terms.
///
/// Deliberately holds no wall-clock state of its own — `TimerViewModel.tick()` already
/// recomputes elapsed time from the entry's start date every second, so this stays correct
/// across app restarts and machine sleep without a second source of truth.
@MainActor
final class ReminderScheduler {
    /// Elapsed-seconds mark at which the next reminder is due. `nil` = not armed.
    private var nextFireAt: Int?

    /// Call when a run begins, is adopted from Toggl, or is restored after a restart.
    func rearm(elapsedSeconds: Int, interval: ReminderInterval) {
        guard interval != .off else {
            nextFireAt = nil
            return
        }
        // Align to the next whole interval boundary so adopting a 2h-old entry doesn't fire
        // immediately — it waits for the next round milestone.
        let periods = elapsedSeconds / interval.seconds
        nextFireAt = (periods + 1) * interval.seconds
    }

    func disarm() {
        nextFireAt = nil
    }

    /// Returns the elapsed minutes to announce when a reminder is due, else `nil`.
    /// Safe to call every tick.
    func fireIfDue(elapsedSeconds: Int, interval: ReminderInterval) -> Int? {
        guard interval != .off else { return nil }

        guard let due = nextFireAt else {
            // Armed lazily — e.g. the user switched the interval on mid-run.
            rearm(elapsedSeconds: elapsedSeconds, interval: interval)
            return nil
        }
        guard elapsedSeconds >= due else { return nil }

        // Coalesce anything missed while the machine slept into a single alert, then
        // re-align to the current interval (it may have changed since we armed).
        var next = due
        while next <= elapsedSeconds { next += interval.seconds }
        nextFireAt = next

        return elapsedSeconds / 60
    }
}
