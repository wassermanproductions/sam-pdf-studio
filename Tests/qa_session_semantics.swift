// Standalone check for DocumentSession version-stack semantics.
// Compiled and run by script/qa.sh (XCTest is unavailable without full Xcode):
//   swiftc Sources/SamPDFStudio/Models/DocumentSession.swift Tests/qa_session_semantics.swift -o <tmp>/qa_session && <tmp>/qa_session
import Foundation

@main
struct QASessionSemantics {
    static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("ok   \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    static func contents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
    }

    static func commitNext(_ session: DocumentSession, _ text: String) throws -> URL {
        let url = session.nextVersionURL()
        try Data(text.utf8).write(to: url)
        session.commit(url)
        return url
    }

    static func main() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let originalURL = workDir.appendingPathComponent("original.pdf")
        try Data("v0".utf8).write(to: originalURL)

        // Initial state
        do {
            let session = try DocumentSession(originalURL: originalURL)
            check(!session.canUndo && !session.canRedo && !session.isDirty, "initial state is clean")
            check(contents(session.currentURL) == "v0", "initial version matches original")
            session.cleanup()
        }

        // Traversal
        do {
            let session = try DocumentSession(originalURL: originalURL)
            _ = try commitNext(session, "v1")
            _ = try commitNext(session, "v2")
            check(session.isDirty && session.canUndo && !session.canRedo, "state after two commits")
            _ = session.undo()
            check(contents(session.currentURL) == "v1" && session.canRedo, "undo lands on v1")
            _ = session.undo()
            check(contents(session.currentURL) == "v0" && !session.canUndo && !session.isDirty, "undo to clean v0")
            _ = session.redo()
            check(contents(session.currentURL) == "v1", "redo lands on v1")
            session.cleanup()
        }

        // Branch after undo: redo truncated, filenames never reused
        do {
            let session = try DocumentSession(originalURL: originalURL)
            let v1 = try commitNext(session, "v1")
            let v2 = try commitNext(session, "v2")
            _ = session.undo()
            let branched = try commitNext(session, "branched")
            check(!session.canRedo, "redo history truncated after branch")
            check(contents(session.currentURL) == "branched", "branch is current")
            check(branched.path != v1.path && branched.path != v2.path, "branch file does not collide with live versions")
            _ = session.undo()
            check(contents(session.currentURL) == "v1", "undo from branch lands on intact v1")
            _ = session.redo()
            _ = session.undo()
            let second = try commitNext(session, "second")
            check(second.path != branched.path, "second branch gets a fresh filename")
            check(contents(session.currentURL) == "second", "second branch is current")
            session.cleanup()
        }

        // Save semantics
        do {
            let session = try DocumentSession(originalURL: originalURL)
            _ = try commitNext(session, "edited")
            try session.saveToOriginal()
            check(!session.isDirty, "clean after save")
            check(contents(originalURL) == "edited", "save wrote current bytes to original")
            _ = session.undo()
            check(session.isDirty, "dirty after undo below save point")
            _ = session.redo()
            check(!session.isDirty, "clean after redo back to saved version")
            session.cleanup()
            try Data("v0".utf8).write(to: originalURL)
        }

        // Truncating past the save point can never become clean again
        do {
            let session = try DocumentSession(originalURL: originalURL)
            _ = try commitNext(session, "v1")
            _ = try commitNext(session, "v2")
            try session.saveToOriginal()
            _ = session.undo()
            _ = try commitNext(session, "branched")
            check(session.isDirty, "dirty after branching away from saved version")
            _ = session.undo()
            check(session.isDirty, "still dirty anywhere in history once saved version is dropped")
            session.cleanup()
            try Data("v0".utf8).write(to: originalURL)
        }

        if failures > 0 {
            print("session semantics: \(failures) FAILURES")
            exit(1)
        }
        print("session semantics ok")
    }
}
