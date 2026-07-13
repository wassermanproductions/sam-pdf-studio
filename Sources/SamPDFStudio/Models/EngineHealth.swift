import Foundation

struct EngineHealth: Decodable {
    let ok: Bool
    let engine: String
    let python: String
    let packages: [String: ToolStatus]
    let binaries: [String: ToolStatus]

    var readyCount: Int {
        packages.values.filter(\.ok).count + binaries.values.filter(\.ok).count
    }

    var missingItems: [String] {
        let packageNames = packages.filter { !$0.value.ok }.map(\.key)
        let binaryNames = binaries.filter { !$0.value.ok }.map(\.key)
        return packageNames + binaryNames
    }
}

struct ToolStatus: Decodable {
    let ok: Bool
    let version: String?
    let path: String?
    let error: String?
}
