import Foundation
import CoreGraphics

public struct SelfTestStep: Codable, Equatable, Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String
}

public struct SelfTestReport: Codable, Equatable, Sendable {
    public var display: String
    public var mode: ControlMode
    public var steps: [SelfTestStep]
    public var medianRoundTripMs: Double?
    public var needsDoubleWrite: Bool?
    public var passed: Bool { steps.allSatisfy(\.passed) }
}

/// Executes IPC commands against the display center. The CLI, the socket server and the MCP server
/// all go through here so behaviour is identical everywhere.
public struct CommandRouter: Sendable {
    public let center: DisplayCenter
    public var appVersion: String
    public var onRefresh: (@Sendable () async -> Void)?

    public init(center: DisplayCenter, appVersion: String = "1.0.0", onRefresh: (@Sendable () async -> Void)? = nil) {
        self.center = center; self.appVersion = appVersion; self.onRefresh = onRefresh
    }

    public func handle(_ req: IPCRequest) async -> IPCResponse {
        do {
            return try await route(req)
        } catch let e as CenterError {
            switch e {
            case .displayNotFound, .presetNotFound: return .failure(e.description, code: ExitCode.notFound)
            case .ambiguous, .invalidValue: return .failure(e.description, code: ExitCode.usage)
            case .unsupported: return .failure(e.description, code: ExitCode.refused)
            }
        } catch {
            return .failure(String(describing: error), code: ExitCode.refused)
        }
    }

    // MARK: Routing

    private func route(_ req: IPCRequest) async throws -> IPCResponse {
        let a = req.args
        switch req.cmd {
        case "version":
            return .success(.object(["app": .string(appVersion), "protocol": .int(IPC.version)]))

        case "status", "list":
            await center.refreshAll()
            return .success(.from(await center.snapshots()))

        case "get":
            let d = try await display(a)
            await d.refreshCore()
            var out: [String: JSONValue] = [:]
            let wanted = a["props"].flatMap { v -> [String]? in if case .array(let arr) = v { return arr.compactMap(\.stringValue) } else { return nil } } ?? []
            for p in DisplayProperty.allCases where await d.supported.contains(p) {
                if !wanted.isEmpty && !wanted.contains(p.rawValue) { continue }
                if let v = await d.refresh(p) { out[p.rawValue] = .int(v) }
            }
            if !wanted.isEmpty, out.isEmpty {
                throw CenterError.unsupported(await d.info.name, DisplayProperty(rawValue: wanted[0]) ?? .brightness)
            }
            return .success(.object(out))

        case "set":
            return try await handleSet(a)

        case "preset.list":
            return .success(.from(center.presets.all.map { $0.name }))

        case "preset.activate":
            guard let name = a["name"]?.stringValue else { throw CenterError.invalidValue("A preset name is required") }
            let results = try await center.activatePreset(name, delay: a["delay"]?.intValue.map(Double.init))
            return presetResponse(results)

        case "schedule.list":
            return .success(.from(center.schedules.all.map { ScheduleInfo(id: $0.id.uuidString, name: $0.name, enabled: $0.enabled, trigger: "\($0.trigger)") }))

        case "schedule.enable", "schedule.disable":
            guard let q = a["id"]?.stringValue, let s = center.schedules.find(q) else { throw CenterError.displayNotFound(a["id"]?.stringValue ?? "schedule") }
            try center.schedules.setEnabled(s.id, req.cmd == "schedule.enable")
            return .success(.string(s.name))

        case "sync.status":
            return .success(.from(await center.sync))

        case "sync.enable":
            let d = try await display(a)
            await center.setSync(enabled: true, hostKey: await d.key)
            return .success(.string(await d.info.name))

        case "sync.disable":
            await center.setSync(enabled: false, hostKey: nil)
            return .success(.null)

        case "reset-gamma":
            CGDisplayRestoreColorSyncSettings()
            await center.reapplySoftwareDimming()
            return .success(.null)

        case "selftest":
            let d = try await display(a)
            return .success(.from(await SelfTest.run(d)))

        case "mode":
            let d = try await display(a)
            let text = a["mode"]?.stringValue?.lowercased() ?? ""
            let mode: ControlMode?
            switch text {
            case "auto", "automatic", "": mode = nil
            default:
                guard let m = ControlMode(rawValue: text) else { throw CenterError.invalidValue("Mode must be auto, ddc, apple or software") }
                mode = m
            }
            try await center.setMode(key: await d.key, mode)
            return .success(.string(await d.mode.rawValue))

        case "redetect":
            let d = try await display(a)
            let ok = await center.redetect(key: await d.key)
            return .success(.bool(ok))

        case "refresh":
            await center.reload()
            await onRefresh?()
            return .success(.null)

        default:
            return .failure("Unknown command \"\(req.cmd)\"", code: ExitCode.usage)
        }
    }

    struct ScheduleInfo: Codable { var id: String; var name: String; var enabled: Bool; var trigger: String }

    private func display(_ a: [String: JSONValue]) async throws -> ManagedDisplay {
        if let i = a["index"]?.intValue { return try await center.resolve("#\(i)") }
        if let u = a["uuid"]?.stringValue { return try await center.resolve(u) }
        if let n = a["display"]?.stringValue, !n.isEmpty { return try await center.resolve(n) }
        // With exactly one display, the name is optional.
        let all = await center.allDisplays
        if all.count == 1 { return all[0] }
        throw CenterError.invalidValue("Specify a display by name, --index or --uuid")
    }

    private func handleSet(_ a: [String: JSONValue]) async throws -> IPCResponse {
        guard case .object(let props)? = a["props"], !props.isEmpty else { throw CenterError.invalidValue("Nothing to set") }
        var changes: [(DisplayProperty, Int)] = []
        for (k, v) in props {
            guard let p = DisplayProperty(rawValue: k) else { throw CenterError.invalidValue("Unknown property \"\(k)\"") }
            let value: Int?
            switch p {
            case .input: value = v.intValue ?? v.stringValue.flatMap(InputSource.parse)
            case .power, .mute: value = v.boolValue.map { $0 ? 1 : 0 } ?? v.intValue
            case .rotation:
                value = v.intValue
                if let r = value, ![0, 90, 180, 270].contains(r) { throw CenterError.invalidValue("Rotation must be 0, 90, 180 or 270") }
            default:
                value = v.intValue
                if let n = value, !(0...100).contains(n) { throw CenterError.invalidValue("\(k) must be between 0 and 100") }
            }
            guard let value else { throw CenterError.invalidValue("Invalid value for \(k)") }
            changes.append((p, value))
        }

        if a["all"]?.boolValue == true {
            var failures: [String: JSONValue] = [:]
            var applied = 0
            for (p, v) in changes {
                let errs = await center.setAll(p, to: v)
                for (k, m) in errs { failures[k] = .string(m) }
                applied += await center.allDisplays.count - errs.count
            }
            if applied == 0 && !failures.isEmpty { return .failure("No display accepted the change", code: ExitCode.refused) }
            return failures.isEmpty ? .success(.null) : IPCResponse(ok: true, data: .object(failures), error: "Some displays were skipped", code: ExitCode.partial)
        }

        let d = try await display(a)
        for (p, v) in changes { try await center.set(d, p, to: v) }
        return .success(.null)
    }

    private func presetResponse(_ results: [ApplyResult]) -> IPCResponse {
        let s = PresetApplier.summary(results)
        let data: JSONValue = .object(["applied": .int(s.applied), "skipped": .int(s.skipped), "failed": .int(s.failed)])
        if s.failed > 0 || s.skipped > 0 {
            return IPCResponse(ok: true, data: data, error: s.failed > 0 ? "\(s.failed) item(s) failed" : "\(s.skipped) item(s) skipped (display not connected)", code: ExitCode.partial)
        }
        return .success(data)
    }
}
