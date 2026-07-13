import AppKit
import SwiftUI

// MARK: - Rendering signatures to transparent PNGs

/// Renders drawn strokes and typed cursive names into tight-cropped,
/// transparent-background black-ink PNGs — the images stamped onto pages.
enum SignatureRenderer {
    /// Stroke paths (top-left origin points) → transparent PNG, tight-cropped
    /// to the drawn bounding box plus a little padding.
    static func strokesPNG(strokes: [[CGPoint]], lineWidth: CGFloat = 2.4, padding: CGFloat = 10) -> Data? {
        let points = strokes.flatMap { $0 }
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let width = (maxX - minX) + padding * 2
        let height = (maxY - minY) + padding * 2
        guard width > 1, height > 1 else { return nil }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocusFlipped(true) // top-left origin matches captured points
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for stroke in strokes {
            guard let start = stroke.first else { continue }
            let origin = NSPoint(x: start.x - minX + padding, y: start.y - minY + padding)
            path.move(to: origin)
            if stroke.count == 1 {
                // A single tap: draw a tiny dot so it still shows.
                path.line(to: NSPoint(x: origin.x + 0.2, y: origin.y + 0.2))
            } else {
                for p in stroke.dropFirst() {
                    path.line(to: NSPoint(x: p.x - minX + padding, y: p.y - minY + padding))
                }
            }
        }
        NSColor.black.setStroke()
        path.stroke()
        image.unlockFocus()
        return pngData(from: image)
    }

    /// A typed name rendered in a cursive/script font → transparent PNG.
    static func cursivePNG(text: String, font: NSFont, padding: CGFloat = 14) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let string = NSAttributedString(string: trimmed, attributes: attributes)
        let size = string.size()
        let width = ceil(size.width) + padding * 2
        let height = ceil(size.height) + padding * 2
        guard width > 1, height > 1 else { return nil }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocusFlipped(true)
        string.draw(at: NSPoint(x: padding, y: padding))
        image.unlockFocus()
        return pngData(from: image)
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Cursive/script faces available on macOS, best first: Snell Roundhand
    /// (bold), Zapfino, any Script/Brush/Hand family, italic system fallback.
    static func cursiveFonts(size: CGFloat) -> [(name: String, font: NSFont)] {
        var result: [(name: String, font: NSFont)] = []
        if let bold = NSFont(name: "SnellRoundhand-Bold", size: size) {
            result.append((name: "Snell Roundhand", font: bold))
        } else if let plain = NSFont(name: "SnellRoundhand", size: size) {
            result.append((name: "Snell Roundhand", font: plain))
        }
        if let zapfino = NSFont(name: "Zapfino", size: size * 0.62) {
            result.append((name: "Zapfino", font: zapfino))
        }
        let manager = NSFontManager.shared
        for family in manager.availableFontFamilies where result.count < 4 {
            let lowered = family.lowercased()
            guard lowered.contains("script") || lowered.contains("brush") || lowered.contains("hand") else { continue }
            if result.contains(where: { $0.name == family }) { continue }
            if let font = manager.font(withFamily: family, traits: [], weight: 5, size: size) {
                result.append((name: family, font: font))
            }
        }
        if result.isEmpty {
            let italic = manager.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
            result.append((name: "Handwritten", font: italic))
        }
        return result
    }
}

// MARK: - Drawing canvas (AppKit)

/// Captures mouse/trackpad strokes into paths and renders them (transparent
/// background) via SignatureRenderer.
final class SignatureDrawView: NSView {
    private(set) var strokes: [[CGPoint]] = []
    private var currentStroke: [CGPoint] = []
    var onChange: (() -> Void)?
    let lineWidth: CGFloat = 2.4

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for stroke in strokes { append(stroke, to: path) }
        append(currentStroke, to: path)
        NSColor.black.setStroke()
        path.stroke()
    }

    private func append(_ stroke: [CGPoint], to path: NSBezierPath) {
        guard let first = stroke.first else { return }
        path.move(to: first)
        if stroke.count == 1 {
            path.line(to: NSPoint(x: first.x + 0.2, y: first.y + 0.2))
        } else {
            for p in stroke.dropFirst() { path.line(to: p) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        currentStroke = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentStroke.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if !currentStroke.isEmpty { strokes.append(currentStroke) }
        currentStroke = []
        needsDisplay = true
        onChange?()
    }

    func clear() {
        strokes = []
        currentStroke = []
        needsDisplay = true
        onChange?()
    }

    var hasInk: Bool { !strokes.isEmpty || !currentStroke.isEmpty }

    func pngData() -> Data? {
        SignatureRenderer.strokesPNG(strokes: strokes, lineWidth: lineWidth)
    }
}

/// Bridges the AppKit drawing view to SwiftUI (Clear / Save / hasInk).
final class SignatureDrawController: ObservableObject {
    weak var view: SignatureDrawView?
    @Published var hasInk = false

    func clear() { view?.clear() }
    func pngData() -> Data? { view?.pngData() }
}

struct SignatureCanvas: NSViewRepresentable {
    let controller: SignatureDrawController

    func makeNSView(context: Context) -> SignatureDrawView {
        let view = SignatureDrawView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.layer?.cornerRadius = 8
        view.onChange = { [weak controller] in
            controller?.hasInk = controller?.view?.hasInk ?? false
        }
        controller.view = view
        return view
    }

    func updateNSView(_ nsView: SignatureDrawView, context: Context) {}
}

// MARK: - Signature Manager sheet

struct SignatureManagerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case saved = "Saved"
        case draw = "Draw"
        case type = "Type"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .draw
    @State private var typedName: String = ""
    @State private var cursiveIndex: Int = 0
    /// Bumped after a save/delete so the Saved gallery re-reads the folder.
    @State private var galleryToken = 0
    @StateObject private var drawController = SignatureDrawController()

    private let cursiveFonts = SignatureRenderer.cursiveFonts(size: 44)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Signatures")
                    .font(.headline)
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            Divider()

            switch mode {
            case .saved: savedGallery
            case .draw: drawTab
            case .type: typeTab
            }

            Divider()

            HStack {
                Text("Pick a signature, then click the page to place it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .onAppear {
            if !store.savedSignatures().isEmpty { mode = .saved }
            if typedName.isEmpty {
                typedName = store.signatureText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // MARK: Saved gallery

    private var savedGallery: some View {
        let signatures = store.savedSignatures()
        return Group {
            if signatures.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "signature")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No saved signatures yet")
                        .foregroundStyle(.secondary)
                    Button("Draw a Signature") { mode = .draw }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(signatures, id: \.self) { url in
                            signatureCell(url)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .id(galleryToken)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signatureCell(_ url: URL) -> some View {
        let isActive = store.activeSignatureURL?.path == url.path
        return VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    } else {
                        Image(systemName: "questionmark.square.dashed")
                    }
                }
                .frame(height: 70)
                .frame(maxWidth: .infinity)
                .background(Color.white)

                Button {
                    store.deleteSignature(url)
                    galleryToken += 1
                } label: {
                    Image(systemName: "trash.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Delete this signature")
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.accentColor : Color.black.opacity(0.15),
                            lineWidth: isActive ? 2.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.setActiveSignature(url)
        }
        .help(isActive ? "Active signature" : "Click to make active")
    }

    // MARK: Draw tab

    private var drawTab: some View {
        VStack(spacing: 10) {
            SignatureCanvas(controller: drawController)
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .overlay(alignment: .bottom) {
                    Text("Draw your signature here")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 6)
                        .allowsHitTesting(false)
                        .opacity(drawController.hasInk ? 0 : 1)
                }
            HStack {
                Button("Clear") { drawController.clear() }
                    .disabled(!drawController.hasInk)
                Spacer()
                Button("Save Signature") { saveDrawn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!drawController.hasInk)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveDrawn() {
        guard let data = drawController.pngData() else { return }
        store.saveSignaturePNG(data)
        drawController.clear()
        galleryToken += 1
        mode = .saved
    }

    // MARK: Type (cursive) tab

    private var typeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Type your name", text: $typedName)
                .textFieldStyle(.roundedBorder)

            if cursiveFonts.count > 1 {
                Picker("Style", selection: $cursiveIndex) {
                    ForEach(Array(cursiveFonts.enumerated()), id: \.offset) { index, entry in
                        Text(entry.name).tag(index)
                    }
                }
                .pickerStyle(.segmented)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                RoundedRectangle(cornerRadius: 8).stroke(.quaternary)
                if let preview = cursivePreview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else {
                    Text("Preview")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 120)

            HStack {
                Spacer()
                Button("Save Signature") { saveTyped() }
                    .buttonStyle(.borderedProminent)
                    .disabled(typedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cursiveFonts.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var selectedCursiveFont: NSFont? {
        guard cursiveFonts.indices.contains(cursiveIndex) else { return cursiveFonts.first?.font }
        return cursiveFonts[cursiveIndex].font
    }

    private var cursivePreview: NSImage? {
        guard let font = selectedCursiveFont,
              let data = SignatureRenderer.cursivePNG(text: typedName, font: font) else { return nil }
        return NSImage(data: data)
    }

    private func saveTyped() {
        guard let font = selectedCursiveFont,
              let data = SignatureRenderer.cursivePNG(text: typedName, font: font) else { return }
        store.signatureText = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveSignaturePNG(data)
        galleryToken += 1
        mode = .saved
    }
}
