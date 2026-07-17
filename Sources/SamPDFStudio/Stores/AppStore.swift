import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

private struct PDFRegionClipboard {
    let sourceURL: URL
    let page: Int
    let rect: String
    let text: String
}

/// Lets the thumbnail sidebar drive the real canvas PDFView.
final class PDFViewProxy {
    weak var pdfView: PDFView?
}

struct PendingNote: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let pdfKitPoint: CGPoint
    /// When set, the note attaches to this text selection instead of a pin.
    var selection: PDFSelection?
}

/// A colored span within a block's text. Offsets index the FULL block text
/// (the same string as `originalText`/the edited text; each newline counts as
/// one character). Lets a Text Color pick recolor just the selected words
/// instead of the whole block. Later runs win over earlier ones on overlap.
struct ColorRun: Codable, Equatable {
    var start: Int
    var length: Int
    var hex: String
}

/// A paragraph block being edited in place.
struct ActiveTextBlock: Equatable {
    let page: Int              // 1-based
    let engineRect: CGRect     // top-origin page coordinates
    /// Document revision this block was read from. A commit or move against
    /// any other revision targets stale content and must be dropped.
    let revision: Int
    /// Unique per click. Distinguishes a fresh selection of the same block
    /// from a SwiftUI re-render of the old one, and lets commit/cancel/move
    /// callbacks target exactly the selection they were opened for.
    let selectionID: Int
    let originalText: String
    let fontName: String
    let lineHeight: Double
    let originalFontSize: Double
    let originalColorHex: String
    let originalBold: Bool
    let originalItalic: Bool
    var fontSize: Double
    var colorHex: String
    var bold: Bool
    var italic: Bool
    /// Underline the block's text (default false; true means changed).
    var underline: Bool
    /// Text alignment: "left" (default), "center", or "right".
    var alignment: String
    /// Explicit font family the user picked (nil = keep the original font).
    var fontFamily: String?
    /// Shading drawn behind the block (nil = leave background untouched).
    /// Committed together with the text edit so color + background persist.
    var backgroundHex: String?
    /// Per-selection text-color spans over sub-ranges of the block's text
    /// (empty = the whole block uses `colorHex`). Survives the async commit
    /// hop via the per-selectionID snapshot, like every other style field.
    var colorRuns: [ColorRun] = []

    var styleChanged: Bool {
        fontSize != originalFontSize || colorHex != originalColorHex
            || bold != originalBold || italic != originalItalic
            || underline || alignment != "left"
            || fontFamily != nil || backgroundHex != nil
            || !colorRuns.isEmpty
    }

    var engineRectString: String {
        "\(engineRect.minX),\(engineRect.minY),\(engineRect.maxX),\(engineRect.maxY)"
    }
}

/// A blank text box the user is typing into on empty page space (Edit > Text,
/// cursor mode). Commits render fresh text at exactly (engineX, engineY).
struct NewTextDraft: Equatable {
    let page: Int              // 1-based
    let engineX: Double        // top-origin page point where the click landed
    let engineY: Double
    /// Unique per click (see ActiveTextBlock.selectionID) — lets commit/cancel
    /// callbacks target exactly the draft they were opened for.
    let selectionID: Int
    var fontName: String = "Helvetica"
    var fontSize: Double = 12
    var colorHex: String = "#000000"
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var alignment: String = "left"
}

struct PendingLink: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let pdfKitRect: CGRect
}

struct PendingRedlineReplace: Identifiable {
    let id = UUID()
    let page: Int
    let rects: String
}

/// First-launch state of the bundled Python engine. A distributed .app that
/// has never run the dev build has no venv yet, so the app self-installs it on
/// first launch and blocks the UI behind an overlay while that runs.
enum EngineSetupState: Equatable {
    case ready
    case installing
    case failed(String)
}

/// Carries the installer's failure output up to `bootstrapEngineIfNeeded`.
struct EngineSetupFailure: Error {
    let message: String
}

final class AppStore: ObservableObject {
    /// Drives the first-launch engine-install overlay in ContentView.
    @Published var engineSetup: EngineSetupState = .ready

    @Published var selectedOperation: PDFOperation = .read {
        didSet {
            if selectedOperation == .edit && oldValue != .edit {
                selectedEditTool = .contentText
            }
            if selectedOperation != oldValue {
                clearCanvasSelection()
            }
        }
    }
    @Published var selectedAnnotateTool: AnnotateTool = .highlight {
        didSet { clearCanvasSelection() }
    }
    @Published var selectedEditTool: EditTool = .contentText {
        didSet {
            clearCanvasSelection()
            prefetchBlocksForVisiblePage()
        }
    }
    @Published var selectedFillSignTool: FillSignTool = .text {
        didSet { clearCanvasSelection() }
    }
    @Published var selectedRedlineTool: RedlineTool = .strikeout {
        didSet { clearCanvasSelection() }
    }

    @Published var document: PDFDocument?
    @Published var pageCount: Int = 0
    /// Bumped on every document mutation so views re-render even when the
    /// PDFDocument instance is mutated in place (reorder, rotate, annotate).
    @Published var documentRevision: Int = 0
    @Published var isDirty: Bool = false
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false

    @Published var busy: Bool = false
    @Published var busyTitle: String = ""
    @Published var lastMessage: String = ""
    @Published var errorMessage: String?
    @Published var showSidebar: Bool = true
    @Published var recentFiles: [URL] = []

    // Canvas selection state (engine coordinates).
    @Published var selectedPDFText: String = "" {
        didSet {
            guard selectedOperation == .edit else { return }
            let selected = normalizedSelectedPDFText()
            guard !selected.isEmpty else { return }
            switch selectedEditTool {
            case .contentText:
                findText = selected
            case .redact:
                redactFindText = selected
            case .grab, .image, .link:
                break
            }
        }
    }
    @Published var selectedPDFPage: Int = 1
    @Published var selectedPDFRect: String = "" {
        didSet { prefetchGuidesForGrabRegion() }
    }
    @Published var hasCopiedRegion: Bool = false

    // Tool inputs.
    @Published var findText: String = ""
    @Published var redactFindText: String = ""
    @Published var activeBlock: ActiveTextBlock? {
        didSet {
            // Preserve the latest style for this selection so a commit that
            // fires AFTER activeBlock is niled or replaced (click-away,
            // clicking another paragraph) still applies the panel's edits.
            if let block = activeBlock {
                // Keyed by selectionID: clicking a DIFFERENT paragraph opens a
                // new selection and would otherwise overwrite a single slot
                // before the previous paragraph's async commit reads it —
                // silently dropping its style edits (Sam's "works in some areas,
                // not others"). Per-selection storage survives that.
                blockStyleBySelection[block.selectionID] = BlockStyleSnapshot(
                    selectionID: block.selectionID, fontSize: block.fontSize,
                    colorHex: block.colorHex, bold: block.bold,
                    italic: block.italic, underline: block.underline,
                    alignment: block.alignment,
                    fontFamily: block.fontFamily, backgroundHex: block.backgroundHex,
                    colorRuns: block.colorRuns
                )
                pruneStyleSnapshots(&blockStyleBySelection, keep: block.selectionID)
            } else {
                // Editor closed: a stale per-word selection must not leak into
                // the next block's Text Color taps.
                activeBlockSelection = nil
                activeBlockTextLength = 0
            }
        }
    }
    /// A blank text box being typed on empty page space (cursor mode click).
    @Published var newTextDraft: NewTextDraft? {
        didSet {
            if let draft = newTextDraft {
                draftStyleBySelection[draft.selectionID] = DraftStyleSnapshot(
                    selectionID: draft.selectionID, fontName: draft.fontName,
                    fontSize: draft.fontSize, colorHex: draft.colorHex, bold: draft.bold,
                    italic: draft.italic, underline: draft.underline, alignment: draft.alignment
                )
                pruneStyleSnapshots(&draftStyleBySelection, keep: draft.selectionID)
            }
        }
    }
    /// Style snapshots keyed by selectionID, surviving activeBlock/draft
    /// being cleared OR replaced by a new selection before the async commit reads them.
    private struct BlockStyleSnapshot { let selectionID: Int; let fontSize: Double; let colorHex: String; let bold: Bool; let italic: Bool; let underline: Bool; let alignment: String; let fontFamily: String?; let backgroundHex: String?; let colorRuns: [ColorRun] }
    private struct DraftStyleSnapshot { let selectionID: Int; let fontName: String; let fontSize: Double; let colorHex: String; let bold: Bool; let italic: Bool; let underline: Bool; let alignment: String }
    private var blockStyleBySelection: [Int: BlockStyleSnapshot] = [:]
    private var draftStyleBySelection: [Int: DraftStyleSnapshot] = [:]
    /// Keep only the most recent handful of snapshots so the maps don't grow.
    private func pruneStyleSnapshots<T>(_ map: inout [Int: T], keep: Int) {
        guard map.count > 8 else { return }
        for key in map.keys.sorted().prefix(map.count - 8) where key != keep {
            map[key] = nil
        }
    }
    /// Other blocks on the active page (engine coords) — alignment guide
    /// candidates while dragging the active block.
    @Published var activeBlockGuides: [CGRect] = []
    /// The open block editor's current text selection, bridged up from AppKit
    /// (the selection lives in the NSTextView). Offsets index the FULL block
    /// text. nil/empty means nothing is selected. Not @Published: it is read
    /// imperatively when a Text Color swatch is tapped, and republishing it on
    /// every caret move would churn the whole workspace.
    var activeBlockSelection: NSRange?
    /// Length of the editor's current text — lets a "select all" be treated as
    /// a whole-block recolor rather than a run.
    var activeBlockTextLength: Int = 0
    @Published var pendingImageURL: URL?
    @Published var pendingNote: PendingNote?
    @Published var pendingNoteText: String = ""
    @Published var pendingLink: PendingLink?
    @Published var pendingLinkURLText: String = ""
    @Published var pendingRedlineReplace: PendingRedlineReplace?
    @Published var pendingRedlineReplaceText: String = ""
    @Published var signatureText: String {
        didSet { UserDefaults.standard.set(signatureText, forKey: "signatureText") }
    }
    /// The saved signature PNG stamped when the Sign tool clicks a page.
    /// nil means the user must create/pick one first (opens the manager).
    @Published var activeSignatureURL: URL? {
        didSet { UserDefaults.standard.set(activeSignatureURL?.path, forKey: "activeSignaturePath") }
    }
    /// Drives the Signature Manager sheet (draw / type-cursive / saved gallery).
    @Published var showSignatureManager: Bool = false
    /// Markup color for highlight/underline/strikeout ("" = tool default).
    @Published var markupColorHex: String = ""
    /// Edit > Text interaction: false = cursor (click types), true = hand
    /// (click selects, drag moves).
    @Published var blockMoveMode: Bool = false {
        didSet { clearCanvasSelection() }
    }
    /// Track Changes: block edits leave a review mark with the original text.
    @Published var trackChanges: Bool {
        didSet { UserDefaults.standard.set(trackChanges, forKey: "trackChanges") }
    }

    // Pages mode.
    @Published var selectedPageIndices: Set<Int> = []

    // OCR mode.
    @Published var ocrLanguage: String = "eng"
    @Published var forceOCR: Bool = false
    @Published var enhanceGrayscale: Bool = true
    @Published var enhanceDenoise: Bool = true
    @Published var enhanceContrast: Double = 1.35
    @Published var enhanceSharpness: Double = 1.15

    /// Common fonts pinned at the top of the font pickers (friendly names the
    /// engine maps to base-14 aliases or system TTFs).
    static let newTextFontChoices = ["Helvetica", "Times New Roman", "Courier New", "Arial", "Georgia", "Verdana"]

    /// Every font family installed on the system, sorted — the full list the
    /// font pickers scroll through below the pinned common fonts.
    static let allFontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    let engine = PDFEngineClient()
    let pdfViewProxy = PDFViewProxy()
    private var blockSelectionCounter = 0
    private(set) var session: DocumentSession?
    private var regionClipboard: PDFRegionClipboard?

    var currentPDFURL: URL? { session?.currentURL }
    var documentName: String { session?.originalURL.lastPathComponent ?? "Sam PDF Studio" }

    init() {
        signatureText = UserDefaults.standard.string(forKey: "signatureText") ?? "Sam Wasserman"
        if let path = UserDefaults.standard.string(forKey: "activeSignaturePath"),
           FileManager.default.fileExists(atPath: path) {
            activeSignatureURL = URL(fileURLWithPath: path)
        }
        trackChanges = UserDefaults.standard.bool(forKey: "trackChanges")
        recentFiles = Self.loadRecents()
        Self.purgeStaleSessions()

        // Show the install overlay from the very first frame if the engine venv
        // isn't there yet, so a fresh .app never flashes a broken UI before the
        // real check + install kick off in bootstrapEngineIfNeeded().
        let venvPython = PDFEngineClient.defaultVenvURL.appendingPathComponent("bin/python3")
        if !FileManager.default.isExecutableFile(atPath: venvPython.path) {
            engineSetup = .installing
        }
    }

    // MARK: - First-launch engine setup

    /// Path to the bundled first-run installer (shown in the manual-fallback
    /// message and used to run the install). Falls back to the repo copy when
    /// running unbundled (dev builds via `swift run`).
    var engineSetupScriptPath: String {
        Bundle.main.url(forResource: "setup-engine", withExtension: "sh")?.path
            ?? engine.projectRoot.appendingPathComponent("script/setup-engine.sh").path
    }

    /// On launch, make sure the Python engine venv exists and can import the
    /// core PDF stack. If not (fresh install), run the bundled setup-engine.sh
    /// on a background queue and drive `engineSetup` so the UI can block behind
    /// an overlay until it's ready.
    func bootstrapEngineIfNeeded() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if self.engineCoreReady() {
                DispatchQueue.main.async { self.engineSetup = .ready }
                return
            }
            DispatchQueue.main.async { self.engineSetup = .installing }
            let result = self.runEngineSetupScript()
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.engineSetup = .ready
                case .failure(let failure):
                    self.engineSetup = .failed(failure.message)
                }
            }
        }
    }

    /// True when the venv python exists and can import the core PDF stack
    /// (fitz + pypdf). OCR and optional conversions are intentionally ignored —
    /// their absence must not force a reinstall on every launch.
    private func engineCoreReady() -> Bool {
        let venvPython = PDFEngineClient.defaultVenvURL.appendingPathComponent("bin/python3")
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else { return false }
        let process = Process()
        process.executableURL = venvPython
        process.arguments = ["-c", "import fitz, pypdf"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Run the bundled setup-engine.sh, pointing it at the app's bundled engine
    /// script + requirements. Returns the trimmed installer output on failure.
    private func runEngineSetupScript() -> Result<Void, EngineSetupFailure> {
        let bundle = Bundle.main
        guard let scriptURL = bundle.url(forResource: "setup-engine", withExtension: "sh")
            ?? existingURL(engine.projectRoot.appendingPathComponent("script/setup-engine.sh")) else {
            return .failure(EngineSetupFailure(message: "Could not find setup-engine.sh in the app bundle."))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        // Run from a neutral, never-TCC-protected directory (see run() in
        // PDFEngineClient) so the install never hangs on a folder prompt.
        let neutralCWD = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SamPDFStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: neutralCWD, withIntermediateDirectories: true)
        process.currentDirectoryURL = neutralCWD

        var environment = ProcessInfo.processInfo.environment
        if let engineScript = bundle.url(forResource: "pdf_engine", withExtension: "py")
            ?? existingURL(engine.projectRoot.appendingPathComponent("Engine/pdf_engine.py")) {
            environment["SAMPDF_ENGINE_SCRIPT"] = engineScript.path
        }
        if let requirements = bundle.url(forResource: "requirements", withExtension: "txt")
            ?? existingURL(engine.projectRoot.appendingPathComponent("Engine/requirements.txt")) {
            environment["SAMPDF_REQUIREMENTS"] = requirements.path
        }
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", existingPath].joined(separator: ":")
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(EngineSetupFailure(message: "Could not start the engine installer: \(error.localizedDescription)"))
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let combined = [String(data: outData, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? ""]
                .joined(separator: "\n")
            // Surface the last few lines — the actionable part of the failure.
            let tail = combined
                .split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(6)
                .joined(separator: "\n")
            let message = tail.isEmpty ? "The engine installer exited with an error." : tail
            return .failure(EngineSetupFailure(message: message))
        }
        return .success(())
    }

    private func existingURL(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Remove session directories left behind by previous runs.
    private static func purgeStaleSessions() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SamPDFStudio/sessions", isDirectory: true)
        guard let leftovers = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for url in leftovers {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Called from the app delegate when the user quits.
    func handleTermination() -> Bool {
        guard confirmDiscardIfDirty() else { return false }
        session?.cleanup()
        return true
    }

    // MARK: - Open / Save

    func openPDF() {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPDF(url)
    }

    func loadPDF(_ url: URL, checkDirty: Bool = false) {
        if checkDirty && !confirmDiscardIfDirty() { return }
        // Surface macOS folder-permission denials clearly: recents from
        // Desktop/Documents/Downloads fail if the (re-signed) app hasn't been
        // granted folder access yet.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            errorMessage = """
            macOS is blocking access to \(url.lastPathComponent).
            Reopen it with Open PDF… or drag it into the window once — \
            or allow Desktop/Documents access for Sam PDF Studio in \
            System Settings → Privacy & Security → Files & Folders.
            """
            return
        }
        do {
            session?.cleanup()
            let newSession = try DocumentSession(originalURL: url)
            session = newSession
            document = PDFDocument(url: newSession.currentURL)
            pageCount = document?.pageCount ?? 0
            selectedEditTool = .contentText
            selectedPageIndices = []
            documentRevision += 1
            clearCanvasSelection()
            refreshHistoryState()
            addRecent(url)
            toast("Opened \(url.lastPathComponent)")
        } catch {
            report(error, while: "Opening PDF")
        }
    }

    func loadDroppedPDFProviders(_ providers: [NSItemProvider]) -> Bool {
        let acceptedTypes = [UTType.fileURL.identifier, UTType.url.identifier]
        guard let provider = providers.first(where: { item in
            acceptedTypes.contains(where: item.hasItemConformingToTypeIdentifier)
        }) else {
            toast("Drop a PDF file")
            return false
        }
        let typeIdentifier = acceptedTypes.first(where: provider.hasItemConformingToTypeIdentifier) ?? UTType.fileURL.identifier
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.toast("Drop failed: \(error.localizedDescription)")
                    return
                }
                guard let url = Self.url(fromDroppedItem: item), self.isPDFURL(url) else {
                    self.toast("Drop a PDF file")
                    return
                }
                self.loadPDF(url, checkDirty: true)
            }
        }
        return true
    }

    func save() {
        guard let session, !busy else { return }
        // A freshly merged document has no real home yet — pick one.
        if isStagedMergeDocument {
            saveAs()
            return
        }
        flushDocumentIfNeeded()
        do {
            try session.saveToOriginal()
            refreshHistoryState()
            toast("Saved \(session.originalURL.lastPathComponent)")
            applyPendingPassword(to: session.originalURL)
        } catch {
            report(error, while: "Saving")
        }
    }

    func saveAs() {
        guard let session, let document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = session.originalURL.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        flushDocumentIfNeeded()
        if document.write(to: url) {
            applyPendingPassword(to: url)
            loadPDF(url)
        } else {
            toast("Could not save to \(url.lastPathComponent)")
        }
    }

    func revertToOriginal() {
        guard let session else { return }
        let url = session.originalURL
        guard confirm("Revert to the last saved version of \(url.lastPathComponent)?", button: "Revert") else { return }
        loadPDF(url)
    }

    // MARK: - Undo / Redo

    func undo() {
        guard !busy else { return }
        guard let session, let url = session.undo() else { return }
        let position = captureScrollPosition()
        document = PDFDocument(url: url)
        pageCount = document?.pageCount ?? 0
        documentRevision += 1
        selectedPageIndices = []
        clearCanvasSelection()
        refreshHistoryState()
        restoreScrollPosition(position)
        toast("Undo")
    }

    func redo() {
        guard !busy else { return }
        guard let session, let url = session.redo() else { return }
        let position = captureScrollPosition()
        document = PDFDocument(url: url)
        pageCount = document?.pageCount ?? 0
        documentRevision += 1
        selectedPageIndices = []
        clearCanvasSelection()
        refreshHistoryState()
        restoreScrollPosition(position)
        toast("Redo")
    }

    // MARK: - Scroll preservation across document swaps

    /// (page index, top-left point on that page) the user is looking at.
    private func captureScrollPosition() -> (pageIndex: Int, point: NSPoint)? {
        guard let pdfView = pdfViewProxy.pdfView,
              let destination = pdfView.currentDestination,
              let page = destination.page,
              let doc = pdfView.document else { return nil }
        return (doc.index(for: page), destination.point)
    }

    /// Return the view to the same page and offset after the document swap.
    private func restoreScrollPosition(_ position: (pageIndex: Int, point: NSPoint)?) {
        guard let position else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let pdfView = self.pdfViewProxy.pdfView,
                  let doc = pdfView.document else { return }
            let index = min(position.pageIndex, doc.pageCount - 1)
            guard index >= 0, let page = doc.page(at: index) else { return }
            let destination = PDFDestination(page: page, at: position.point)
            pdfView.go(to: destination)
        }
    }

    // MARK: - Annotate (instant, PDFKit)

    func applyMarkup(_ selection: PDFSelection, kind: AnnotationKind) {
        guard selectedOperation == .annotate else { return }
        guard document != nil else { return }
        let subtype: PDFAnnotationSubtype
        let color: NSColor
        switch kind {
        case .highlight:
            subtype = .highlight
            color = NSColor.systemYellow
        case .underline:
            subtype = .underline
            color = NSColor.systemBlue
        case .strikeout:
            subtype = .strikeOut
            color = NSColor.systemRed
        }

        let chosenColor = NSColor(engineHex: markupColorHex) ?? color
        var annotated = false
        for lineSelection in selection.selectionsByLine() {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.color = chosenColor
                page.addAnnotation(annotation)
                annotated = true
            }
        }
        guard annotated else { return }
        commitDocumentChange(title: kind.title)
    }

    func placeNote(pageIndex: Int, pdfKitPoint: CGPoint) {
        guard selectedAnnotateTool == .note || selectedRedlineTool == .note else { return }
        guard selectedOperation == .annotate || selectedOperation == .redline else { return }
        pendingNoteText = ""
        pendingNote = PendingNote(pageIndex: pageIndex, pdfKitPoint: pdfKitPoint)
    }

    /// Note attached to a text selection — highlights the passage and hangs
    /// the note on it (click the highlight to read it).
    func noteOnSelection(_ selection: PDFSelection) {
        guard selectedOperation == .annotate, selectedAnnotateTool == .note else { return }
        guard let page = selection.pages.first, let document else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }
        pendingNoteText = ""
        pendingNote = PendingNote(pageIndex: pageIndex, pdfKitPoint: .zero, selection: selection)
    }

    func commitPendingNote() {
        guard let pending = pendingNote, let document,
              let page = document.page(at: pending.pageIndex) else {
            pendingNote = nil
            return
        }
        let text = pendingNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingNote = nil
        guard !text.isEmpty else { return }

        if let selection = pending.selection {
            // Attached note: soft highlight over the passage carrying the note.
            var annotated = false
            for line in selection.selectionsByLine() {
                guard let linePage = line.pages.first, linePage === page else { continue }
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.85)
                annotation.contents = text
                page.addAnnotation(annotation)
                annotated = true
            }
            guard annotated else { return }
            commitDocumentChange(title: "Note on Selection")
            return
        }

        let bounds = CGRect(x: pending.pdfKitPoint.x - 11, y: pending.pdfKitPoint.y - 11, width: 22, height: 22)
        let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        annotation.contents = text
        annotation.color = .systemYellow
        annotation.iconType = .note
        page.addAnnotation(annotation)
        commitDocumentChange(title: "Note")
    }
    /// Apply a Text Color pick to the active block. When a non-empty sub-range
    /// (that is NOT the entire text) is selected in the editor, only that range
    /// changes — recorded as a `ColorRun` and previewed live over the editor's
    /// text. Otherwise this falls back to today's whole-block recolor.
    func applyBlockTextColor(_ hex: String) {
        guard activeBlock != nil else { return }
        if let range = activeBlockSelection,
           range.length > 0,
           !(range.location == 0 && range.length >= activeBlockTextLength) {
            // Newer run appended last so it wins on any overlap; the engine
            // and the live preview both apply runs in order.
            activeBlock?.colorRuns.append(
                ColorRun(start: range.location, length: range.length, hex: hex)
            )
        } else {
            activeBlock?.colorHex = hex
        }
    }

    /// Change the active block's font family from the style panel.
    func setActiveBlockFont(_ family: String?) {
        editorLog.info("setActiveBlockFont \(family ?? "nil") activeBlock=\(self.activeBlock != nil)")
        activeBlock?.fontFamily = family
    }

    // Background shading is now committed together with the text edit via
    // `backgroundHex` on ActiveTextBlock, so text color and background both
    // persist. (Was a standalone op that discarded pending text-color edits.)

    func addTextBox(pageIndex: Int, pdfKitPoint: CGPoint, text: String, fontSize: CGFloat = 14) {
        guard let document, let page = document.page(at: pageIndex) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: fontSize)
        let size = (trimmed as NSString).size(withAttributes: [.font: font])
        let bounds = CGRect(
            x: pdfKitPoint.x,
            y: pdfKitPoint.y - size.height,
            width: min(size.width + 10, page.bounds(for: .cropBox).width - pdfKitPoint.x),
            height: size.height + 6
        )
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = trimmed
        annotation.font = font
        annotation.fontColor = .black
        annotation.color = .clear
        annotation.backgroundColor = .clear
        page.addAnnotation(annotation)
        commitDocumentChange(title: "Text Box")
    }

    func linkRegionSelected(pageIndex: Int, pdfKitRect: CGRect) {
        guard selectedOperation == .edit, selectedEditTool == .link else { return }
        pendingLinkURLText = "https://"
        pendingLink = PendingLink(pageIndex: pageIndex, pdfKitRect: pdfKitRect)
    }

    func commitPendingLink() {
        guard let pending = pendingLink, let document,
              let page = document.page(at: pending.pageIndex) else {
            pendingLink = nil
            return
        }
        let raw = pendingLinkURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingLink = nil
        guard let url = URL(string: raw), url.scheme != nil else {
            toast("Enter a full link address (https://…)")
            return
        }
        let annotation = PDFAnnotation(bounds: pending.pdfKitRect, forType: .link, withProperties: nil)
        annotation.url = url
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        page.addAnnotation(annotation)
        commitDocumentChange(title: "Link")
    }

    /// Commit an in-place annotation change (moved or deleted in Edit mode) as
    /// a new document version, so it walks Undo/Redo and persists on Save.
    /// The moved/removed annotation already lives on the in-memory document, so
    /// this just snapshots the current state.
    func annotationEdited(title: String) {
        guard document != nil else { return }
        commitDocumentChange(title: title)
    }

    // MARK: - Fill & Sign (engine)

    func fillSignClick(page: Int, x: Double, y: Double) {
        guard selectedOperation == .fillSign else { return }
        switch selectedFillSignTool {
        case .check, .cross, .dot:
            let kind = selectedFillSignTool == .check ? "check" : (selectedFillSignTool == .cross ? "cross" : "dot")
            runEngineOp(title: selectedFillSignTool.title) { [engine] input, output in
                _ = try engine.addSymbol(input: input, output: output, page: page, kind: kind, x: x, y: y - 12, size: 16)
            }
        case .date:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            let today = formatter.string(from: Date())
            runEngineOp(title: "Date") { [engine] input, output in
                _ = try engine.addText(input: input, output: output, page: page, x: x, y: y - 10, text: today, fontSize: 11)
            }
        case .signature:
            placeSignature(page: page, x: x, y: y)
        case .text:
            break // handled by the inline text editor in the canvas
        }
    }

    // MARK: - Redline (engine review marks)

    func applyRedline(_ selection: PDFSelection) {
        guard selectedOperation == .redline else { return }
        guard let target = engineLineRects(for: selection) else { return }
        switch selectedRedlineTool {
        case .strikeout, .squiggly:
            let kind = selectedRedlineTool == .strikeout ? "strikeout" : "squiggly"
            runEngineOp(title: selectedRedlineTool.title) { [engine] input, output in
                _ = try engine.redline(input: input, output: output, page: target.page, kind: kind, rects: target.rects)
            }
        case .replace:
            pendingRedlineReplaceText = ""
            pendingRedlineReplace = PendingRedlineReplace(page: target.page, rects: target.rects)
        case .insert, .note:
            break
        }
    }

    func redlineCaret(page: Int, x: Double, y: Double) {
        guard selectedOperation == .redline, selectedRedlineTool == .insert else { return }
        runEngineOp(title: "Insert Mark") { [engine] input, output in
            _ = try engine.redline(input: input, output: output, page: page, kind: "caret", x: x, y: y)
        }
    }

    func commitRedlineReplace() {
        guard let pending = pendingRedlineReplace else { return }
        let note = pendingRedlineReplaceText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingRedlineReplace = nil
        guard !note.isEmpty else { return }
        runEngineOp(title: "Replace Mark") { [engine] input, output in
            _ = try engine.redline(input: input, output: output, page: pending.page, kind: "replace", rects: pending.rects, note: note)
        }
    }

    /// Selection line rects in engine coordinates ("x0,y0,x1,y1;…").
    private func engineLineRects(for selection: PDFSelection) -> (page: Int, rects: String)? {
        guard let page = selection.pages.first, let document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        let bounds = page.bounds(for: .cropBox)
        var parts: [String] = []
        for line in selection.selectionsByLine() {
            guard let linePage = line.pages.first, linePage === page else { continue }
            let rect = line.bounds(for: page)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let x0 = rect.minX - bounds.minX
            let x1 = rect.maxX - bounds.minX
            let y0 = bounds.maxY - rect.maxY
            let y1 = bounds.maxY - rect.minY
            parts.append("\(x0),\(y0),\(x1),\(y1)")
        }
        guard !parts.isEmpty else { return nil }
        return (pageIndex + 1, parts.joined(separator: ";"))
    }

    // MARK: - Signature / Image placement (engine)

    func placeSignature(page: Int, x: Double, y: Double) {
        let fromAnnotate = selectedOperation == .annotate && selectedAnnotateTool == .signature
        let fromFillSign = selectedOperation == .fillSign && selectedFillSignTool == .signature
        guard fromAnnotate || fromFillSign else { return }
        // A saved signature is a transparent PNG stamped like an image; if none
        // exists yet, open the manager so the user can draw or type one first.
        guard let url = activeSignatureURL, FileManager.default.fileExists(atPath: url.path) else {
            showSignatureManager = true
            toast("Create or pick a signature, then click the page")
            return
        }
        stampSignatureImage(url, page: page, x: x, y: y)
    }

    /// Stamp the active signature PNG at the click, ~40pt tall, width by aspect
    /// ratio, transparent background so only the ink lands over the content.
    private func stampSignatureImage(_ url: URL, page: Int, x: Double, y: Double) {
        let targetHeight = 40.0
        var width = 120.0
        if let image = NSImage(contentsOf: url), image.size.height > 0 {
            let aspect = image.size.width / image.size.height
            width = max(24.0, (targetHeight * aspect).rounded())
        }
        runEngineOp(title: "Sign") { [engine] input, output in
            _ = try engine.addImage(
                input: input, output: output, image: url,
                page: page, x: x, y: y, width: width, height: targetHeight
            )
        }
    }

    // MARK: Saved signatures (Application Support)

    /// Where signature PNGs live — App Support (outside iCloud/TCC, alongside
    /// the engine venv), created on demand.
    static var signaturesDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SamPDFStudio/signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saved signature PNGs, newest first.
    func savedSignatures() -> [URL] {
        let dir = Self.signaturesDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    /// Persist a rendered signature PNG and (by default) make it active.
    @discardableResult
    func saveSignaturePNG(_ data: Data, makeActive: Bool = true) -> URL? {
        let name = "sig-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let url = Self.signaturesDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            if makeActive { activeSignatureURL = url }
            objectWillChange.send()
            return url
        } catch {
            report(error, while: "Saving signature")
            return nil
        }
    }

    func setActiveSignature(_ url: URL) {
        activeSignatureURL = url
    }

    func deleteSignature(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if activeSignatureURL?.path == url.path {
            activeSignatureURL = savedSignatures().first
        }
        objectWillChange.send()
    }

    private func placeTypedSignature(page: Int, x: Double, y: Double) {
        let text = signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            toast("Enter your signature name first")
            return
        }
        let width = max(120.0, Double(text.count) * 14.0)
        runEngineOp(title: "Sign") { [engine] input, output in
            _ = try engine.addSignature(
                input: input, output: output, page: page,
                x: x, y: y, width: width, height: 44,
                text: text, fontSize: 26
            )
        }
    }

    func chooseImageForInsert() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image, then click the page to place it"
        guard panel.runModal() == .OK else { return }
        pendingImageURL = panel.url
        if pendingImageURL != nil {
            toast("Now click the page where the image should go")
        }
    }

    /// Annotate/Fill&Sign "Text": drop a new-text draft at the click. Reuses
    /// the same editor as Edit's new-text tool, which reliably accepts typing.
    func placeTextDraft(page: Int, x: Double, y: Double) {
        // A click while one draft is open just commits it (its editor's
        // resign-first-responder handles that) — don't stack a second box.
        if newTextDraft != nil { newTextDraft = nil; return }
        blockSelectionCounter += 1
        newTextDraft = NewTextDraft(page: page, engineX: x, engineY: y, selectionID: blockSelectionCounter)
    }

    func placeImage(page: Int, x: Double, y: Double) {
        guard selectedOperation == .edit, selectedEditTool == .image else { return }
        guard let image = pendingImageURL else {
            toast("Choose an image first")
            return
        }
        let width = 200.0
        var height = 150.0
        if let nsImage = NSImage(contentsOf: image), nsImage.size.width > 0 {
            let aspect = nsImage.size.height / nsImage.size.width
            height = (width * aspect).rounded()
        }
        runEngineOp(title: "Place Image") { [engine] input, output in
            _ = try engine.addImage(
                input: input, output: output, image: image,
                page: page, x: x, y: y, width: width, height: height
            )
        }
    }

    // MARK: - Block editing (engine)

    /// Per-page text blocks, cached per document version so a click can
    /// hit-test locally and open the editor instantly.
    private var pageBlocksCache: [Int: [PDFEngineClient.EngineBlockPayload]] = [:]
    private var pageBlocksCacheRevision: Int = -1

    /// Click on text in Edit > Text: find the paragraph block there and open
    /// the in-place block editor.
    func editBlock(page: Int, x: Double, y: Double) {
        editorLog.info("store.editBlock page=\(page) x=\(x) y=\(y) busy=\(self.busy)")
        guard selectedOperation == .edit, selectedEditTool == .contentText else { return }
        guard currentPDFURL != nil, !busy else { return }
        if pageBlocksCacheRevision != documentRevision {
            pageBlocksCache = [:]
            pageBlocksCacheRevision = documentRevision
        }
        if let blocks = pageBlocksCache[page] {
            openBlock(from: blocks, page: page, x: x, y: y)
            return
        }
        fetchBlocks(page: page) { [weak self] blocks in
            self?.openBlock(from: blocks, page: page, x: x, y: y)
        }
    }

    /// Warm the block cache for the visible page so the first click is instant.
    func prefetchBlocksForVisiblePage() {
        guard selectedOperation == .edit, selectedEditTool == .contentText else { return }
        guard currentPDFURL != nil, !busy else { return }
        if pageBlocksCacheRevision != documentRevision {
            pageBlocksCache = [:]
            pageBlocksCacheRevision = documentRevision
        }
        let page = currentVisiblePage()
        guard pageBlocksCache[page] == nil else { return }
        fetchBlocks(page: page) { _ in }
    }

    /// Warm the block cache for a grabbed region's page so alignment guides
    /// exist by the time the user starts dragging it.
    private func prefetchGuidesForGrabRegion() {
        guard selectedOperation == .edit, selectedEditTool == .grab else { return }
        guard currentPDFURL != nil, !busy else { return }
        guard !selectedPDFRect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if pageBlocksCacheRevision != documentRevision {
            pageBlocksCache = [:]
            pageBlocksCacheRevision = documentRevision
        }
        let page = boundedPage(selectedPDFPage)
        guard pageBlocksCache[page] == nil else { return }
        fetchBlocks(page: page) { _ in }
    }

    /// Cached block rects for a page as engine-coordinate CGRects — alignment
    /// guide candidates for the Grab tool. Empty if the cache is stale or cold.
    func guideRects(forPage page: Int) -> [CGRect] {
        guard pageBlocksCacheRevision == documentRevision,
              let blocks = pageBlocksCache[page] else { return [] }
        return blocks
            .filter { $0.rect.count == 4 }
            .map { CGRect(x: $0.rect[0], y: $0.rect[1], width: $0.rect[2] - $0.rect[0], height: $0.rect[3] - $0.rect[1]) }
    }

    private func fetchBlocks(page: Int, then completion: @escaping ([PDFEngineClient.EngineBlockPayload]) -> Void) {
        guard let input = currentPDFURL else { return }
        let revision = documentRevision
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let blocks = try self.engine.pageBlocks(input: input, page: page)
                DispatchQueue.main.async {
                    guard revision == self.documentRevision else { return }
                    self.pageBlocksCache[page] = blocks
                    completion(blocks)
                }
            } catch {
                DispatchQueue.main.async {
                    self.report(error, while: "Finding text block")
                }
            }
        }
    }

    private func openBlock(from blocks: [PDFEngineClient.EngineBlockPayload], page: Int, x: Double, y: Double) {
        guard selectedOperation == .edit, selectedEditTool == .contentText, !busy else { return }
        var chosen: PDFEngineClient.EngineBlockPayload?
        var bestDistance = Double.greatestFiniteMagnitude
        for block in blocks where block.rect.count == 4 {
            let dx = max(block.rect[0] - x, x - block.rect[2], 0)
            let dy = max(block.rect[1] - y, y - block.rect[3], 0)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                chosen = block
            }
        }
        guard let block = chosen, bestDistance <= 900 else { // within ~30pt
            // Clicking empty space while an editor is open just dismisses it
            // (the editor's own resign-first-responder commits). Spawning a
            // new text box on that same click would also nil the selection
            // before the pending commit runs. Require a click on truly idle
            // canvas to start new text.
            if activeBlock != nil { activeBlock = nil; return }
            if newTextDraft != nil { newTextDraft = nil; return }
            // Cursor mode: an empty spot opens a fresh text box to type into.
            // Hand mode keeps the old "nothing to grab here" feedback.
            if !blockMoveMode {
                blockSelectionCounter += 1
                newTextDraft = NewTextDraft(page: page, engineX: x, engineY: y, selectionID: blockSelectionCounter)
            } else {
                toast("No editable text there")
            }
            return
        }
        newTextDraft = nil
        activeBlockGuides = blocks
            .filter { $0.rect != block.rect && $0.rect.count == 4 }
            .map { CGRect(x: $0.rect[0], y: $0.rect[1], width: $0.rect[2] - $0.rect[0], height: $0.rect[3] - $0.rect[1]) }
        blockSelectionCounter += 1
        activeBlock = ActiveTextBlock(
            page: page,
            engineRect: CGRect(
                x: block.rect[0], y: block.rect[1],
                width: block.rect[2] - block.rect[0], height: block.rect[3] - block.rect[1]
            ),
            revision: documentRevision,
            selectionID: blockSelectionCounter,
            originalText: block.text,
            fontName: block.fontname,
            lineHeight: block.line_height,
            originalFontSize: block.fontsize,
            originalColorHex: block.color,
            originalBold: block.bold,
            originalItalic: block.italic,
            fontSize: block.fontsize,
            colorHex: block.color,
            bold: block.bold,
            italic: block.italic,
            underline: false,
            alignment: "left",
            fontFamily: nil,
            backgroundHex: nil
        )
    }

    /// Commit an edit for EXACTLY the block whose editor closed. The block
    /// rides along from the editor because this call arrives on an async
    /// hop — by then the user may already have clicked a different
    /// paragraph, and reading `activeBlock` here would commit the old text
    /// into the new block's rect (and tear down its editor mid-typing).
    func commitBlockEdit(block: ActiveTextBlock, newText: String) {
        editorLog.info("store.commitBlockEdit sel=\(block.selectionID) text=\(String(newText.prefix(30)))")
        guard selectedOperation == .edit, selectedEditTool == .contentText else { return }
        var block = block
        // The payload identifies WHICH block; the style panel edits are kept
        // in blockStyleBySelection (by selectionID) so they survive activeBlock
        // being niled OR replaced by another paragraph before this async commit.
        if let style = blockStyleBySelection[block.selectionID] {
            block.fontSize = style.fontSize
            block.colorHex = style.colorHex
            block.bold = style.bold
            block.italic = style.italic
            block.underline = style.underline
            block.alignment = style.alignment
            block.fontFamily = style.fontFamily
            block.backgroundHex = style.backgroundHex
            block.colorRuns = style.colorRuns
        }
        blockStyleBySelection[block.selectionID] = nil
        if activeBlock?.selectionID == block.selectionID {
            activeBlock = nil
        }
        guard block.revision == documentRevision else {
            editorLog.error("commitBlockEdit DROPPED: stale block rev \(block.revision) vs \(self.documentRevision)")
            toast("Text changed underneath — click the paragraph again")
            return
        }
        editorLog.info("commitBlockEdit MERGED italic=\(block.italic) under=\(block.underline) align=\(block.alignment) changed=\(block.styleChanged) textChanged=\(newText != block.originalText)")
        let textChanged = newText != block.originalText
        guard textChanged || block.styleChanged else { return }
        // If the user already clicked the NEXT paragraph, the op below will
        // close that editor (document changes). Re-open it for them after.
        let displaced = activeBlock
        let trackOriginal = (trackChanges && textChanged) ? block.originalText : nil
        // Serialize per-word color spans to a compact JSON array; only sent
        // when the user actually colored a sub-range.
        let colorRunsJSON: String? = block.colorRuns.isEmpty ? nil
            : (try? JSONEncoder().encode(block.colorRuns)).flatMap { String(data: $0, encoding: .utf8) }
        runEngineOp(title: "Edit Text", onDone: { [weak self] in
            guard let self, let displaced else { return }
            self.editBlock(
                page: displaced.page,
                x: displaced.engineRect.midX,
                y: displaced.engineRect.midY
            )
        }) { [engine] input, output in
            _ = try engine.replaceBlock(
                input: input,
                output: output,
                page: block.page,
                rect: block.engineRectString,
                text: newText,
                fontSize: block.styleChanged ? block.fontSize : 0,
                fontFamily: block.fontFamily,
                colorHex: block.styleChanged ? block.colorHex : nil,
                bold: block.bold,
                italic: block.italic,
                underline: block.underline,
                alignment: block.alignment,
                background: block.backgroundHex,
                lineHeight: block.lineHeight,
                trackOriginal: trackOriginal,
                originalText: block.originalText,
                colorRunsJSON: colorRunsJSON
            )
        }
    }

    func cancelBlockEdit(block: ActiveTextBlock) {
        if activeBlock?.selectionID == block.selectionID {
            activeBlock = nil
        }
    }

    /// Commit a freshly typed text box for EXACTLY the draft whose editor
    /// closed. Like commitBlockEdit, the draft rides along the async hop so a
    /// later click can't retarget this render. Empty text is a silent no-op.
    func commitNewText(draft: NewTextDraft, text: String) {
        editorLog.info("store.commitNewText sel=\(draft.selectionID) text=\(String(text.prefix(30)))")
        // Reachable from Edit>Text, Annotate>Text, and Fill&Sign>Text.
        guard selectedOperation == .edit || selectedOperation == .annotate || selectedOperation == .fillSign else { return }
        var draft = draft
        // Style edits kept per-selectionID so they survive newTextDraft being
        // cleared or replaced before this async commit runs.
        if let style = draftStyleBySelection[draft.selectionID] {
            draft.fontName = style.fontName
            draft.fontSize = style.fontSize
            draft.colorHex = style.colorHex
            draft.bold = style.bold
            draft.italic = style.italic
            draft.underline = style.underline
            draft.alignment = style.alignment
        }
        draftStyleBySelection[draft.selectionID] = nil
        if newTextDraft?.selectionID == draft.selectionID {
            newTextDraft = nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runEngineOp(title: "Add Text") { [engine] input, output in
            _ = try engine.addText(
                input: input,
                output: output,
                page: draft.page,
                x: draft.engineX,
                y: draft.engineY,
                text: trimmed,
                fontSize: draft.fontSize,
                fontName: draft.fontName,
                colorHex: draft.colorHex,
                bold: draft.bold,
                italic: draft.italic,
                underline: draft.underline,
                alignment: draft.alignment
            )
        }
    }

    func cancelNewText(draft: NewTextDraft) {
        if newTextDraft?.selectionID == draft.selectionID {
            newTextDraft = nil
        }
    }

    /// Drag the block's dashed frame to a new spot. Moves ONLY the block's
    /// own text (per-line styles preserved), never neighboring content, and
    /// lands exactly at the drop point. Any text typed in the editor before
    /// dragging is carried along.
    func moveActiveBlock(block: ActiveTextBlock, text: String, toEngineX x: Double, y: Double) {
        editorLog.info("store.moveActiveBlock sel=\(block.selectionID) dest=(\(x), \(y)) text=\(String(text.prefix(30)))")
        guard selectedOperation == .edit, selectedEditTool == .contentText else { return }
        var block = block
        if let style = blockStyleBySelection[block.selectionID] {
            block.fontSize = style.fontSize
            block.colorHex = style.colorHex
            block.bold = style.bold
            block.italic = style.italic
            block.underline = style.underline
            block.alignment = style.alignment
            block.fontFamily = style.fontFamily
            block.backgroundHex = style.backgroundHex
            block.colorRuns = style.colorRuns
        }
        blockStyleBySelection[block.selectionID] = nil
        if activeBlock?.selectionID == block.selectionID {
            activeBlock = nil
        }
        guard block.revision == documentRevision else {
            editorLog.error("moveActiveBlock DROPPED: stale block rev \(block.revision) vs \(self.documentRevision)")
            toast("Text changed underneath — click the paragraph again")
            return
        }
        let moveText = text.isEmpty ? block.originalText : text
        runEngineOp(title: "Move Text") { [engine] input, output in
            _ = try engine.moveBlock(
                input: input,
                output: output,
                page: block.page,
                rect: block.engineRectString,
                text: moveText,
                destX: x,
                destY: y,
                fontSize: block.styleChanged ? block.fontSize : 0,
                fontFamily: block.fontFamily,
                colorHex: block.styleChanged ? block.colorHex : nil,
                bold: block.styleChanged && block.bold,
                italic: block.italic,
                underline: block.underline,
                alignment: block.alignment,
                lineHeight: block.lineHeight,
                originalText: block.originalText
            )
        }
    }

    // MARK: - Edit (engine)

    func redactSelectedText() {
        guard selectedOperation == .edit, selectedEditTool == .redact else {
            toast("Switch to Edit > Redact to redact")
            return
        }
        let selected = normalizedSelectedPDFText()
        if !selected.isEmpty {
            redactFindText = selected
        }
        let find = redactFindText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !find.isEmpty else {
            toast("Select the text to redact first")
            return
        }
        guard confirm("Permanently remove “\(find.prefix(60))” from the document?", button: "Redact") else { return }
        let selection = selectionTarget(force: true)
        runEngineOp(title: "Redact") { [engine] input, output in
            _ = try engine.redactText(
                input: input, output: output,
                find: find, label: "", pages: nil,
                page: selection.page, rect: selection.rect
            )
        }
    }

    func copySelectedRegion() {
        guard selectedOperation == .edit, selectedEditTool == .grab else {
            toast("Switch to Edit > Grab to copy a region")
            return
        }
        guard let sourceURL = currentPDFURL else {
            toast("Open a PDF first")
            return
        }
        let rect = selectedPDFRect.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rect.isEmpty else {
            toast("Lasso an area first")
            return
        }
        let text = normalizedSelectedPDFText()
        regionClipboard = PDFRegionClipboard(sourceURL: sourceURL, page: boundedPage(selectedPDFPage), rect: rect, text: text)
        hasCopiedRegion = true
        if !text.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        toast("Region copied — click where it should go, then paste")
    }

    func pasteCopiedRegion(page: Int, x: Double, y: Double) {
        guard selectedOperation == .edit, selectedEditTool == .grab else {
            toast("Switch to Edit > Grab to paste a region")
            return
        }
        guard let clipboard = regionClipboard else {
            toast("Copy a region first")
            return
        }
        let destinationPage = boundedPage(page)
        let reselect = movedRectString(from: clipboard.rect, toX: x, y: y)
        runEngineOp(title: "Paste Region", onDone: { [weak self] in
            guard let self, let reselect else { return }
            self.selectedPDFPage = destinationPage
            self.selectedPDFRect = reselect
        }) { [engine] input, output in
            _ = try engine.pasteRegion(
                input: input,
                source: clipboard.sourceURL,
                output: output,
                sourcePage: clipboard.page,
                sourceRect: clipboard.rect,
                destinationPage: destinationPage,
                destinationX: x,
                destinationY: y,
                eraseSource: false
            )
        }
    }

    func pasteCopiedRegionAtSelection() {
        let destination = selectedRegionOrigin() ?? copiedRegionOffsetOrigin()
        guard let destination else {
            toast("Copy a region first")
            return
        }
        pasteCopiedRegion(page: destination.page, x: destination.x, y: destination.y)
    }

    func moveSelectedRegion(page: Int, x: Double, y: Double) {
        guard selectedOperation == .edit, selectedEditTool == .grab else {
            toast("Switch to Edit > Grab to move a region")
            return
        }
        guard currentPDFURL != nil else {
            toast("Open a PDF first")
            return
        }
        let rect = selectedPDFRect.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rect.isEmpty else {
            toast("Lasso an area first")
            return
        }
        let sourcePage = boundedPage(selectedPDFPage)
        let destinationPage = boundedPage(page)
        // Keep the moved section selected at its new spot so it can be
        // dragged again immediately — direct manipulation.
        let reselect = movedRectString(from: rect, toX: x, y: y)
        runEngineOp(title: "Move Region", onDone: { [weak self] in
            guard let self, let reselect else { return }
            self.selectedPDFPage = destinationPage
            self.selectedPDFRect = reselect
        }) { [engine] input, output in
            _ = try engine.pasteRegion(
                input: input,
                source: input,
                output: output,
                sourcePage: sourcePage,
                sourceRect: rect,
                destinationPage: destinationPage,
                destinationX: x,
                destinationY: y,
                eraseSource: true
            )
        }
    }

    /// Rect string with the same size as `rect`, repositioned to origin (x, y).
    private func movedRectString(from rect: String, toX x: Double, y: Double) -> String? {
        guard let parsed = parseRect(rect) else { return nil }
        let width = parsed.x1 - parsed.x0
        let height = parsed.y1 - parsed.y0
        return "\(x),\(y),\(x + width),\(y + height)"
    }

    // MARK: - Pages mode (instant, PDFKit)

    func deleteSelectedPages() {
        guard let document, !selectedPageIndices.isEmpty else { return }
        guard document.pageCount > selectedPageIndices.count else {
            toast("A PDF needs at least one page")
            return
        }
        for index in selectedPageIndices.sorted(by: >) {
            document.removePage(at: index)
        }
        selectedPageIndices = []
        pageCount = document.pageCount
        commitDocumentChange(title: "Delete Pages")
    }

    func rotateSelectedPages() {
        guard let document, !selectedPageIndices.isEmpty else { return }
        for index in selectedPageIndices {
            if let page = document.page(at: index) {
                page.rotation = (page.rotation + 90) % 360
            }
        }
        commitDocumentChange(title: "Rotate Pages")
    }

    func movePage(from source: Int, to destination: Int) {
        guard let document,
              source != destination,
              source >= 0, source < document.pageCount,
              destination >= 0, destination <= document.pageCount,
              let page = document.page(at: source) else { return }
        document.removePage(at: source)
        let target = source < destination ? destination - 1 : destination
        document.insert(page, at: min(target, document.pageCount))
        selectedPageIndices = []
        commitDocumentChange(title: "Reorder Pages")
    }

    func extractSelectedPages() {
        guard let document, !selectedPageIndices.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName(suffix: "pages")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let extracted = PDFDocument()
        for (offset, index) in selectedPageIndices.sorted().enumerated() {
            if let page = document.page(at: index), let copy = page.copy() as? PDFPage {
                extracted.insert(copy, at: offset)
            }
        }
        if extracted.write(to: url) {
            toast("Saved \(url.lastPathComponent)")
        } else {
            toast("Could not save \(url.lastPathComponent)")
        }
    }

    private var copiedPages: [PDFPage] = []
    @Published var hasCopiedPages: Bool = false

    /// Blank page after the selection (or at the end), sized like its neighbor.
    func insertBlankPage() {
        guard let document else { return }
        let index = selectedPageIndices.max().map { $0 + 1 } ?? document.pageCount
        let reference = document.page(at: max(0, min(index - 1, document.pageCount - 1)))
        let bounds = reference?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let page = PDFPage()
        page.setBounds(bounds, for: .mediaBox)
        document.insert(page, at: min(index, document.pageCount))
        pageCount = document.pageCount
        selectedPageIndices = []
        commitDocumentChange(title: "Insert Page")
    }

    func copySelectedPages() {
        guard let document, !selectedPageIndices.isEmpty else { return }
        copiedPages = selectedPageIndices.sorted().compactMap { index in
            document.page(at: index)?.copy() as? PDFPage
        }
        hasCopiedPages = !copiedPages.isEmpty
        toast("Copied \(copiedPages.count) page\(copiedPages.count == 1 ? "" : "s")")
    }

    func pasteCopiedPages() {
        guard let document, !copiedPages.isEmpty else { return }
        var index = selectedPageIndices.max().map { $0 + 1 } ?? document.pageCount
        for page in copiedPages {
            guard let copy = page.copy() as? PDFPage else { continue }
            document.insert(copy, at: min(index, document.pageCount))
            index += 1
        }
        pageCount = document.pageCount
        selectedPageIndices = []
        commitDocumentChange(title: "Paste Pages")
    }

    func appendPDFs() {
        guard let document else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to add to the end of this document"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var added = 0
        for url in panel.urls {
            guard let other = PDFDocument(url: url) else { continue }
            for index in 0..<other.pageCount {
                if let page = other.page(at: index), let copy = page.copy() as? PDFPage {
                    document.insert(copy, at: document.pageCount)
                    added += 1
                }
            }
        }
        guard added > 0 else {
            toast("No pages found")
            return
        }
        pageCount = document.pageCount
        commitDocumentChange(title: "Add Pages")
        toast("Added \(added) pages — drag to reorder")
    }

    /// Merge: pick several PDFs, and the combined document
    /// opens straight into the Pages grid to arrange — save comes after.
    func mergePDFFiles() {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose the PDFs to merge (in order)"
        guard panel.runModal() == .OK, panel.urls.count >= 2 else {
            if panel.urls.count == 1 { toast("Pick at least two PDFs to merge") }
            return
        }
        let stagingDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SamPDFStudio/merged", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let output = stagingDir.appendingPathComponent("Merged \(formatter.string(from: Date())).pdf")
        let inputs = panel.urls
        runEngineJob(title: "Merge PDFs") { [engine] in
            _ = try engine.merge(inputs: inputs, output: output)
            return output
        } onSuccess: { [weak self] url in
            guard let self else { return }
            self.loadPDF(url)
            self.selectedOperation = .pages
            self.toast("Merged \(inputs.count) PDFs — arrange the pages, then Save (⌘S)")
        }
    }

    /// Merged documents live in staging until the user chooses a real home.
    private var isStagedMergeDocument: Bool {
        session?.originalURL.path.contains("/SamPDFStudio/merged/") ?? false
    }

    func addPageNumbers(position: String, format: String, start: Int) {
        runEngineOp(title: "Page Numbers") { [engine] input, output in
            _ = try engine.addPageNumbers(input: input, output: output, position: position, format: format, start: start)
        }
    }

    func resizePages(width: Double, height: Double, presetName: String) {
        runEngineOp(title: "Resize to \(presetName)") { [engine] input, output in
            _ = try engine.resizePages(input: input, output: output, width: width, height: height)
        }
    }

    @Published var showPasswordSheet: Bool = false
    @Published var passwordText: String = ""
    @Published var pendingPassword: String?

    /// The password protects the file when it is saved — the working copy
    /// stays editable in the meantime.
    func setPassword() {
        let password = passwordText
        passwordText = ""
        showPasswordSheet = false
        guard !password.isEmpty else {
            pendingPassword = nil
            toast("Password removed for future saves")
            return
        }
        pendingPassword = password
        isDirty = true
        toast("Password will protect the file when you Save (⌘S)")
    }

    private func applyPendingPassword(to url: URL) {
        guard let password = pendingPassword else { return }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".sampdf-protect-\(UUID().uuidString).pdf")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.engine.setPassword(input: url, output: temp, password: password)
                let data = try Data(contentsOf: temp)
                try data.write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: temp)
                DispatchQueue.main.async {
                    self.toast("Saved with password protection")
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                DispatchQueue.main.async {
                    self.report(error, while: "Protecting with password")
                }
            }
        }
    }

    func reduceFileSize(quality: String) {
        guard let session else { return }
        let before = (try? Data(contentsOf: session.currentURL).count) ?? 0
        var savedResult: (before: Int, after: Int)?
        runEngineOp(title: "Reduce File Size", onDone: { [weak self] in
            if let result = savedResult, result.before > 0 {
                let percent = 100 - Int(Double(result.after) / Double(result.before) * 100)
                let formatter = ByteCountFormatter()
                self?.lastMessage = percent > 0
                    ? "Reduced \(formatter.string(fromByteCount: Int64(result.before))) → \(formatter.string(fromByteCount: Int64(result.after))) (−\(percent)%)"
                    : "Already as small as it gets"
            }
        }) { [engine] input, output in
            let result = try engine.compress(input: input, output: output, quality: quality)
            savedResult = (before, result.after_bytes)
        }
    }

    func newFromImages() {
        guard confirmDiscardIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to combine into a PDF"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "Images.pdf"
        guard savePanel.runModal() == .OK, let output = savePanel.url else { return }
        let inputs = panel.urls
        runEngineJob(title: "Create PDF from Images") { [engine] in
            _ = try engine.imagesToPDF(inputs: inputs, output: output)
            return output
        } onSuccess: { [weak self] url in
            self?.loadPDF(url)
        }
    }

    // MARK: - OCR mode (engine)

    func runOCR(currentPageOnly: Bool) {
        let language = ocrLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "eng" : ocrLanguage
        let force = forceOCR
        let page = currentPageOnly ? currentVisiblePage() : nil
        runEngineOp(title: currentPageOnly ? "Recognize Text (This Page)" : "Recognize Text") { [engine] input, output in
            _ = try engine.ocr(input: input, output: output, language: language, force: force, page: page)
        }
    }

    func enhanceScan() {
        let grayscale = enhanceGrayscale
        let denoise = enhanceDenoise
        let contrast = enhanceContrast
        let sharpness = enhanceSharpness
        runEngineOp(title: "Enhance Scan") { [engine] input, output in
            _ = try engine.enhanceScan(input: input, output: output, grayscale: grayscale, denoise: denoise, contrast: contrast, sharpness: sharpness)
        }
    }

    // MARK: - Export

    func exportPDFCopy() {
        guard let session else { return }
        flushDocumentIfNeeded()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName(suffix: "copy")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: session.currentURL)
            try data.write(to: url, options: .atomic)
            toast("Exported \(url.lastPathComponent)")
        } catch {
            report(error, while: "Exporting PDF")
        }
    }

    func exportOffice(_ format: OfficeExportFormat) {
        guard currentPDFURL != nil else { return }
        flushDocumentIfNeeded()
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.rawValue) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = suggestedName(extension: format.rawValue)
        guard panel.runModal() == .OK, let url = panel.url, let input = currentPDFURL else { return }
        runEngineJob(title: "Export to \(format.title)") { [engine] in
            switch format {
            case .word: _ = try engine.exportDOCX(input: input, output: url)
            case .excel: _ = try engine.exportXLSX(input: input, output: url)
            case .powerpoint: _ = try engine.exportPPTX(input: input, output: url)
            }
            return url
        } onSuccess: { [weak self] url in
            self?.revealAndToast(url)
        }
    }

    func exportText(_ format: TextExportFormat) {
        guard currentPDFURL != nil else { return }
        flushDocumentIfNeeded()
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.rawValue) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = suggestedName(extension: format.rawValue)
        guard panel.runModal() == .OK, let url = panel.url, let input = currentPDFURL else { return }
        runEngineJob(title: "Export to \(format.title)") { [engine] in
            _ = try engine.exportText(input: input, output: url, format: format)
            return url
        } onSuccess: { [weak self] url in
            self?.revealAndToast(url)
        }
    }

    func exportImages(_ format: ImageExportFormat) {
        guard currentPDFURL != nil else { return }
        flushDocumentIfNeeded()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the page images"
        guard panel.runModal() == .OK, let folder = panel.url, let input = currentPDFURL else { return }
        runEngineJob(title: "Export \(format.title) Images") { [engine] in
            _ = try engine.exportImages(input: input, outputDirectory: folder, format: format, dpi: 200)
            return folder
        } onSuccess: { [weak self] url in
            self?.revealAndToast(url)
        }
    }

    // MARK: - Version plumbing

    /// Commit an in-memory PDFKit change as a new version file.
    private func commitDocumentChange(title: String) {
        guard let session, let document else { return }
        guard !busy else {
            toast("Wait for \(busyTitle) to finish")
            reloadCurrentVersion()
            return
        }
        let url = session.nextVersionURL()
        guard document.write(to: url) else {
            toast("\(title) failed to save")
            reloadCurrentVersion()
            return
        }
        session.commit(url)
        documentRevision += 1
        refreshHistoryState()
        toast(title)
    }

    /// Discard un-committed in-memory changes by reloading the current version.
    private func reloadCurrentVersion() {
        guard let session else { return }
        let position = captureScrollPosition()
        document = PDFDocument(url: session.currentURL)
        pageCount = document?.pageCount ?? 0
        documentRevision += 1
        selectedPageIndices = []
        restoreScrollPosition(position)
    }

    /// Run an engine command from the current version into the next version.
    private func runEngineOp(title: String, onDone: (() -> Void)? = nil, work: @escaping (URL, URL) throws -> Void) {
        guard let session else {
            toast("Open a PDF first")
            return
        }
        guard !busy else {
            toast("Wait for \(busyTitle) to finish")
            return
        }
        flushDocumentIfNeeded()
        let input = session.currentURL
        let output = session.nextVersionURL()
        busy = true
        busyTitle = title
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try work(input, output)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = false
                    session.commit(output)
                    let position = self.captureScrollPosition()
                    self.document = PDFDocument(url: output)
                    self.pageCount = self.document?.pageCount ?? 0
                    self.documentRevision += 1
                    self.clearCanvasSelection()
                    self.refreshHistoryState()
                    self.restoreScrollPosition(position)
                    self.toast(title)
                    onDone?()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.busy = false
                    self?.report(error, while: title)
                }
            }
        }
    }

    /// Run an engine command whose output is not the working document.
    private func runEngineJob(title: String, work: @escaping () throws -> URL, onSuccess: @escaping (URL) -> Void) {
        busy = true
        busyTitle = title
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let url = try work()
                DispatchQueue.main.async {
                    self?.busy = false
                    onSuccess(url)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.busy = false
                    self?.report(error, while: title)
                }
            }
        }
    }

    /// PDFKit-side changes that never went through commitDocumentChange
    /// (defensive; ops normally commit immediately).
    private func flushDocumentIfNeeded() {
        // Current design commits after every mutation, so nothing to do.
    }

    private func refreshHistoryState() {
        canUndo = session?.canUndo ?? false
        canRedo = session?.canRedo ?? false
        // Staged merges count as unsaved until they get a real home.
        isDirty = (session?.isDirty ?? false) || (session != nil && isStagedMergeDocument)
        DispatchQueue.main.async { [weak self] in
            self?.prefetchBlocksForVisiblePage()
        }
    }

    // MARK: - Helpers

    func currentVisiblePage() -> Int {
        guard let pdfView = pdfViewProxy.pdfView,
              let page = pdfView.currentPage,
              let document = pdfView.document else { return 1 }
        return document.index(for: page) + 1
    }

    func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func revealAndToast(_ url: URL) {
        toast("Exported \(url.lastPathComponent)")
        reveal(url)
    }

    private func toast(_ message: String) {
        lastMessage = message
        let stamp = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.lastMessage == stamp {
                self?.lastMessage = ""
            }
        }
    }

    private func report(_ error: Error, while title: String) {
        errorMessage = "\(title) failed.\n\(error.localizedDescription)"
    }

    private func confirm(_ message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if button == "Redact" || button == "Revert" {
            alert.buttons.first?.hasDestructiveAction = true
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDiscardIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes to \(documentName)."
        alert.informativeText = "Save them before continuing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func boundedPage(_ page: Int) -> Int {
        max(1, min(page, max(pageCount, 1)))
    }

    private func clearCanvasSelection() {
        selectedPDFText = ""
        selectedPDFPage = 1
        selectedPDFRect = ""
        findText = ""
        redactFindText = ""
        pendingImageURL = nil
        activeBlock = nil
        newTextDraft = nil
        activeBlockGuides = []
    }

    private func normalizedSelectedPDFText() -> String {
        selectedPDFText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectionTarget(force: Bool = false) -> (page: Int?, rect: String?) {
        let rect = selectedPDFRect.trimmingCharacters(in: .whitespacesAndNewlines)
        if rect.isEmpty {
            return (nil, nil)
        }
        if force || normalizedSelectedPDFText() == findText || normalizedSelectedPDFText() == redactFindText {
            return (boundedPage(selectedPDFPage), rect)
        }
        return (nil, nil)
    }

    private func selectedRegionOrigin() -> (page: Int, x: Double, y: Double)? {
        guard let rect = parseRect(selectedPDFRect) else { return nil }
        return (boundedPage(selectedPDFPage), rect.x0, rect.y0)
    }

    private func copiedRegionOffsetOrigin() -> (page: Int, x: Double, y: Double)? {
        guard let clipboard = regionClipboard, let rect = parseRect(clipboard.rect) else { return nil }
        return (boundedPage(clipboard.page), rect.x0 + 18, rect.y0 + 18)
    }

    private func parseRect(_ text: String) -> (x0: Double, y0: Double, x1: Double, y1: Double)? {
        let values = text
            .split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == 4, let x0 = values[0], let y0 = values[1], let x1 = values[2], let y1 = values[3] else {
            return nil
        }
        return (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
    }

    private func suggestedName(suffix: String) -> String {
        let base = session?.originalURL.deletingPathExtension().lastPathComponent ?? "Document"
        return "\(base) \(suffix).pdf"
    }

    private func suggestedName(extension ext: String) -> String {
        let base = session?.originalURL.deletingPathExtension().lastPathComponent ?? "Document"
        return "\(base).\(ext)"
    }

    private func isPDFURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" {
            return true
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
    }

    private static func url(fromDroppedItem item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url.isFileURL ? url : nil
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }

    // MARK: - Recents

    private func addRecent(_ url: URL) {
        var recents = recentFiles.filter { $0 != url }
        recents.insert(url, at: 0)
        recentFiles = Array(recents.prefix(8))
        UserDefaults.standard.set(recentFiles.map(\.path), forKey: "recentFiles")
    }

    private static func loadRecents() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []
        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
