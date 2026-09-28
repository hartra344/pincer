import Foundation

/// Session groups.
extension DemoGateway {
    func handleGroups(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        switch method {
        case "sessions.groups.list":
            return self.groupCatalog()
        case "sessions.groups.put":
            return try self.putGroups(params)
        case "sessions.groups.rename":
            return try self.renameGroup(params)
        case "sessions.groups.delete":
            return try self.deleteGroup(params)
        default:
            return nil
        }
    }

    // MARK: Groups

    func groupCatalog(_ extra: Row = [:]) -> JSONValue {
        var result: Row = [
            "groups": .array(self.groups.enumerated().map { ["name": .string($1), "position": JSONValue($0)] }),
            "sectionOrder": [],
        ]
        result.merge(extra) { $1 }
        return .object(result)
    }

    func registerGroup(_ name: String?) {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !self.groups.contains(name) else { return }
        self.groups.append(name)
    }

    func groupsChanged() {
        guard self.sessionsSubscribed else { return }
        self.emit("sessions.changed", ["reason": "groups"])
    }

    func moveMembers(of name: String, to category: JSONValue) -> Int {
        let keys = self.sessions.filter { $0.value["category"]?.string == name }.map(\.key)
        for key in keys {
            self.sessions[key]?["category"] = category
            self.sessionChanged(key, reason: "patch")
        }
        return keys.count
    }

    func putGroups(_ params: JSONValue) throws -> JSONValue {
        guard let raw = params["names"]?.array else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "names required", details: nil)
        }
        var names: [String] = []
        for name in raw.compactMap(\.string).map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        let dropped = self.groups.filter { name in !names.contains(name) && self.sessions.values.contains { $0["category"]?.string == name } }
        guard dropped.isEmpty else {
            throw GatewayError.rpc(code: "INVALID_REQUEST",
                                   message: "sessions.groups.put cannot drop groups that still have member sessions", details: nil)
        }
        self.groups = names
        self.groupsChanged()
        return self.groupCatalog(["ok": true])
    }

    func renameGroup(_ params: JSONValue) throws -> JSONValue {
        guard let from = params["name"]?.string?.trimmingCharacters(in: .whitespaces), !from.isEmpty,
              let to = params["to"]?.string?.trimmingCharacters(in: .whitespaces), !to.isEmpty
        else { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "group rename requires non-empty names", details: nil) }
        guard self.groups.contains(from) else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown session group: \(from)", details: nil)
        }
        let updated = from == to ? 0 : self.moveMembers(of: from, to: .string(to))
        if from != to, self.groups.contains(to) {
            self.groups.removeAll { $0 == from }
        } else {
            self.groups = self.groups.map { $0 == from ? to : $0 }
        }
        self.groupsChanged()
        return self.groupCatalog(["ok": true, "updatedSessions": JSONValue(updated)])
    }

    func deleteGroup(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "group delete requires a non-empty name", details: nil)
        }
        let updated = self.moveMembers(of: name, to: .null)
        self.groups.removeAll { $0 == name }
        self.groupsChanged()
        return self.groupCatalog(["ok": true, "updatedSessions": JSONValue(updated)])
    }
}
