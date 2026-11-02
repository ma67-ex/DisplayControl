import Testing
import Foundation
@testable import DisplayControlCore

/// The app promises that nothing leaves the device. These tests keep that promise from eroding by accident.
@Suite struct OfflineTests {
    static let sources: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    static func swiftFiles() -> [URL] {
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    @Test func sourceContainsNoNetworkingCode() throws {
        let banned = ["URLSession", "URLRequest", "NWConnection", "NWListener", "NWPathMonitor", "CFSocket", "CFStream", "AF_INET",
                      "WKWebView", "NSURLConnection", "import Network", "SCNetworkReachability"]
        let files = Self.swiftFiles()
        #expect(files.count > 20)                                              // the scan really found the code
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for word in banned { #expect(!text.contains(word), "\(f.lastPathComponent) mentions \(word)") }
        }
    }

    @Test func onlyLocalUnixSocketsAreOpened() throws {
        for f in Self.swiftFiles() {
            for line in try String(contentsOf: f, encoding: .utf8).split(separator: "\n") where line.contains("socket(") && !line.contains("//") {
                #expect(line.contains("AF_UNIX"), "\(f.lastPathComponent): \(line)")
            }
        }
    }

    @Test func savedFilesAreReadableOnlyByTheOwner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("x.json")
        try AtomicJSON.write(["a": 1], to: url)
        try AtomicJSON.write(["a": 2], to: url)                                // second write also makes the backup
        for u in [url, url.appendingPathExtension("bak")] {
            let mode = (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            #expect(mode == 0o600, "\(u.lastPathComponent) mode is \(String(mode, radix: 8))")
        }
    }

    @Test func controlSocketIsOwnerOnly() throws {
        let path = "/tmp/dc-off-\(UUID().uuidString.prefix(8)).sock"
        let server = IPCServer(path: path) { _ in .success() }
        try server.start()
        defer { server.stop() }
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & 0o777 == 0o600)
    }
}
