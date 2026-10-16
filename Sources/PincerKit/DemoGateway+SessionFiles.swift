import CryptoKit
import Foundation

/// One file of the demo workspace.
struct DemoSessionFile: Sendable {
    var path: String
    var kind: String // "modified" | "read"
    var text: String?
    var imageBase64: String?
    var binary = false
    /// Reported size for files too large to carry (the demo doesn't store the bytes).
    var declaredSize: Int?
    var missing = false
    var updatedAtMs: Double
    var readOnly = false

    var name: String { (path as NSString).lastPathComponent }
    var size: Int { self.declaredSize ?? self.text?.utf8.count ?? (self.imageBase64.map { $0.count * 3 / 4 } ?? 0) }
    var hash: String? {
        guard let text, self.declaredSize == nil, !self.readOnly else { return nil }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The demo's `sessions.files.list/get/set` and `artifacts.list`, in the shape upstream replies with
/// (src/gateway/server-methods/sessions-files.ts): a seeded workspace with changed, read and deleted files,
/// a nested tree, an image, an over-256 KiB file and a file that conflicts on its first save.
extension DemoGateway {
    static let sessionFilesMethods = ["sessions.files.list", "sessions.files.get", "sessions.files.set", "artifacts.list"]
    static let demoWorkspaceRoot = "/home/demo/workspace/japan-trip"
    /// The first `sessions.files.set` of this file finds it already changed by someone else.
    static let demoConflictPath = "docs/conflict-demo.md"
    static let demoOversizedPath = "data/photos-index.json"
    static let demoPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    static func seedSessionFiles() -> [String: DemoSessionFile] {
        let now = Date().timeIntervalSince1970 * 1000
        func file(_ path: String, _ kind: String, _ text: String? = nil, agoMin: Double, _ tweak: (inout DemoSessionFile) -> Void = { _ in }) -> DemoSessionFile {
            var item = DemoSessionFile(path: path, kind: kind, text: text, updatedAtMs: now - agoMin * 60_000)
            tweak(&item)
            return item
        }
        let all = [
            file("itinerary.md", "modified", "# Japan trip\n\n- Day 1: Arrive in Tokyo\n- Day 2: Kyoto by Shinkansen\n- Day 3: Fushimi Inari at sunrise\n", agoMin: 4),
            file("docs/packing.md", "modified", "# Packing\n\n- [ ] Passport\n- [ ] Rail pass\n- [x] Adapter\n", agoMin: 12),
            file(Self.demoConflictPath, "modified", "# Notes\n\nEdit this, then save: the gateway version will have changed.\n", agoMin: 30),
            file("src/budget.py", "modified", "def total(days, per_day):\n    return days * per_day\n", agoMin: 55),
            file("docs/old-plan.md", "modified", agoMin: 90) { $0.missing = true },
            file("README.md", "read", "# Japan trip workspace\n\nNotes, itineraries and budgets.\n", agoMin: 200) { $0.readOnly = false },
            file("data/bookings.csv", "read", "city,nights\nTokyo,3\nKyoto,4\n", agoMin: 240),
            file("data/map.png", "read", agoMin: 300) { $0.imageBase64 = Self.demoPNG },
            file("data/archive.zip", "read", agoMin: 400) { $0.binary = true; $0.declaredSize = 48_213 },
            file(Self.demoOversizedPath, "read", agoMin: 500) { $0.declaredSize = 3 * 1024 * 1024 },
            file("scripts/build.sh", "read", "#!/bin/sh\necho build\n", agoMin: 600),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.path, $0) })
    }

    /// Changes `path` as if another client wrote it, so the next `sessions.files.set` conflicts. Test and demo hook.
    func simulateExternalFileEdit(path: String) {
        guard var item = self.demoSessionFiles[path], let text = item.text else { return }
        item.text = text + "\n(Edited elsewhere.)\n"
        item.updatedAtMs = Date().timeIntervalSince1970 * 1000
        self.demoSessionFiles[path] = item
    }

    func handleSessionFiles(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "sessions.files.list": return self.sessionFilesList(params)
        case "sessions.files.get": return try self.sessionFilesGet(params)
        case "sessions.files.set": return try self.sessionFilesSet(params)
        case "artifacts.list": return self.demoArtifacts(params)
        default: return nil
        }
    }

    private func fileJSON(_ item: DemoSessionFile, includeContent: Bool) -> JSONValue {
        var row: [String: JSONValue] = [
            "path": .string(item.path), "workspacePath": .string("\(Self.demoWorkspaceRoot)/\(item.path)"),
            "name": .string(item.name), "kind": .string(item.kind), "missing": .bool(item.missing),
            "updatedAtMs": .number(item.updatedAtMs),
        ]
        if !item.missing { row["size"] = .number(Double(item.size)) }
        guard includeContent, !item.missing else { return .object(row) }
        if item.binary {
            row["previewKind"] = "unsupported"
            row["mimeType"] = "application/zip"
        } else if item.declaredSize != nil {
            // Over the 256 KiB cap: no content, no previewKind (upstream then answers `get` with session_file_too_large).
        } else if let image = item.imageBase64 {
            row["previewKind"] = "image"
            row["mimeType"] = "image/png"
            row["contentEncoding"] = "base64"
            row["content"] = .string(image)
        } else if let text = item.text {
            row["previewKind"] = "text"
            row["contentEncoding"] = "utf8"
            row["content"] = .string(text)
            if let hash = item.hash { row["hash"] = .string(hash) }
        }
        return .object(row)
    }

    private func sessionFilesList(_ params: JSONValue) -> JSONValue {
        let key = params["sessionKey"]?.string ?? ""
        let search = (params["search"]?.string ?? "").lowercased()
        let path = params["path"]?.string ?? ""
        let sorted = self.demoSessionFiles.values.sorted {
            ($0.kind == "modified" ? 0 : 1, $0.path) < ($1.kind == "modified" ? 0 : 1, $1.path)
        }
        let files = sorted.filter { search.isEmpty || $0.path.lowercased().contains(search) }
        var entries: [JSONValue] = []
        if search.isEmpty {
            let prefix = path.isEmpty ? "" : path + "/"
            var folders = Set<String>()
            for item in sorted where item.path.hasPrefix(prefix) {
                let rest = item.path.dropFirst(prefix.count)
                if let slash = rest.firstIndex(of: "/") {
                    folders.insert(String(rest[..<slash]))
                } else {
                    entries.append(["path": .string(item.path), "name": .string(item.name), "kind": "file",
                                    "sessionKind": .string(item.kind), "size": .number(Double(item.size))])
                }
            }
            let dirs: [JSONValue] = folders.sorted().map {
                ["path": .string(prefix + $0), "name": .string($0), "kind": "directory", "sessionKind": "mixed"]
            }
            entries = dirs + entries
        } else {
            entries = files.map {
                ["path": .string($0.path), "name": .string($0.name), "kind": "file", "sessionKind": .string($0.kind)]
            }
        }
        var browser: [String: JSONValue] = ["path": .string(path), "entries": .array(entries)]
        if !path.isEmpty { browser["parentPath"] = .string((path as NSString).deletingLastPathComponent) }
        if !search.isEmpty { browser["search"] = .string(search) }
        return ["sessionKey": .string(key), "root": .string(Self.demoWorkspaceRoot), "gitCheckout": true,
                "files": .array(files.map { self.fileJSON($0, includeContent: false) }), "browser": .object(browser)]
    }

    private func sessionFilesGet(_ params: JSONValue) throws -> JSONValue {
        let key = params["sessionKey"]?.string ?? ""
        guard let path = params["path"]?.string, let item = self.demoSessionFiles[path] else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "session file not found",
                                   details: ["type": "session_file_not_found", "path": .string(params["path"]?.string ?? "")])
        }
        if item.declaredSize != nil, !item.binary {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "session file is too large to preview",
                                   details: ["type": "session_file_too_large", "maxPreviewBytes": .number(Double(256 * 1024)),
                                             "path": .string(path), "size": .number(Double(item.size))])
        }
        if item.missing {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "session file not found",
                                   details: ["type": "session_file_not_found", "path": .string(path)])
        }
        return ["sessionKey": .string(key), "root": .string(Self.demoWorkspaceRoot),
                "file": self.fileJSON(item, includeContent: true)]
    }

    private func sessionFilesSet(_ params: JSONValue) throws -> JSONValue {
        let key = params["sessionKey"]?.string ?? ""
        guard let path = params["path"]?.string, var item = self.demoSessionFiles[path], !item.missing,
              let content = params["content"]?.string, let expected = params["expectedHash"]?.string else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "session file not found",
                                   details: ["type": "session_file_not_found", "path": .string(params["path"]?.string ?? "")])
        }
        if content.utf8.count > 256 * 1024 {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "session file is too large to write",
                                   details: ["type": "session_file_too_large", "maxPreviewBytes": .number(Double(256 * 1024)),
                                             "path": .string(path), "size": .number(Double(content.utf8.count))])
        }
        if content.contains("\u{0}") {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "session file could not be written safely",
                                   details: ["type": "session_file_unsafe", "path": .string(path)])
        }
        if path == Self.demoConflictPath, !self.demoConflictTriggered {
            self.demoConflictTriggered = true
            self.simulateExternalFileEdit(path: path)
            item = self.demoSessionFiles[path] ?? item
        }
        guard let current = item.hash, current == expected else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "session file changed since it was read",
                                   details: ["type": "session_file_conflict", "path": .string(path),
                                             "currentHash": .string(item.hash ?? "")])
        }
        item.text = content
        item.kind = "modified"
        item.updatedAtMs = Date().timeIntervalSince1970 * 1000
        self.demoSessionFiles[path] = item
        return ["sessionKey": .string(key), "root": .string(Self.demoWorkspaceRoot),
                "file": self.fileJSON(item, includeContent: true)]
    }

    private func demoArtifacts(_ params: JSONValue) -> JSONValue {
        let key = params["sessionKey"]?.string ?? ""
        return ["artifacts": [
            ["id": "demo-artifact-map", "type": "image", "title": "Kyoto route map", "mimeType": "image/png",
             "sizeBytes": 68, "sessionKey": .string(key), "download": ["mode": "bytes"]],
            ["id": "demo-artifact-itinerary", "type": "file", "title": "itinerary.pdf", "mimeType": "application/pdf",
             "sizeBytes": 18_240, "sessionKey": .string(key), "download": ["mode": "bytes"]],
        ]]
    }
}
