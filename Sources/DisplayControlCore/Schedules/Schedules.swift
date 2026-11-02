import Foundation

// MARK: - Model

public enum Trigger: Codable, Equatable, Sendable {
    case time(hour: Int, minute: Int, weekdays: Set<Int>)       // weekdays 1...7 (Sunday = 1); empty = every day
    case sunrise(offsetMinutes: Int)
    case sunset(offsetMinutes: Int)
    case wake
    case lock
    case unlock
    case appLaunch
    case appearanceDark
    case appearanceLight
    case powerPlugged
    case powerBattery
    case monitorConnected(identityKey: String?)
    case monitorDisconnected(identityKey: String?)

    /// Triggers that need a computed timer rather than a system notification.
    public var isTimed: Bool {
        switch self { case .time, .sunrise, .sunset: return true; default: return false }
    }
}

public struct Schedule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: Trigger
    public var presetID: UUID
    /// Optional preset applied when the condition ends (for example unplugged vs plugged in).
    public var endPresetID: UUID?

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, trigger: Trigger, presetID: UUID, endPresetID: UUID? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.trigger = trigger
        self.presetID = presetID; self.endPresetID = endPresetID
    }
}

struct ScheduleFile: Codable { var version: Int = 1; var schedules: [Schedule]; var latitude: Double?; var longitude: Double? }

public struct GeoPoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

public final class ScheduleStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var items: [Schedule]
    private var geo: GeoPoint?

    public init(url: URL = Paths.schedulesFile) {
        self.url = url
        let f = AtomicJSON.read(ScheduleFile.self, from: url)
        items = f?.schedules ?? []
        if let la = f?.latitude, let lo = f?.longitude { geo = GeoPoint(latitude: la, longitude: lo) }
    }

    public var all: [Schedule] { lock.withLock { items } }
    public var location: GeoPoint? { lock.withLock { geo } }

    public func setLocation(_ g: GeoPoint?) throws { try lock.withLock { geo = g; try persist() } }

    public func upsert(_ s: Schedule) throws {
        try lock.withLock {
            if let i = items.firstIndex(where: { $0.id == s.id }) { items[i] = s } else { items.append(s) }
            try persist()
        }
    }

    public func delete(id: UUID) throws { try lock.withLock { items.removeAll { $0.id == id }; try persist() } }

    public func setEnabled(_ id: UUID, _ on: Bool) throws {
        try lock.withLock {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].enabled = on
            try persist()
        }
    }

    /// Matches a full id or a unique prefix of one (the CLI allows prefixes).
    public func find(_ query: String) -> Schedule? {
        let q = query.lowercased()
        return lock.withLock {
            items.first { $0.id.uuidString.lowercased() == q }
                ?? { let m = items.filter { $0.id.uuidString.lowercased().hasPrefix(q) }; return m.count == 1 ? m[0] : nil }()
                ?? items.first { $0.name.lowercased() == q }
        }
    }

    private func persist() throws {
        try AtomicJSON.write(ScheduleFile(schedules: items, latitude: geo?.latitude, longitude: geo?.longitude), to: url)
    }
}

// MARK: - Solar calculation (NOAA / "sunrise equation")

public enum SolarCalculator {
    /// Sunrise and sunset for the civil date of `date` in `calendar`'s time zone.
    /// Returns nil during polar day or polar night.
    public static func sunTimes(on date: Date, at geo: GeoPoint, calendar: Calendar = .current) -> (sunrise: Date, sunset: Date)? {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // The day number below is defined for a Julian date taken at 00:00 UTC of the civil date;
        // using noon would land on the next day number.
        guard let midnightUTC = utc.date(from: DateComponents(year: comps.year, month: comps.month, day: comps.day)) else { return nil }
        let jd = midnightUTC.timeIntervalSince1970 / 86400.0 + 2440587.5

        let rad = Double.pi / 180
        let n = (jd - 2451545.0 + 0.0008).rounded(.up)
        let jStar = n - geo.longitude / 360.0
        let m = (357.5291 + 0.98560028 * jStar).truncatingRemainder(dividingBy: 360)
        let mr = m * rad
        let c = 1.9148 * sin(mr) + 0.0200 * sin(2 * mr) + 0.0003 * sin(3 * mr)
        let lambda = (m + c + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let lr = lambda * rad
        let jTransit = 2451545.0 + jStar + 0.0053 * sin(mr) - 0.0069 * sin(2 * lr)
        let sinDec = sin(lr) * sin(23.4397 * rad)
        let cosDec = cos(asin(sinDec))
        let phi = geo.latitude * rad
        let cosOmega = (sin(-0.833 * rad) - sin(phi) * sinDec) / (cos(phi) * cosDec)
        guard cosOmega >= -1, cosOmega <= 1 else { return nil }
        let omega = acos(cosOmega) / rad
        func toDate(_ j: Double) -> Date { Date(timeIntervalSince1970: (j - 2440587.5) * 86400.0) }
        return (toDate(jTransit - omega / 360.0), toDate(jTransit + omega / 360.0))
    }
}

// MARK: - Next fire time

public enum NextFire {
    /// The next time a timed trigger should fire strictly after `after`, or nil for event triggers.
    public static func date(for trigger: Trigger, after: Date, calendar: Calendar = .current, location: GeoPoint?) -> Date? {
        switch trigger {
        case .time(let h, let m, let weekdays):
            return nextTime(hour: h, minute: m, weekdays: weekdays, after: after, calendar: calendar)
        case .sunrise(let off):
            return nextSun(rising: true, offset: off, after: after, calendar: calendar, location: location)
        case .sunset(let off):
            return nextSun(rising: false, offset: off, after: after, calendar: calendar, location: location)
        default:
            return nil
        }
    }

    static func nextTime(hour: Int, minute: Int, weekdays: Set<Int>, after: Date, calendar: Calendar) -> Date? {
        let days = weekdays.isEmpty ? [nil] : weekdays.sorted().map { Optional($0) }
        var best: Date?
        for wd in days {
            var dc = DateComponents(hour: hour, minute: minute, second: 0)
            if let wd { dc.weekday = wd }
            if let d = calendar.nextDate(after: after, matching: dc, matchingPolicy: .nextTime), best == nil || d < best! { best = d }
        }
        return best
    }

    static func nextSun(rising: Bool, offset: Int, after: Date, calendar: Calendar, location: GeoPoint?) -> Date? {
        guard let loc = location else { return nil }
        // Look up to a year ahead so polar regions eventually find a valid day.
        for dayOffset in 0..<370 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: after),
                  let t = SolarCalculator.sunTimes(on: day, at: loc, calendar: calendar) else { continue }
            let fire = (rising ? t.sunrise : t.sunset).addingTimeInterval(TimeInterval(offset * 60))
            if fire > after { return fire }
        }
        return nil
    }

    /// Spec F45: when the Mac slept through a time-based schedule, returns the most recent missed
    /// fire time within `window` before `now`, or nil.
    public static func missedFire(for trigger: Trigger, since lastCheck: Date, now: Date, window: TimeInterval = 7200,
                                  calendar: Calendar = .current, location: GeoPoint?) -> Date? {
        guard trigger.isTimed, now > lastCheck else { return nil }
        var cursor = lastCheck
        var latest: Date?
        // Bounded loop: at most a few fires can lie between two checks.
        for _ in 0..<16 {
            guard let d = date(for: trigger, after: cursor, calendar: calendar, location: location), d <= now else { break }
            latest = d
            cursor = d
        }
        guard let l = latest, now.timeIntervalSince(l) <= window else { return nil }
        return l
    }
}
