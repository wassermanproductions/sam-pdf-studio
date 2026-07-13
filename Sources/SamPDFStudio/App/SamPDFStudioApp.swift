import AppKit
import SwiftUI

@main
struct SamPDFStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Sam PDF Studio") {
            ContentView()
                .environmentObject(appDelegate.store)
                .frame(minWidth: 1000, minHeight: 660)
                .navigationTitle(appDelegate.store.documentName)
        }
        .commands {
            AppCommands(store: appDelegate.store)
        }
    }
}

private struct AppCommands: Commands {
    @ObservedObject var store: AppStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…") {
                store.openPDF()
            }
            .keyboardShortcut("o")
            .disabled(store.busy)

            Button("New from Images…") {
                store.newFromImages()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(store.busy)

            Button("Merge PDFs…") {
                store.mergePDFFiles()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(store.busy)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                store.save()
            }
            .keyboardShortcut("s")
            .disabled(!store.isDirty || store.busy)

            Button("Save As…") {
                store.saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(store.document == nil || store.busy)

            Button("Export PDF Copy…") {
                store.exportPDFCopy()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(store.document == nil || store.busy)

            Divider()

            Button("Set Password…") {
                store.showPasswordSheet = true
            }
            .disabled(store.document == nil || store.busy)

            Menu("Reduce File Size") {
                Button("Small File (screen quality)") { store.reduceFileSize(quality: "small") }
                Button("Balanced (good quality)") { store.reduceFileSize(quality: "medium") }
                Button("High Quality (print)") { store.reduceFileSize(quality: "high") }
            }
            .disabled(store.document == nil || store.busy)

            Divider()

            Button("Revert to Original") {
                store.revertToOriginal()
            }
            .disabled(store.document == nil || !store.isDirty || store.busy)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                store.undo()
            }
            .keyboardShortcut("z")
            .disabled(!store.canUndo || store.busy)

            Button("Redo") {
                store.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!store.canRedo || store.busy)
        }

        CommandMenu("Go") {
            ForEach(Array(PDFOperation.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) {
                    store.selectedOperation = mode
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(store.document == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = AppStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.handleTermination() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
