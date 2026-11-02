import Foundation
import os

/// Shared loggers. Subsystem and categories follow the spec (section 5.11).
public enum Log {
    public static let subsystem = "app.displaycontrol"
    public static let ddc = Logger(subsystem: subsystem, category: "ddc")
    public static let registry = Logger(subsystem: subsystem, category: "registry")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let schedule = Logger(subsystem: subsystem, category: "schedule")
    public static let keys = Logger(subsystem: subsystem, category: "keys")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
}

/// Filesystem locations used by the app and the CLI.
public enum Paths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DisplayControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
    /// `sun_path` holds about 104 bytes; fall back to a short per-user path in the temp directory when needed.
    public static var socketPath: String {
        let preferred = supportDirectory.appendingPathComponent("control.sock").path
        if preferred.utf8.count < 100 { return preferred }
        return "/tmp/displaycontrol-\(getuid()).sock"
    }
    public static var presetsFile: URL { supportDirectory.appendingPathComponent("presets.json") }
    public static var schedulesFile: URL { supportDirectory.appendingPathComponent("schedules.json") }
    public static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var displaysFile: URL { supportDirectory.appendingPathComponent("displays.json") }
}

/// Maps between user-facing percentages (0...100) and a device's raw range (0...max).
public enum ValueMapper {
    /// Percent to raw. Always clamped to `0...max`.
    public static func raw(fromPercent percent: Int, max: Int) -> Int {
        guard max > 0 else { return 0 }
        let p = Swift.min(100, Swift.max(0, percent))
        return Int((Double(p) * Double(max) / 100.0).rounded())
    }

    /// Raw to percent, clamped to `0...100`.
    public static func percent(fromRaw raw: Int, max: Int) -> Int {
        guard max > 0 else { return 0 }
        let r = Swift.min(max, Swift.max(0, raw))
        return Int((Double(r) * 100.0 / Double(max)).rounded())
    }

    public static func clampPercent(_ v: Int) -> Int { Swift.min(100, Swift.max(0, v)) }
}

/// Atomic JSON persistence with a one-generation backup (spec 5.7).
public enum AtomicJSON {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(value)
        let fm = FileManager.default
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // Settings, presets and schedules are private to this user: owner read and write only.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bak.path)
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads `url`; if it is missing or corrupt, falls back to the `.bak` copy.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for candidate in [url, url.appendingPathExtension("bak")] {
            if let data = try? Data(contentsOf: candidate), let v = try? dec.decode(T.self, from: data) {
                return v
            }
        }
        return nil
    }
}

/// Trailing-edge debouncer. Cheap: one pending task, no timers when idle.
public final class Debouncer: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let delay: Duration

    public init(delay: Duration) { self.delay = delay }

    public func call(_ action: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        let d = delay
        task = Task {
            try? await Task.sleep(for: d)
            if Task.isCancelled { return }
            await action()
        }
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel(); task = nil
    }
}
