import AppKit
import OSLog
import PDFKit
import SwiftUI

let editorLog = Logger(subsystem: "com.sam.private.SamPDFStudio", category: "editor")

struct PDFPreviewView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var selectedText: String
    @Binding var selectedPage: Int
    @Binding var selectedRect: String
    let isEditing: Bool
    let isAnnotating: Bool
    let isFillSign: Bool
    let isRedline: Bool
    let blockMoveMode: Bool
    let editTool: EditTool
    let annotateTool: AnnotateTool
    let fillSignTool: FillSignTool
    let redlineTool: RedlineTool
    let activeBlock: ActiveTextBlock?
    let activeBlockGuides: [CGRect]
    let newTextDraft: NewTextDraft?
    let pdfViewProxy: PDFViewProxy
    let onEditBlock: (Int, Double, Double) -> Void
    let onCommitBlock: (ActiveTextBlock, String) -> Void
    let onCancelBlock: (ActiveTextBlock) -> Void
    let onMoveBlock: (ActiveTextBlock, String, Double, Double) -> Void
    let onCommitNewText: (NewTextDraft, String) -> Void
    let onCancelNewText: (NewTextDraft) -> Void
    let onBlockSelectionChanged: (NSRange, Int) -> Void
    let onCopyRegion: () -> Void
    let onPasteRegion: (Int, Double, Double) -> Void
    let onMoveRegion: (Int, Double, Double) -> Void
    let onGrabGuideRects: (Int) -> [CGRect]
    let liveActiveBlock: () -> ActiveTextBlock?
    let liveNewTextDraft: () -> NewTextDraft?
    let onMarkupSelection: (PDFSelection) -> Void
    let onPlaceNote: (Int, CGPoint) -> Void
    let onAddTextBox: (Int, CGPoint, String) -> Void
    let onPlaceSignature: (Int, Double, Double) -> Void
    let onPlaceImage: (Int, Double, Double) -> Void
    let onPlaceTextDraft: (Int, Double, Double) -> Void
    let onLinkRegion: (Int, CGRect) -> Void
    let onFillSignClick: (Int, Double, Double) -> Void
    let onRedlineSelection: (PDFSelection) -> Void
    let onRedlineCaret: (Int, Double, Double) -> Void
    let onNoteSelection: (PDFSelection) -> Void
    let onAnnotationEdited: (String) -> Void

    final class Coordinator {
        var selectedText: Binding<String>
        var selectedPage: Binding<Int>
        var selectedRect: Binding<String>
        var observer: NSObjectProtocol?

        init(selectedText: Binding<String>, selectedPage: Binding<Int>, selectedRect: Binding<String>) {
            self.selectedText = selectedText
            self.selectedPage = selectedPage
            self.selectedRect = selectedRect
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedText: $selectedText, selectedPage: $selectedPage, selectedRect: $selectedRect)
    }

    final class InlineEditTextView: NSTextView {
        var onCommit: ((String) -> Void)?
        var onCancel: (() -> Void)?
        var commitEmptyChanges = false
        private var finished = false
        private var originalText = ""

        override var acceptsFirstResponder: Bool { true }

        init(text: String, frame: NSRect, fontSize: CGFloat, matchedFont: NSFont? = nil, matchedColor: NSColor? = nil) {
            super.init(frame: frame, textContainer: nil)
            string = text
            originalText = text
            configure(fontSize: fontSize, matchedFont: matchedFont, matchedColor: matchedColor)
        }

        override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
            super.init(frame: frameRect, textContainer: container)
            configure(fontSize: frameRect.height * 0.58, matchedFont: nil, matchedColor: nil)
        }

        private func configure(fontSize: CGFloat, matchedFont: NSFont?, matchedColor: NSColor?) {
            // Typing should look like the PDF text being edited: same face,
            // same color, sized for the current zoom.
            font = matchedFont ?? .systemFont(ofSize: max(10, fontSize))
            textColor = matchedColor ?? .textColor
            isEditable = true
            isSelectable = true
            isRichText = false
            importsGraphics = false
            drawsBackground = false
            backgroundColor = .clear
            insertionPointColor = .controlAccentColor
            textContainerInset = NSSize(width: 1, height: 0)
            // Fixed-width container that tracks the view — a horizontally
            // resizable container starts at zero usable width, so typed
            // characters lay out nowhere and never appear (the field looks
            // like it swallows keystrokes even though keyDown fires).
            isVerticallyResizable = true
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textContainer?.widthTracksTextView = true
            textContainer?.lineFragmentPadding = 0
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76:
                finish(commit: true)
            case 53:
                finish(commit: false)
            default:
                super.keyDown(with: event)
            }
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                finish(commit: true)
            }
            return result
        }

        private func finish(commit: Bool) {
            guard !finished else { return }
            finished = true
            let changed = string != originalText || (commitEmptyChanges && !string.isEmpty)
            if commit && changed {
                onCommit?(string)
            } else {
                onCancel?()
            }
        }
    }

    final class RegionOverlayView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2
            layer?.cornerRadius = 2
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }
    }

    /// Multi-line text view used inside the block editor.
    final class BlockTextView: NSTextView {
        var onCommit: ((String) -> Void)?
        var onCancel: (() -> Void)?
        var onGrew: (() -> Void)?
        /// Reports the current selection (range into the full text) and that
        /// text's length, so the store can recolor just the selected words.
        var onSelectionChanged: ((NSRange, Int) -> Void)?
        private var finished = false

        override var acceptsFirstResponder: Bool { true }

        // Fires on every selection change (mouse, keyboard, or programmatic) —
        // the one hook that bridges the AppKit text selection up to the store.
        override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
            onSelectionChanged?(selectedRange(), (string as NSString).length)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Escape
                finish(commit: false)
                return
            }
            if (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                finish(commit: true) // ⌘Return commits; plain Return makes a new line
                return
            }
            super.keyDown(with: event)
        }

        override func didChangeText() {
            super.didChangeText()
            onGrew?()
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result {
                finish(commit: true)
            }
            return result
        }

        func finish(commit: Bool) {
            guard !finished else { return }
            finished = true
            editorLog.info("BlockTextView.finish commit=\(commit)")
            if commit {
                onCommit?(string)
            } else {
                onCancel?()
            }
        }

        /// Close without firing commit/cancel — used when the block move
        /// takes over and must read store state before it is cleared.
        func abandon() {
            finished = true
        }
    }

    /// PDF Expert-style block editor. First click SELECTS the block — a
    /// dashed frame you can drag from anywhere to move it. A second click
    /// puts the caret in to type (Return = new line, drag the border to
    /// move, click away or ⌘Return to apply, Esc to cancel).
    final class BlockEditorView: NSView {
        enum Phase {
            case selected
            case editing
        }

        // Generous border band so the frame is easy to grab while editing.
        static let inset: CGFloat = 11
        let textView: BlockTextView
        var representedRect: CGRect = .zero
        var onMoved: ((NSPoint) -> Void)?
        /// Given a proposed frame, returns a (possibly snapped) origin.
        var snapProvider: ((NSRect) -> NSPoint)?
        var onDragEnded: (() -> Void)?
        /// Hand mode: the frame can be dragged to move the block.
        var movable: Bool = true
        /// Cursor mode: a click switches into text editing.
        var editOnClick: Bool = true
        var onDragBegan: (() -> Void)?
        private(set) var isDragging = false
        private(set) var phase: Phase = .selected
        private var dragStartMouse: NSPoint?
        private var dragStartOrigin: NSPoint?
        private var didDrag = false

        override var acceptsFirstResponder: Bool { true }

        init(frame frameRect: NSRect, text: String, font: NSFont, textColor: NSColor) {
            textView = BlockTextView(frame: NSRect(
                x: Self.inset, y: Self.inset,
                width: max(20, frameRect.width - Self.inset * 2),
                height: max(16, frameRect.height - Self.inset * 2)
            ))
            super.init(frame: frameRect)
            wantsLayer = true

            textView.string = text
            textView.font = font
            textView.textColor = textColor
            textView.isRichText = false
            textView.importsGraphics = false
            textView.drawsBackground = true
            // Covers the original block while its replacement is typed.
            textView.backgroundColor = .white
            textView.insertionPointColor = .controlAccentColor
            textView.textContainerInset = NSSize(width: 0, height: 0)
            textView.textContainer?.lineFragmentPadding = 0
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.onGrew = { [weak self] in
                self?.growToFitText()
            }
            // Starts in the SELECTED phase: draggable, not yet typable. The
            // original page text stays visible through the frame — no white
            // cover, no doubled "ghost" text.
            textView.isEditable = false
            textView.isSelectable = false
            textView.isHidden = true
            addSubview(textView)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if phase == .editing && textView.frame.contains(point) {
                NSCursor.iBeam.set()
            } else if movable {
                NSCursor.openHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        }

        /// Second click: switch from selected to text editing.
        func enterEditing(at windowPoint: NSPoint?) {
            guard phase == .selected else { return }
            phase = .editing
            textView.isHidden = false
            textView.isEditable = true
            textView.isSelectable = true
            window?.makeFirstResponder(textView)
            if let windowPoint {
                let textPoint = textView.convert(windowPoint, from: nil)
                let index = textView.characterIndexForInsertion(at: textPoint)
                textView.setSelectedRange(NSRange(location: min(index, (textView.string as NSString).length), length: 0))
            }
            window?.invalidateCursorRects(for: self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // While merely selected, the whole block is one draggable object.
            let view = super.hitTest(point)
            if phase == .selected, view === textView {
                return self
            }
            return view
        }

        override func keyDown(with event: NSEvent) {
            if phase == .selected {
                if event.keyCode == 53 { // Escape — deselect without changes
                    textView.finish(commit: false)
                    return
                }
                if event.keyCode == 36 || event.keyCode == 76 { // Return — edit
                    enterEditing(at: nil)
                    return
                }
            }
            super.keyDown(with: event)
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result && phase == .selected {
                // Click-away while selected: close (no text changes to save).
                textView.finish(commit: true)
            }
            return result
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let accent = NSColor.controlAccentColor
            let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 1.5
            border.setLineDash([4, 3], count: 2, phase: 0)
            accent.setStroke()
            border.stroke()

            // Circular handles like PDF Expert's block box.
            let radius: CGFloat = 3.5
            let points = [
                NSPoint(x: bounds.minX + 1.5, y: bounds.midY),
                NSPoint(x: bounds.maxX - 1.5, y: bounds.midY),
                NSPoint(x: bounds.minX + 1.5, y: bounds.maxY - 1.5),
                NSPoint(x: bounds.maxX - 1.5, y: bounds.maxY - 1.5),
                NSPoint(x: bounds.minX + 1.5, y: bounds.minY + 1.5),
                NSPoint(x: bounds.maxX - 1.5, y: bounds.minY + 1.5),
            ]
            for point in points {
                let dot = NSBezierPath(ovalIn: NSRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2
                ))
                NSColor.white.setFill()
                dot.fill()
                accent.setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
        }

        private func growToFitText() {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            let needed = used.height + Self.inset * 2 + 4
            if needed > frame.height {
                var newFrame = frame
                newFrame.size.height = needed
                frame = newFrame
                textView.frame = NSRect(
                    x: Self.inset, y: Self.inset,
                    width: frame.width - Self.inset * 2,
                    height: frame.height - Self.inset * 2
                )
                needsDisplay = true
            }
        }

        // Selected phase: drag from ANYWHERE moves the block; a plain click
        // enters text editing. Editing phase: only the border band drags.
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            dragStartMouse = superview?.convert(event.locationInWindow, from: nil)
            dragStartOrigin = frame.origin
            didDrag = false
            if movable {
                isDragging = true
                NSCursor.closedHand.set()
                // Guides are computed NOW, against the current scroll/zoom.
                onDragBegan?()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard movable else { return }
            guard let start = dragStartMouse,
                  let origin = dragStartOrigin,
                  let current = superview?.convert(event.locationInWindow, from: nil) else { return }
            let dx = current.x - start.x
            let dy = current.y - start.y
            if abs(dx) + abs(dy) > 2 {
                didDrag = true
            }
            let proposed = NSPoint(x: origin.x + dx, y: origin.y + dy)
            if didDrag, let snapProvider {
                setFrameOrigin(snapProvider(NSRect(origin: proposed, size: frame.size)))
            } else {
                setFrameOrigin(proposed)
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                dragStartMouse = nil
                dragStartOrigin = nil
                isDragging = false
            }
            if movable {
                NSCursor.openHand.set()
            }
            onDragEnded?()
            editorLog.info("editor mouseUp didDrag=\(self.didDrag) origin=(\(self.frame.origin.x), \(self.frame.origin.y))")
            if didDrag {
                onMoved?(frame.origin)
            } else if phase == .selected && editOnClick {
                enterEditing(at: event.locationInWindow)
            }
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .openHand)
            if phase == .editing {
                addCursorRect(textView.frame, cursor: .iBeam)
            }
        }
    }

    /// Blue smart-guide lines shown while dragging a block, PDF Expert style.
    final class GuideOverlayView: NSView {
        var verticalLines: [CGFloat] = []
        var horizontalLines: [CGFloat] = []
        var pageRect: NSRect = .zero

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.systemBlue.setStroke()
            for x in verticalLines {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x, y: pageRect.minY))
                path.line(to: NSPoint(x: x, y: pageRect.maxY))
                path.lineWidth = 1
                path.stroke()
            }
            for y in horizontalLines {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: pageRect.minX, y: y))
                path.line(to: NSPoint(x: pageRect.maxX, y: y))
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// PDF Expert-style hairline outline around the text span being edited —
    /// a see-through frame, never a filled box.
    final class EditorOutlineView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            layer?.borderWidth = 1
            layer?.cornerRadius = 2
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class EditingPDFView: PDFView {
        var editTool: EditTool = .contentText
        var annotateTool: AnnotateTool = .highlight
        var fillSignTool: FillSignTool = .text
        var redlineTool: RedlineTool = .strikeout
        var onTextSelectionChanged: ((PDFSelection, PDFView) -> Void)?
        var onRegionChanged: ((Int, String) -> Void)?
        var onEditBlock: ((Int, Double, Double) -> Void)?
        var onCommitBlock: ((ActiveTextBlock, String) -> Void)?
        var onCancelBlock: ((ActiveTextBlock) -> Void)?
        var onMoveBlock: ((ActiveTextBlock, String, Double, Double) -> Void)?
        var onCommitNewText: ((NewTextDraft, String) -> Void)?
        var onCancelNewText: ((NewTextDraft) -> Void)?
        /// Bridges the block editor's text selection (range, text length) up to
        /// the store so a Text Color tap can recolor just the selected words.
        var onBlockSelectionChanged: ((NSRange, Int) -> Void)?
        /// Ground-truth readers. SwiftUI can deliver update passes carrying
        /// STALE captured state — e.g. a nil activeBlock snapshotted before
        /// the click that opened the editor — and acting on those tore live
        /// editors down mid-use. Editor lifecycle always consults these.
        var liveActiveBlock: (() -> ActiveTextBlock?)?
        var liveNewTextDraft: (() -> NewTextDraft?)?
        var onCopyRegion: (() -> Void)?
        var onPasteRegion: ((Int, Double, Double) -> Void)?
        var onMoveRegion: ((Int, Double, Double) -> Void)?
        var onGrabGuideRects: ((Int) -> [CGRect])?
        var onMarkupSelection: ((PDFSelection) -> Void)?
        var onPlaceNote: ((Int, CGPoint) -> Void)?
        var onAddTextBox: ((Int, CGPoint, String) -> Void)?
        var onPlaceSignature: ((Int, Double, Double) -> Void)?
        var onPlaceImage: ((Int, Double, Double) -> Void)?
        /// Annotate/Fill&Sign "Text": place a new-text draft (the editor that
        /// reliably accepts typing) rather than a bare inline field.
        var onPlaceTextDraft: ((Int, Double, Double) -> Void)?
        var onLinkRegion: ((Int, CGRect) -> Void)?
        var onFillSignClick: ((Int, Double, Double) -> Void)?
        var onRedlineSelection: ((PDFSelection) -> Void)?
        var onRedlineCaret: ((Int, Double, Double) -> Void)?
        var onNoteSelection: ((PDFSelection) -> Void)?
        /// Commit an in-place annotation move/delete (Edit mode) as a version.
        var onAnnotationEdited: ((String) -> Void)?
        private var noteDownViewPoint: NSPoint?

        // Annotations placed in Annotate/Fill&Sign (notes, text boxes, stamps,
        // signatures) can be grabbed and moved — or deleted — in Edit mode.
        static let movableAnnotationTypes: Set<String> =
            ["Text", "FreeText", "Stamp", "Square", "Circle", "Ink", "Line"]
        static let deletableAnnotationTypes: Set<String> =
            ["Text", "FreeText", "Stamp", "Square", "Circle", "Ink", "Line",
             "Highlight", "Underline", "StrikeOut"]
        private var selectedAnnotation: PDFAnnotation?
        private var draggingAnnotation: PDFAnnotation?
        private var draggingAnnotationPage: PDFPage?
        private var annotationDragLastPagePoint: CGPoint?
        private var annotationDragMoved = false

        var selectedEnginePage: Int = 1
        var selectedEngineRect: String = ""
        // didSet fires on EVERY assignment, and configure() re-assigns these
        // each SwiftUI update pass. Clear only on a real true→false
        // transition — clearing on every pass silently destroyed the open
        // editor moments after each click.
        var isEditingEnabled = false {
            didSet {
                if oldValue && !isEditingEnabled {
                    clearTransientEditors()
                }
            }
        }
        var isAnnotatingEnabled = false {
            didSet {
                if oldValue && !isAnnotatingEnabled {
                    clearTransientEditors()
                }
            }
        }
        var isFillSignEnabled = false {
            didSet {
                if oldValue && !isFillSignEnabled {
                    clearTransientEditors()
                }
            }
        }
        var isRedlineEnabled = false
        var blockMoveMode = false

        private var inlineEditor: InlineEditTextView?
        private var editorOutline: EditorOutlineView?
        private var regionOverlay: RegionOverlayView?
        private var blockEditor: BlockEditorView?
        private var newTextEditor: BlockEditorView?
        private var newTextEditorSelectionID: Int?
        /// Typed text preserved across a spurious teardown of the draft
        /// editor (SwiftUI double-pass renders); keyed by selectionID.
        private var draftTextBackup: (selectionID: Int, text: String)?
        private var guideOverlay: GuideOverlayView?
        private var guideXs: [CGFloat] = []
        private var guideYs: [CGFloat] = []
        private var guidePageRect: NSRect = .zero
        // Engine-space guide sources; converted to view space at drag start
        // so guides are always correct for the current scroll and zoom.
        private var guideEngineRects: [CGRect] = []
        private var activeBlockPageIndex: Int = 0
        private var activeBlockEngineRect: CGRect = .zero
        private var scrollObservers: [NSObjectProtocol] = []
        /// Guards against SwiftUI resurrecting a locally-closed editor.
        private var lastSyncedBlockKey: String?

        deinit {
            for observer in scrollObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Keep the block editor glued to its text through scroll and zoom.
        func startTrackingScroll() {
            guard scrollObservers.isEmpty else { return }
            // PDFView's internal clip view doesn't always post bounds
            // changes; turn them on so scrolling reaches us.
            if let clipView = firstScrollView(in: self)?.contentView {
                clipView.postsBoundsChangedNotifications = true
            }
            let names: [Notification.Name] = [
                NSView.boundsDidChangeNotification,
                .PDFViewScaleChanged,
                .PDFViewPageChanged,
            ]
            for name in names {
                let observer = NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] note in
                    guard let self else { return }
                    if name == NSView.boundsDidChangeNotification {
                        guard let view = note.object as? NSView, view.isDescendant(of: self) else { return }
                    } else {
                        guard (note.object as? PDFView) === self else { return }
                    }
                    self.repositionBlockEditor()
                }
                scrollObservers.append(observer)
            }
        }

        private func firstScrollView(in view: NSView) -> NSScrollView? {
            for subview in view.subviews {
                if let scroll = subview as? NSScrollView { return scroll }
                if let found = firstScrollView(in: subview) { return found }
            }
            return nil
        }

        private func repositionBlockEditor() {
            guard let editor = blockEditor, !editor.isDragging else { return }
            guard let page = document?.page(at: activeBlockPageIndex) else { return }
            let engineRect = NSRect(
                x: activeBlockEngineRect.minX, y: activeBlockEngineRect.minY,
                width: activeBlockEngineRect.width, height: activeBlockEngineRect.height
            )
            guard let pdfKit = pdfKitRect(fromEngineRect: engineRect, page: page) else { return }
            var viewRect = convert(pdfKit, from: page)
                .insetBy(dx: -(BlockEditorView.inset + 5), dy: -BlockEditorView.inset)
            // Keep any extra height the editor grew to fit typed text.
            if editor.phase == .editing && editor.frame.height > viewRect.height {
                viewRect.size.height = editor.frame.height
            }
            if editor.frame != viewRect {
                editorLog.info("repositionBlockEditor \(editor.frame.debugDescription) -> \(viewRect.debugDescription)")
                editor.frame = viewRect
                editor.needsDisplay = true
            }
        }

        /// Rebuild guide candidates against the CURRENT geometry.
        private func rebuildGuides() {
            guard let page = document?.page(at: activeBlockPageIndex) else { return }
            guidePageRect = convert(page.bounds(for: .cropBox), from: page)
            guideXs = [guidePageRect.midX]
            guideYs = [guidePageRect.midY]
            for guideRect in guideEngineRects {
                let engineGuide = NSRect(
                    x: guideRect.minX, y: guideRect.minY,
                    width: guideRect.width, height: guideRect.height
                )
                guard let pk = pdfKitRect(fromEngineRect: engineGuide, page: page) else { continue }
                let viewGuide = convert(pk, from: page)
                guideXs.append(contentsOf: [viewGuide.minX, viewGuide.midX, viewGuide.maxX])
                guideYs.append(contentsOf: [viewGuide.minY, viewGuide.midY, viewGuide.maxY])
            }
        }
        private var lastBlockClickViewPoint: NSPoint?
        private var grabState: GrabState?
        private var lastPasteTarget: PasteTarget?
        // Grab-move alignment guides live in PDFKit PAGE coords (bottom-origin).
        private var grabGuideXs: [CGFloat] = []
        private var grabGuideYs: [CGFloat] = []
        private var lastSnappedGrabRect: NSRect?
        private var grabGuidePage: PDFPage?

        override var acceptsFirstResponder: Bool { true }

        private enum LassoPurpose {
            case grab
            case link
        }

        private enum GrabState {
            case lasso(page: PDFPage, startPagePoint: NSPoint, purpose: LassoPurpose)
            case move(page: PDFPage, originalPDFKitRect: NSRect, dragOffset: NSSize)
        }

        private struct PasteTarget {
            let page: Int
            let x: Double
            let y: Double
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let viewPoint = convert(event.locationInWindow, from: nil)

            if isEditingEnabled {
                updateLastPasteTarget(viewPoint: viewPoint)
                switch editTool {
                case .contentText:
                    // A click while the block editor is open just commits it
                    // (the first-responder change above already did); a click
                    // on plain text opens the block editor there.
                    if blockEditor != nil {
                        return
                    }
                    // Grab an existing annotation (note, text box, signature,
                    // shape) placed via Annotate/Fill & Sign — click to select
                    // (Delete removes it), drag to move it. Falls through to
                    // text editing when the click misses every annotation.
                    if let target = pageTarget(at: viewPoint),
                       let page = document?.page(at: target.pageIndex),
                       let annotation = page.annotation(at: target.pagePoint),
                       let type = annotation.type,
                       Self.deletableAnnotationTypes.contains(type) {
                        selectedAnnotation = annotation
                        if Self.movableAnnotationTypes.contains(type) {
                            draggingAnnotation = annotation
                            draggingAnnotationPage = page
                            annotationDragLastPagePoint = convert(viewPoint, to: page)
                            annotationDragMoved = false
                        }
                        return
                    }
                    selectedAnnotation = nil
                    lastBlockClickViewPoint = viewPoint
                    editorLog.info("mouseDown contentText -> editBlock at view (\(viewPoint.x), \(viewPoint.y))")
                    placeAtClick(viewPoint) { [weak self] page, x, y in
                        self?.onEditBlock?(page, x, y)
                    }
                    return
                case .grab:
                    beginGrab(at: viewPoint, purpose: .grab)
                    return
                case .link:
                    beginGrab(at: viewPoint, purpose: .link)
                    return
                case .image:
                    placeAtClick(viewPoint) { [weak self] page, x, y in
                        self?.onPlaceImage?(page, x, y)
                    }
                    return
                case .redact:
                    break // plain text selection via PDFKit
                }
            }

            if isAnnotatingEnabled {
                switch annotateTool {
                case .note:
                    // Click pins a note; dragging across text attaches one to
                    // the selection — decided on mouse up.
                    noteDownViewPoint = viewPoint
                case .textBox:
                    placeAtClick(viewPoint) { [weak self] page, x, y in
                        self?.onPlaceTextDraft?(page, x, y)
                    }
                    return
                case .signature:
                    placeAtClick(viewPoint) { [weak self] page, x, y in
                        self?.onPlaceSignature?(page, x, y)
                    }
                    return
                case .highlight, .underline, .strikeout:
                    break // plain text selection; markup applies on mouse up
                }
            }

            if isFillSignEnabled {
                switch fillSignTool {
                case .text:
                    placeAtClick(viewPoint) { [weak self] page, x, y in
                        self?.onPlaceTextDraft?(page, x, y)
                    }
                case .signature:
                    placeAtClick(viewPoint) { [weak self] page, x, y in
                        self?.onPlaceSignature?(page, x, y)
                    }
                case .check, .cross, .dot, .date:
                    placeAtClick(viewPoint) { [weak self] page, x, y in
                        self?.onFillSignClick?(page, x, y)
                    }
                }
                return
            }

            if isRedlineEnabled {
                switch redlineTool {
                case .insert:
                    placeAtClick(viewPoint) { [weak self] page, x, y in
                        self?.onRedlineCaret?(page, x, y)
                    }
                    return
                case .note:
                    if let target = pageTarget(at: viewPoint) {
                        onPlaceNote?(target.pageIndex, target.pagePoint)
                    }
                    return
                case .strikeout, .squiggly, .replace:
                    break // plain text selection; mark applies on mouse up
                }
            }

            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            let viewPoint = convert(event.locationInWindow, from: nil)

            if isEditingEnabled {
                switch editTool {
                case .contentText:
                    if let annotation = draggingAnnotation,
                       let page = draggingAnnotationPage,
                       let last = annotationDragLastPagePoint {
                        let now = convert(viewPoint, to: page)
                        let dx = now.x - last.x
                        let dy = now.y - last.y
                        if dx != 0 || dy != 0 {
                            let oldBounds = annotation.bounds
                            annotation.bounds = oldBounds.offsetBy(dx: dx, dy: dy)
                            annotationDragLastPagePoint = now
                            annotationDragMoved = true
                            let dirty = convert(oldBounds, from: page)
                                .union(convert(annotation.bounds, from: page))
                                .insetBy(dx: -6, dy: -6)
                            setNeedsDisplay(dirty)
                        }
                    }
                    return
                case .grab, .link:
                    continueGrab(to: viewPoint)
                    return
                case .image:
                    return
                case .redact:
                    break
                }
            }

            // The inline text-box editor owns this drag: letting PDFView run
            // its selection machinery here would steal first-responder focus
            // back from the editor (annotate mode is a text-selecting mode).
            if isAnnotatingEnabled, annotateTool == .textBox { return }

            super.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            let viewPoint = convert(event.locationInWindow, from: nil)

            if isEditingEnabled {
                switch editTool {
                case .contentText:
                    if draggingAnnotation != nil {
                        let moved = annotationDragMoved
                        draggingAnnotation = nil
                        draggingAnnotationPage = nil
                        annotationDragLastPagePoint = nil
                        annotationDragMoved = false
                        if moved { onAnnotationEdited?("Move Annotation") }
                    }
                    return
                case .grab, .link:
                    finishGrab(at: viewPoint)
                    return
                case .image:
                    return
                case .redact:
                    break
                }
            }

            // Text-box placement: the inline editor is already first responder
            // from mouseDown. Returning before super.mouseUp keeps PDFView's
            // selection handling from stealing focus so the caret stays live.
            if isAnnotatingEnabled, annotateTool == .textBox { return }

            super.mouseUp(with: event)

            if isAnnotatingEnabled,
               [.highlight, .underline, .strikeout].contains(annotateTool),
               let selection = currentSelection,
               let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                onMarkupSelection?(selection)
                currentSelection = nil
            }

            if isAnnotatingEnabled, annotateTool == .note, let down = noteDownViewPoint {
                noteDownViewPoint = nil
                if let selection = currentSelection,
                   let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    // Dragged across text: attach the note to the selection.
                    onNoteSelection?(selection)
                    currentSelection = nil
                } else if hypot(viewPoint.x - down.x, viewPoint.y - down.y) < 4,
                          let target = pageTarget(at: viewPoint) {
                    // Plain click: pin a note at that spot.
                    onPlaceNote?(target.pageIndex, target.pagePoint)
                }
            }

            if isRedlineEnabled,
               [.strikeout, .squiggly, .replace].contains(redlineTool),
               let selection = currentSelection,
               let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                onRedlineSelection?(selection)
                currentSelection = nil
            }
        }

        override func keyDown(with event: NSEvent) {
            // Delete / Forward-delete removes an annotation selected in Edit
            // mode (Delete=51, Fn+Delete=117).
            if isEditingEnabled, blockEditor == nil,
               editTool == .contentText,
               event.keyCode == 51 || event.keyCode == 117,
               let annotation = selectedAnnotation, let page = annotation.page {
                page.removeAnnotation(annotation)
                selectedAnnotation = nil
                setNeedsDisplay(bounds)
                onAnnotationEdited?("Delete Annotation")
                return
            }
            // Escape clears an annotation selection.
            if isEditingEnabled, editTool == .contentText,
               event.keyCode == 53, selectedAnnotation != nil {
                selectedAnnotation = nil
                return
            }
            if isEditingEnabled,
               editTool == .grab,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
               let key = event.charactersIgnoringModifiers?.lowercased() {
                switch key {
                case "c":
                    copy(self)
                    return
                case "v":
                    paste(self)
                    return
                default:
                    break
                }
            }
            // Escape deselects the grabbed region.
            if isEditingEnabled, editTool == .grab, event.keyCode == 53 {
                clearRegionOverlay()
                selectedEngineRect = ""
                onRegionChanged?(selectedEnginePage, "")
                return
            }
            super.keyDown(with: event)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard isEditingEnabled else { return }
            switch editTool {
            case .grab, .link:
                addCursorRect(bounds, cursor: .crosshair)
                if editTool == .grab,
                   let page = document?.page(at: selectedEnginePage - 1),
                   let rect = pdfKitRect(fromEngineRect: selectedEngineRect, page: page),
                   rect.width > 1 {
                    addCursorRect(convert(rect, from: page), cursor: .openHand)
                }
            case .contentText:
                addCursorRect(bounds, cursor: .iBeam)
            case .image, .redact:
                break
            }
        }

        override func copy(_ sender: Any?) {
            if isEditingEnabled,
               editTool == .grab,
               !selectedEngineRect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onCopyRegion?()
                return
            }
            super.copy(sender)
        }

        @objc func paste(_ sender: Any?) {
            guard isEditingEnabled, editTool == .grab else { return }
            if let target = lastPasteTarget {
                onPasteRegion?(target.page, target.x, target.y)
                return
            }
            if let rect = parseEngineRect(selectedEngineRect) {
                onPasteRegion?(selectedEnginePage, Double(rect.minX + 18), Double(rect.minY + 18))
            }
        }

        func syncSelectionOverlay() {
            guard isEditingEnabled,
                  editTool == .grab,
                  let page = document?.page(at: selectedEnginePage - 1),
                  let engineRect = parseEngineRect(selectedEngineRect),
                  engineRect.width > 1,
                  engineRect.height > 1 else {
                clearRegionOverlay()
                return
            }
            showRegionOverlay(page: page, engineRect: engineRect)
        }

        func clearTransientEditors() {
            editorLog.info("clearTransientEditors")
            removeInlineEditor()
            removeBlockEditorView()
            removeNewTextEditorView()
            if editTool != .grab {
                clearRegionOverlay()
            }
        }

        // MARK: Placement helpers

        private struct PageTarget {
            let pageIndex: Int
            let pagePoint: NSPoint
        }

        private func pageTarget(at viewPoint: NSPoint) -> PageTarget? {
            guard let page = page(for: viewPoint, nearest: true),
                  let document,
                  let pageIndex = optionalPageIndex(page, in: document) else { return nil }
            return PageTarget(pageIndex: pageIndex, pagePoint: convert(viewPoint, to: page))
        }

        private func placeAtClick(_ viewPoint: NSPoint, action: (Int, Double, Double) -> Void) {
            guard let page = page(for: viewPoint, nearest: true),
                  let document,
                  let pageIndex = optionalPageIndex(page, in: document) else { return }
            let pagePoint = convert(viewPoint, to: page)
            let origin = engineOrigin(fromPDFKitPoint: pagePoint, page: page)
            action(pageIndex + 1, origin.x, origin.y)
        }

        private func beginNewTextBox(at viewPoint: NSPoint) {
            removeInlineEditor()
            guard let target = pageTarget(at: viewPoint) else { return }
            let frame = NSRect(x: viewPoint.x, y: viewPoint.y - 10, width: 260, height: 22)
            let editor = InlineEditTextView(text: "", frame: frame, fontSize: 14)
            editor.commitEmptyChanges = true
            let outline = EditorOutlineView(frame: frame.insetBy(dx: -3, dy: -2))
            addSubview(outline)
            editorOutline = outline
            editor.onCommit = { [weak self] value in
                self?.removeInlineEditor()
                self?.onAddTextBox?(target.pageIndex, target.pagePoint, value)
            }
            editor.onCancel = { [weak self] in
                self?.removeInlineEditor()
            }
            addSubview(editor)
            inlineEditor = editor
            // Defer to the next runloop so it wins first responder AFTER the
            // mouseDown that created it fully settles (PDFView otherwise keeps
            // key focus and the field silently swallows no keystrokes).
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let editor else { return }
                self?.window?.makeFirstResponder(editor)
            }
        }

        // MARK: Block editor lifecycle

        func syncBlockEditor(_ snapshot: ActiveTextBlock?, guides: [CGRect] = []) {
            // Prefer the store's current value over the render snapshot.
            let block = liveActiveBlock != nil ? liveActiveBlock!() : snapshot
            guard let block else {
                lastSyncedBlockKey = nil
                blockEditor?.removeFromSuperview()
                blockEditor = nil
                return
            }
            // Keyed on the per-click selection ID: a FRESH click on the same
            // paragraph gets a new ID and always opens; only a SwiftUI
            // re-render of the already-closed selection is blocked below.
            let blockKey = "\(block.selectionID)"
            if let editor = blockEditor {
                if editor.representedRect == block.engineRect {
                    // Style panel changes: restyle the live editor.
                    editor.textView.font = Self.editorFont(for: block, scale: scaleFactor)
                    editor.textView.textColor = NSColor(engineHex: block.colorHex) ?? .black
                    Self.applyUnderline(editor.textView, block.underline)
                    // Overlay per-word color spans on top of the base color.
                    Self.applyColorRuns(editor.textView, base: NSColor(engineHex: block.colorHex) ?? .black, runs: block.colorRuns)
                    // Preview the chosen background (white cover when none).
                    editor.textView.backgroundColor = block.backgroundHex
                        .flatMap { NSColor(engineHex: $0) } ?? .white
                    return
                }
                editor.removeFromSuperview()
                blockEditor = nil
            } else if lastSyncedBlockKey == blockKey {
                // The editor for this block was closed locally (commit,
                // cancel, or move still in flight). NEVER resurrect it from
                // a SwiftUI re-render — a phantom editor over a changing
                // document commits edits against stale content.
                return
            }
            guard let page = document?.page(at: block.page - 1) else { return }
            let engineRect = NSRect(
                x: block.engineRect.minX, y: block.engineRect.minY,
                width: block.engineRect.width, height: block.engineRect.height
            )
            guard let pdfKit = pdfKitRect(fromEngineRect: engineRect, page: page) else { return }
            // Extra width headroom so the block's own text never re-wraps
            // inside the editor due to font metric differences.
            let viewRect = convert(pdfKit, from: page)
                .insetBy(dx: -(BlockEditorView.inset + 5), dy: -BlockEditorView.inset)

            editorLog.info("syncBlockEditor OPEN rect=\(block.engineRectString) text=\(String(block.originalText.prefix(30)))")
            let editor = BlockEditorView(
                frame: viewRect,
                text: block.originalText,
                font: Self.editorFont(for: block, scale: scaleFactor),
                textColor: NSColor(engineHex: block.colorHex) ?? .black
            )
            if let bg = block.backgroundHex.flatMap({ NSColor(engineHex: $0) }) {
                editor.textView.backgroundColor = bg
            }
            Self.applyUnderline(editor.textView, block.underline)
            Self.applyColorRuns(editor.textView, base: NSColor(engineHex: block.colorHex) ?? .black, runs: block.colorRuns)
            // Bridge the AppKit text selection up to the store so a Text Color
            // tap can recolor just the selected words.
            editor.textView.onSelectionChanged = { [weak self] range, length in
                self?.onBlockSelectionChanged?(range, length)
            }
            editor.representedRect = block.engineRect
            // Store mutations hop through the main queue so a commit fired
            // during a SwiftUI view update never publishes mid-update.
            // Every callback carries `block` (captured at open): by the time
            // the async hop runs, the user may have selected a different
            // paragraph, and the store must act on THIS one, not that one.
            editor.textView.onCommit = { [weak self] text in
                self?.removeBlockEditorView()
                DispatchQueue.main.async {
                    self?.onCommitBlock?(block, text)
                }
            }
            editor.textView.onCancel = { [weak self] in
                self?.removeBlockEditorView()
                DispatchQueue.main.async {
                    self?.onCancelBlock?(block)
                }
            }
            editor.onMoved = { [weak self, weak editor] newFrameOrigin in
                guard let self, let editor else { return }
                // The block's new top-left on the page is the dropped frame
                // minus the border inset. The visual TOP edge is minY only in
                // a flipped superview — PDFView is not flipped, so assuming
                // minY landed blocks one full height below the drop point.
                let content = NSRect(origin: newFrameOrigin, size: editor.frame.size)
                    .insetBy(dx: BlockEditorView.inset + 5, dy: BlockEditorView.inset)
                let contentTopLeft = NSPoint(
                    x: content.minX,
                    y: self.isFlipped ? content.minY : content.maxY
                )
                let pagePoint = self.convert(contentTopLeft, to: page)
                let origin = self.engineOrigin(fromPDFKitPoint: pagePoint, page: page)
                // Carry any typed changes along with the move, and close
                // silently FIRST so resigning focus can't fire a commit or
                // cancel that clears the active block before the move runs.
                let currentText = editor.textView.string
                editor.textView.abandon()
                self.removeBlockEditorView()
                DispatchQueue.main.async { [weak self] in
                    self?.onMoveBlock?(block, currentText, origin.x, origin.y)
                }
            }
            // Guide sources stay in engine space; view-space candidates are
            // rebuilt at each drag start so scroll/zoom never stales them.
            guideEngineRects = guides
            activeBlockPageIndex = block.page - 1
            activeBlockEngineRect = block.engineRect
            rebuildGuides()
            startTrackingScroll()
            editor.snapProvider = { [weak self] proposed in
                self?.snapFrame(proposed) ?? proposed.origin
            }
            editor.onDragBegan = { [weak self] in
                self?.rebuildGuides()
            }
            editor.onDragEnded = { [weak self] in
                self?.clearGuideOverlay()
            }

            // Cursor mode: click goes straight into typing; the frame is not
            // draggable. Hand mode: click selects, drag anywhere moves.
            editor.movable = blockMoveMode
            editor.editOnClick = false

            removeNewTextEditorView()
            addSubview(editor)
            blockEditor = editor
            lastSyncedBlockKey = blockKey
            window?.makeFirstResponder(editor)
            if !blockMoveMode {
                let windowPoint = lastBlockClickViewPoint.map { convert($0, to: nil) }
                editor.enterEditing(at: windowPoint)
            }
            lastBlockClickViewPoint = nil
            window?.invalidateCursorRects(for: editor)
        }

        private func removeBlockEditorView() {
            if blockEditor != nil {
                editorLog.info("removeBlockEditorView")
            }
            blockEditor?.removeFromSuperview()
            blockEditor = nil
            clearGuideOverlay()
        }

        // MARK: New-text editor lifecycle

        /// Mirror of syncBlockEditor for a blank text box on empty page space.
        /// Only one editor lives at a time: opening this removes any block
        /// editor, and syncBlockEditor removes this one.
        func syncNewTextEditor(_ snapshot: NewTextDraft?) {
            // Prefer the store's current value over the render snapshot.
            let draft = liveNewTextDraft != nil ? liveNewTextDraft!() : snapshot
            guard let draft else {
                removeNewTextEditorView()
                return
            }
            removeBlockEditorView()
            // Shares lastSyncedBlockKey with the block editor; the "new-" prefix
            // keeps the two keyspaces distinct.
            let key = "new-\(draft.selectionID)"
            if let editor = newTextEditor {
                if newTextEditorSelectionID == draft.selectionID {
                    // Style-panel changes on the same draft: restyle live.
                    editor.textView.font = Self.newTextFont(for: draft, scale: scaleFactor)
                    editor.textView.textColor = NSColor(engineHex: draft.colorHex) ?? .black
                    Self.applyUnderline(editor.textView, draft.underline)
                    return
                }
                editor.removeFromSuperview()
                newTextEditor = nil
            } else if lastSyncedBlockKey == key {
                // Editor was closed locally (commit/cancel in flight): never
                // resurrect it from a SwiftUI re-render.
                return
            }
            guard let page = document?.page(at: draft.page - 1) else { return }
            // Synthetic rect anchored at the click's top-left; the engine places
            // the text at that exact spot (it treats y as the line top).
            let synthetic = NSRect(x: draft.engineX, y: draft.engineY, width: 260, height: draft.fontSize * 1.6)
            guard let pdfKit = pdfKitRect(fromEngineRect: synthetic, page: page) else { return }
            let viewRect = convert(pdfKit, from: page)
                .insetBy(dx: -(BlockEditorView.inset + 5), dy: -BlockEditorView.inset)

            editorLog.info("syncNewTextEditor OPEN sel=\(draft.selectionID) at (\(draft.engineX), \(draft.engineY))")
            let restoredText = (draftTextBackup?.selectionID == draft.selectionID)
                ? (draftTextBackup?.text ?? "") : ""
            let editor = BlockEditorView(
                frame: viewRect,
                text: restoredText,
                font: Self.newTextFont(for: draft, scale: scaleFactor),
                textColor: NSColor(engineHex: draft.colorHex) ?? .black
            )
            editor.representedRect = synthetic
            editor.textView.onCommit = { [weak self] text in
                self?.removeNewTextEditorView()
                DispatchQueue.main.async {
                    self?.onCommitNewText?(draft, text)
                }
            }
            editor.textView.onCancel = { [weak self] in
                self?.removeNewTextEditorView()
                DispatchQueue.main.async {
                    self?.onCancelNewText?(draft)
                }
            }
            editor.movable = false
            editor.editOnClick = true
            Self.applyUnderline(editor.textView, draft.underline)
            addSubview(editor)
            newTextEditor = editor
            newTextEditorSelectionID = draft.selectionID
            lastSyncedBlockKey = key
            window?.makeFirstResponder(editor)
            editor.enterEditing(at: nil)
            if !restoredText.isEmpty {
                // Caret back at the end so typing continues where it left off.
                editor.textView.setSelectedRange(
                    NSRange(location: (restoredText as NSString).length, length: 0)
                )
            }
            window?.invalidateCursorRects(for: editor)
        }

        private func removeNewTextEditorView() {
            if let editor = newTextEditor {
                editorLog.info("removeNewTextEditorView")
                // If SwiftUI churn recreates this draft's editor, it must
                // come back with whatever was already typed, never empty.
                if let id = newTextEditorSelectionID, !editor.textView.string.isEmpty {
                    draftTextBackup = (id, editor.textView.string)
                }
            }
            newTextEditor?.removeFromSuperview()
            newTextEditor = nil
        }

        static func newTextFont(for draft: NewTextDraft, scale: CGFloat) -> NSFont {
            resolveFont(draft.fontName, size: max(6, draft.fontSize * Double(scale)), bold: draft.bold, italic: draft.italic)
        }

        /// Resolve a friendly family name (e.g. "Times New Roman") OR a raw
        /// engine PostScript name (e.g. "Times-Roman") to a live NSFont.
        /// NSFont(name:) only accepts PostScript names, so friendly family
        /// names must go through NSFontManager or the live preview silently
        /// falls back to the system font (looks like the font "reverted").
        static func resolveFont(_ name: String, size: CGFloat, bold: Bool, italic: Bool = false) -> NSFont {
            let manager = NSFontManager.shared
            var traits: NSFontTraitMask = bold ? .boldFontMask : []
            if italic { traits.insert(.italicFontMask) }
            let weight = bold ? 9 : 5
            func applyTraits(_ font: NSFont) -> NSFont {
                var result = font
                if bold { result = manager.convert(result, toHaveTrait: .boldFontMask) }
                if italic { result = manager.convert(result, toHaveTrait: .italicFontMask) }
                return result
            }
            if let font = manager.font(withFamily: name, traits: traits, weight: weight, size: size) {
                return font
            }
            if let byName = NSFont(name: name, size: size) {
                return applyTraits(byName)
            }
            if let base = name.split(separator: "-").first,
               let font = manager.font(withFamily: String(base), traits: traits, weight: weight, size: size) {
                return font
            }
            return applyTraits(NSFont.systemFont(ofSize: size))
        }

        // MARK: Alignment guides

        /// Snap the dragged frame to nearby block edges/centers and show
        /// blue guide lines (PDF Expert-style smart guides).
        private func snapFrame(_ proposed: NSRect) -> NSPoint {
            let content = NSRect(
                x: proposed.minX + BlockEditorView.inset + 5,
                y: proposed.minY + BlockEditorView.inset,
                width: proposed.width - (BlockEditorView.inset + 5) * 2,
                height: proposed.height - BlockEditorView.inset * 2
            )
            let threshold: CGFloat = 4
            var correctionX: CGFloat = 0
            var activeVertical: [CGFloat] = []
            var bestDx = threshold + 1
            for guide in guideXs {
                for own in [content.minX, content.midX, content.maxX] {
                    let dx = guide - own
                    if abs(dx) < abs(bestDx) && abs(dx) <= threshold {
                        bestDx = dx
                        correctionX = dx
                        activeVertical = [guide]
                    }
                }
            }
            var correctionY: CGFloat = 0
            var activeHorizontal: [CGFloat] = []
            var bestDy = threshold + 1
            for guide in guideYs {
                for own in [content.minY, content.midY, content.maxY] {
                    let dy = guide - own
                    if abs(dy) < abs(bestDy) && abs(dy) <= threshold {
                        bestDy = dy
                        correctionY = dy
                        activeHorizontal = [guide]
                    }
                }
            }
            updateGuideOverlay(vertical: activeVertical, horizontal: activeHorizontal)
            return NSPoint(x: proposed.minX + correctionX, y: proposed.minY + correctionY)
        }

        private func updateGuideOverlay(vertical: [CGFloat], horizontal: [CGFloat]) {
            if vertical.isEmpty && horizontal.isEmpty {
                clearGuideOverlay()
                return
            }
            if guideOverlay == nil {
                let overlay = GuideOverlayView(frame: bounds)
                overlay.autoresizingMask = [.width, .height]
                addSubview(overlay)
                guideOverlay = overlay
            }
            guideOverlay?.pageRect = guidePageRect
            guideOverlay?.verticalLines = vertical
            guideOverlay?.horizontalLines = horizontal
            guideOverlay?.needsDisplay = true
        }

        private func clearGuideOverlay() {
            guideOverlay?.removeFromSuperview()
            guideOverlay = nil
        }

        /// Reflect an underline choice live in an editor's text view. Commit
        /// reads `.string`, so enabling rich text here only affects display.
        static func applyUnderline(_ textView: NSTextView, _ on: Bool) {
            let value = on ? NSUnderlineStyle.single.rawValue : 0
            if on { textView.isRichText = true }
            textView.typingAttributes[.underlineStyle] = value
            if let storage = textView.textStorage, storage.length > 0 {
                storage.addAttribute(.underlineStyle, value: value, range: NSRange(location: 0, length: storage.length))
            }
        }

        static func editorFont(for block: ActiveTextBlock, scale: CGFloat) -> NSFont {
            resolveFont(block.fontFamily ?? block.fontName,
                        size: max(6, block.fontSize * Double(scale)), bold: block.bold, italic: block.italic)
        }

        /// Live-preview per-word text color: paint the whole text the base
        /// color, then overlay each run's color on its range (later runs win).
        static func applyColorRuns(_ textView: NSTextView, base: NSColor, runs: [ColorRun]) {
            guard let storage = textView.textStorage else { return }
            let length = storage.length
            guard length > 0 else { return }
            storage.addAttribute(.foregroundColor, value: base, range: NSRange(location: 0, length: length))
            for run in runs {
                let end = run.start + run.length
                guard run.start >= 0, run.length > 0, end <= length,
                      let color = NSColor(engineHex: run.hex) else { continue }
                storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: run.start, length: run.length))
            }
        }

        // MARK: Lasso / move

        private func beginGrab(at viewPoint: NSPoint, purpose: LassoPurpose) {
            removeInlineEditor()
            clearGuideOverlay()
            lastSnappedGrabRect = nil
            grabGuideXs = []
            grabGuideYs = []
            grabGuidePage = nil
            guard let page = page(for: viewPoint, nearest: true),
                  let document,
                  let pageIndex = optionalPageIndex(page, in: document) else { return }
            let pagePoint = convert(viewPoint, to: page)
            updateLastPasteTarget(page: page, pageIndex: pageIndex, pagePoint: pagePoint)

            if purpose == .grab,
               pageIndex + 1 == selectedEnginePage,
               let selectedPDFKitRect = pdfKitRect(fromEngineRect: selectedEngineRect, page: page),
               selectedPDFKitRect.contains(pagePoint) {
                let offset = NSSize(width: pagePoint.x - selectedPDFKitRect.minX, height: pagePoint.y - selectedPDFKitRect.minY)
                grabState = .move(page: page, originalPDFKitRect: selectedPDFKitRect, dragOffset: offset)
                // Build snap guides from the page's OTHER blocks (page coords).
                for engineRect in onGrabGuideRects?(pageIndex + 1) ?? [] {
                    let rect = NSRect(x: engineRect.minX, y: engineRect.minY, width: engineRect.width, height: engineRect.height)
                    guard let pk = pdfKitRect(fromEngineRect: rect, page: page) else { continue }
                    // The moved region's own text must not snap to itself.
                    if pk.intersects(selectedPDFKitRect) { continue }
                    grabGuideXs.append(contentsOf: [pk.minX, pk.midX, pk.maxX])
                    grabGuideYs.append(contentsOf: [pk.minY, pk.midY, pk.maxY])
                }
                let pb = page.bounds(for: .cropBox)
                grabGuideXs.append(pb.midX)
                grabGuideYs.append(pb.midY)
                grabGuidePage = page
            } else {
                grabState = .lasso(page: page, startPagePoint: pagePoint, purpose: purpose)
                showRegionOverlay(page: page, pdfKitRect: NSRect(origin: pagePoint, size: .zero))
            }
        }

        private func continueGrab(to viewPoint: NSPoint) {
            guard let state = grabState,
                  let page = page(for: viewPoint, nearest: true) else { return }
            let pagePoint = convert(viewPoint, to: page)

            switch state {
            case .lasso(let startPage, let startPoint, _):
                guard page === startPage else { return }
                showRegionOverlay(page: page, pdfKitRect: normalizedRect(startPoint, pagePoint))

            case .move(let startPage, let originalRect, let offset):
                guard page === startPage else { return }
                let movedOrigin = NSPoint(x: pagePoint.x - offset.width, y: pagePoint.y - offset.height)
                var movedRect = NSRect(origin: movedOrigin, size: originalRect.size)
                if page === grabGuidePage {
                    movedRect = snapGrabRect(movedRect, page: page)
                }
                lastSnappedGrabRect = movedRect
                showRegionOverlay(page: page, pdfKitRect: movedRect)
            }
        }

        /// Snap a moved region rect to nearby block edges/centers (PAGE coords)
        /// and light up the matched blue guide lines. Threshold shrinks with
        /// zoom so it stays ~4pt on screen.
        private func snapGrabRect(_ rect: NSRect, page: PDFPage) -> NSRect {
            let threshold = 4.0 / max(scaleFactor, 0.01)
            var correctionX: CGFloat = 0
            var matchedX: CGFloat?
            var bestDx = threshold + 1
            for guide in grabGuideXs {
                for own in [rect.minX, rect.midX, rect.maxX] {
                    let dx = guide - own
                    if abs(dx) < abs(bestDx) && abs(dx) <= threshold {
                        bestDx = dx
                        correctionX = dx
                        matchedX = guide
                    }
                }
            }
            var correctionY: CGFloat = 0
            var matchedY: CGFloat?
            var bestDy = threshold + 1
            for guide in grabGuideYs {
                for own in [rect.minY, rect.midY, rect.maxY] {
                    let dy = guide - own
                    if abs(dy) < abs(bestDy) && abs(dy) <= threshold {
                        bestDy = dy
                        correctionY = dy
                        matchedY = guide
                    }
                }
            }
            // GuideOverlayView draws in VIEW coords; convert the matched lines.
            var vertical: [CGFloat] = []
            if let matchedX {
                vertical = [convert(NSPoint(x: matchedX, y: 0), from: page).x]
            }
            var horizontal: [CGFloat] = []
            if let matchedY {
                horizontal = [convert(NSPoint(x: 0, y: matchedY), from: page).y]
            }
            if vertical.isEmpty && horizontal.isEmpty {
                clearGuideOverlay()
            } else {
                guidePageRect = convert(page.bounds(for: .cropBox), from: page)
                updateGuideOverlay(vertical: vertical, horizontal: horizontal)
            }
            return NSRect(
                x: rect.minX + correctionX, y: rect.minY + correctionY,
                width: rect.width, height: rect.height
            )
        }

        private func finishGrab(at viewPoint: NSPoint) {
            defer {
                grabState = nil
                lastSnappedGrabRect = nil
                grabGuideXs = []
                grabGuideYs = []
                grabGuidePage = nil
                clearGuideOverlay()
            }
            guard let state = grabState,
                  let document else { return }

            switch state {
            case .lasso(let page, let startPoint, let purpose):
                guard let pageIndex = optionalPageIndex(page, in: document),
                      let currentPage = self.page(for: viewPoint, nearest: true),
                      currentPage === page else { return }
                let pagePoint = convert(viewPoint, to: page)
                let pdfKitRect = normalizedRect(startPoint, pagePoint)
                guard pdfKitRect.width > 3, pdfKitRect.height > 3 else { return }

                switch purpose {
                case .grab:
                    let engineRect = engineRectString(fromPDFKitRect: pdfKitRect, page: page)
                    selectedEnginePage = pageIndex + 1
                    selectedEngineRect = engineRect
                    onRegionChanged?(pageIndex + 1, engineRect)
                    showRegionOverlay(page: page, pdfKitRect: pdfKitRect)
                case .link:
                    clearRegionOverlay()
                    onLinkRegion?(pageIndex, pdfKitRect)
                }

            case .move(let page, let originalRect, let offset):
                guard let pageIndex = optionalPageIndex(page, in: document),
                      let currentPage = self.page(for: viewPoint, nearest: true),
                      currentPage === page else { return }
                let pagePoint = convert(viewPoint, to: page)
                let movedOrigin = NSPoint(x: pagePoint.x - offset.width, y: pagePoint.y - offset.height)
                let movedRect = NSRect(origin: movedOrigin, size: originalRect.size)
                let snappedRect = lastSnappedGrabRect ?? movedRect
                let destination = engineOrigin(fromPDFKitRect: snappedRect, page: page)
                clearRegionOverlay()
                onMoveRegion?(pageIndex + 1, destination.x, destination.y)
            }
        }

        private func removeInlineEditor() {
            inlineEditor?.removeFromSuperview()
            inlineEditor = nil
            editorOutline?.removeFromSuperview()
            editorOutline = nil
        }

        private func showRegionOverlay(page: PDFPage, engineRect: NSRect) {
            guard let pdfKitRect = pdfKitRect(fromEngineRect: engineRect, page: page) else { return }
            showRegionOverlay(page: page, pdfKitRect: pdfKitRect)
        }

        private func showRegionOverlay(page: PDFPage, pdfKitRect: NSRect) {
            let viewRect = convert(pdfKitRect, from: page)
            if regionOverlay == nil {
                let overlay = RegionOverlayView(frame: viewRect)
                addSubview(overlay)
                regionOverlay = overlay
            } else {
                regionOverlay?.frame = viewRect
            }
        }

        private func clearRegionOverlay() {
            regionOverlay?.removeFromSuperview()
            regionOverlay = nil
        }

        private func updateLastPasteTarget(viewPoint: NSPoint) {
            guard let page = page(for: viewPoint, nearest: true),
                  let document,
                  let pageIndex = optionalPageIndex(page, in: document) else { return }
            updateLastPasteTarget(page: page, pageIndex: pageIndex, pagePoint: convert(viewPoint, to: page))
        }

        private func updateLastPasteTarget(page: PDFPage, pageIndex: Int, pagePoint: NSPoint) {
            let origin = engineOrigin(fromPDFKitPoint: pagePoint, page: page)
            lastPasteTarget = PasteTarget(page: pageIndex + 1, x: origin.x, y: origin.y)
        }

        private func optionalPageIndex(_ page: PDFPage, in document: PDFDocument) -> Int? {
            let index = document.index(for: page)
            return index == NSNotFound ? nil : index
        }

        private func normalizedRect(_ first: NSPoint, _ second: NSPoint) -> NSRect {
            NSRect(
                x: min(first.x, second.x),
                y: min(first.y, second.y),
                width: abs(first.x - second.x),
                height: abs(first.y - second.y)
            )
        }

        private func engineRectString(fromPDFKitRect rect: NSRect, page: PDFPage) -> String {
            let bounds = page.bounds(for: .cropBox)
            let x0 = rect.minX - bounds.minX
            let x1 = rect.maxX - bounds.minX
            let y0 = bounds.maxY - rect.maxY
            let y1 = bounds.maxY - rect.minY
            return "\(x0),\(y0),\(x1),\(y1)"
        }

        private func engineOrigin(fromPDFKitRect rect: NSRect, page: PDFPage) -> (x: Double, y: Double) {
            let bounds = page.bounds(for: .cropBox)
            return (Double(rect.minX - bounds.minX), Double(bounds.maxY - rect.maxY))
        }

        private func engineOrigin(fromPDFKitPoint point: NSPoint, page: PDFPage) -> (x: Double, y: Double) {
            let bounds = page.bounds(for: .cropBox)
            return (Double(point.x - bounds.minX), Double(bounds.maxY - point.y))
        }

        private func pdfKitRect(fromEngineRect text: String, page: PDFPage) -> NSRect? {
            guard let rect = parseEngineRect(text) else { return nil }
            return pdfKitRect(fromEngineRect: rect, page: page)
        }

        private func pdfKitRect(fromEngineRect rect: NSRect, page: PDFPage) -> NSRect? {
            let bounds = page.bounds(for: .cropBox)
            let x0 = bounds.minX + rect.minX
            let x1 = bounds.minX + rect.maxX
            let y0 = bounds.maxY - rect.maxY
            let y1 = bounds.maxY - rect.minY
            return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }

        private func parseEngineRect(_ text: String) -> NSRect? {
            let values = text
                .split(separator: ",")
                .map { CGFloat(Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan) }
            guard values.count == 4, values.allSatisfy({ $0.isFinite }) else { return nil }
            let x0 = min(values[0], values[2])
            let y0 = min(values[1], values[3])
            let x1 = max(values[0], values[2])
            let y1 = max(values[1], values[3])
            return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }

    func makeNSView(context: Context) -> PDFView {
        let view = EditingPDFView()
        configure(view, context: context)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor.underPageBackgroundColor
        view.document = document
        pdfViewProxy.pdfView = view
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewSelectionChanged,
            object: view,
            queue: .main
        ) { notification in
            guard let pdfView = notification.object as? PDFView else { return }
            if let selection = pdfView.currentSelection {
                updateSelection(selection, pdfView: pdfView, coordinator: context.coordinator)
            } else {
                context.coordinator.selectedText.wrappedValue = ""
                context.coordinator.selectedRect.wrappedValue = ""
            }
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.selectedText = $selectedText
        context.coordinator.selectedPage = $selectedPage
        context.coordinator.selectedRect = $selectedRect
        if let editingView = nsView as? EditingPDFView {
            configure(editingView, context: context)
            editingView.selectedEnginePage = selectedPage
            editingView.selectedEngineRect = selectedRect
            editingView.syncSelectionOverlay()
            editingView.syncBlockEditor(activeBlock, guides: activeBlockGuides)
            // The store keeps activeBlock and newTextDraft mutually
            // exclusive; pass the draft straight through so a stale render
            // pass can never deliver a spurious nil that tears the editor
            // down mid-typing.
            editingView.syncNewTextEditor(newTextDraft)
            editingView.window?.invalidateCursorRects(for: editingView)
        }
        if nsView.document !== document {
            nsView.document = document
            if let editingView = nsView as? EditingPDFView {
                editingView.clearTransientEditors()
            }
        }
        nsView.autoScales = true
        pdfViewProxy.pdfView = nsView
    }

    private func configure(_ view: EditingPDFView, context: Context) {
        view.isEditingEnabled = isEditing
        view.isAnnotatingEnabled = isAnnotating
        view.isFillSignEnabled = isFillSign
        view.isRedlineEnabled = isRedline
        view.blockMoveMode = blockMoveMode
        view.editTool = editTool
        view.annotateTool = annotateTool
        view.fillSignTool = fillSignTool
        view.redlineTool = redlineTool
        view.onTextSelectionChanged = { selection, pdfView in
            updateSelection(selection, pdfView: pdfView, coordinator: context.coordinator)
        }
        view.onRegionChanged = { page, rect in
            updateRegionSelection(page: page, rect: rect, coordinator: context.coordinator)
        }
        view.onEditBlock = onEditBlock
        view.onCommitBlock = onCommitBlock
        view.onCancelBlock = onCancelBlock
        view.onMoveBlock = onMoveBlock
        view.onCommitNewText = onCommitNewText
        view.onCancelNewText = onCancelNewText
        view.onBlockSelectionChanged = onBlockSelectionChanged
        view.onCopyRegion = onCopyRegion
        view.onPasteRegion = onPasteRegion
        view.onMoveRegion = onMoveRegion
        view.onGrabGuideRects = onGrabGuideRects
        view.liveActiveBlock = liveActiveBlock
        view.liveNewTextDraft = liveNewTextDraft
        view.onMarkupSelection = onMarkupSelection
        view.onPlaceNote = onPlaceNote
        view.onAddTextBox = onAddTextBox
        view.onPlaceSignature = onPlaceSignature
        view.onPlaceImage = onPlaceImage
        view.onPlaceTextDraft = onPlaceTextDraft
        view.onLinkRegion = onLinkRegion
        view.onFillSignClick = onFillSignClick
        view.onRedlineSelection = onRedlineSelection
        view.onRedlineCaret = onRedlineCaret
        view.onNoteSelection = onNoteSelection
        view.onAnnotationEdited = onAnnotationEdited
    }

    private func updateSelection(_ selection: PDFSelection, pdfView: PDFView, coordinator: Coordinator) {
        let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        coordinator.selectedText.wrappedValue = text
        guard let page = selection.pages.first, let document = pdfView.document, !text.isEmpty else {
            coordinator.selectedRect.wrappedValue = ""
            return
        }
        coordinator.selectedPage.wrappedValue = document.index(for: page) + 1
        let bounds = selection.bounds(for: page)
        coordinator.selectedRect.wrappedValue = engineRectString(fromPDFKitRect: bounds, page: page)
    }

    private func updateRegionSelection(page: Int, rect: String, coordinator: Coordinator) {
        coordinator.selectedText.wrappedValue = ""
        coordinator.selectedPage.wrappedValue = page
        coordinator.selectedRect.wrappedValue = rect
    }

    private func engineRectString(fromPDFKitRect rect: NSRect, page: PDFPage) -> String {
        let pageBounds = page.bounds(for: .cropBox)
        let x0 = rect.minX - pageBounds.minX
        let x1 = rect.maxX - pageBounds.minX
        let y0 = pageBounds.maxY - rect.maxY
        let y1 = pageBounds.maxY - rect.minY
        return "\(x0),\(y0),\(x1),\(y1)"
    }
}

extension Color {
    /// Engine "#rrggbb" hex for a SwiftUI color (via sRGB).
    var engineHex: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "#%02x%02x%02x",
            Int(round(ns.redComponent * 255)),
            Int(round(ns.greenComponent * 255)),
            Int(round(ns.blueComponent * 255))
        )
    }
}

extension NSColor {
    /// Parse the engine's "#rrggbb" color strings.
    convenience init?(engineHex: String) {
        var raw = engineHex
        if raw.hasPrefix("#") {
            raw = String(raw.dropFirst())
        }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 255) / 255.0,
            green: CGFloat((value >> 8) & 255) / 255.0,
            blue: CGFloat(value & 255) / 255.0,
            alpha: 1
        )
    }
}
