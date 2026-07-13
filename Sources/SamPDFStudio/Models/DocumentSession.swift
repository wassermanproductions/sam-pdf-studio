import Foundation

/// Tracks the version history for one open document.
///
/// Every mutating operation writes the result to a new version file inside a
/// private session directory (outside iCloud-synced folders), so Undo/Redo is
/// a matter of stepping through version files. The user's original file is
/// only touched by an explicit Save.
final class DocumentSession {
    let originalURL: URL
    private let directory: URL
    private var versions: [URL]
    private var index: Int
    private var savedIndex: Int
    /// Monotonic counter so version filenames are never reused, even after
    /// undo truncates the redo tail (a reused name would overwrite a file
    /// that is still referenced as the current or an undoable version).
    private var versionCounter: Int = 0

    var currentURL: URL { versions[index] }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < versions.count - 1 }
    var isDirty: Bool { index != savedIndex }

    init(originalURL: URL) throws {
        self.originalURL = originalURL

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SamPDFStudio/sessions", isDirectory: true)
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let v0 = directory.appendingPathComponent("v0.pdf")
        try FileManager.default.copyItem(at: originalURL, to: v0)
        versions = [v0]
        index = 0
        savedIndex = 0
    }

    /// Path the next operation should write its result to.
    func nextVersionURL() -> URL {
        directory.appendingPathComponent("v\(versionCounter + 1).pdf")
    }

    /// Record a completed operation's output as the new current version.
    func commit(_ url: URL) {
        if index < versions.count - 1 {
            let dropped = versions[(index + 1)...]
            versions.removeSubrange((index + 1)...)
            for stale in dropped where stale != url {
                try? FileManager.default.removeItem(at: stale)
            }
            if savedIndex > index {
                savedIndex = -1
            }
        }
        versions.append(url)
        index = versions.count - 1
        versionCounter += 1
    }

    func undo() -> URL? {
        guard canUndo else { return nil }
        index -= 1
        return versions[index]
    }

    func redo() -> URL? {
        guard canRedo else { return nil }
        index += 1
        return versions[index]
    }

    /// Overwrite the original file with the current version.
    func saveToOriginal() throws {
        let data = try Data(contentsOf: currentURL)
        try data.write(to: originalURL, options: .atomic)
        savedIndex = index
    }

    func markSaved() {
        savedIndex = index
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
