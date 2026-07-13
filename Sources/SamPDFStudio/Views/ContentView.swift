import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isPDFDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TopBarView()
            Divider()

            if store.document != nil && store.selectedOperation != .read {
                ToolStripView()
                Divider()
            }

            HStack(spacing: 0) {
                if store.showSidebar, store.document != nil, store.selectedOperation != .pages {
                    PDFThumbnailRailView()
                        .frame(width: 168)
                        .background(Color(nsColor: .underPageBackgroundColor))
                    Divider()
                }

                PDFWorkspaceView()
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.activeBlock != nil || store.newTextDraft != nil {
                TextStylePanel()
                    .padding(.top, 96)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if !store.lastMessage.isEmpty {
                ToastView(message: store.lastMessage)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.lastMessage.isEmpty)
        .overlay {
            if isPDFDropTargeted {
                DropOverlayView()
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier],
            isTargeted: $isPDFDropTargeted
        ) { providers in
            store.loadDroppedPDFProviders(providers)
        }
        .sheet(item: $store.pendingNote) { _ in
            NoteSheetView()
        }
        .sheet(item: $store.pendingLink) { _ in
            LinkSheetView()
        }
        .sheet(item: $store.pendingRedlineReplace) { _ in
            RedlineReplaceSheetView()
        }
        .sheet(isPresented: $store.showPasswordSheet) {
            PasswordSheetView()
        }
        .sheet(isPresented: $store.showSignatureManager) {
            SignatureManagerView()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

// MARK: - Top bar

private struct TopBarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.showSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Show or hide page thumbnails")
            .disabled(store.document == nil)

            Button {
                store.openPDF()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open a PDF (⌘O)")

            Spacer(minLength: 8)

            Picker("", selection: modeBinding) {
                ForEach(PDFOperation.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 560)
            .disabled(store.document == nil)

            Spacer(minLength: 8)

            if store.busy {
                ProgressView()
                    .controlSize(.small)
                Text(store.busyTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                store.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Undo (⌘Z)")
            .disabled(!store.canUndo || store.busy)

            Button {
                store.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .help("Redo (⇧⌘Z)")
            .disabled(!store.canRedo || store.busy)

            ExportMenuView()

            Button {
                store.save()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                    if store.isDirty {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .help("Save changes to the original file (⌘S)")
            .disabled(store.document == nil || !store.isDirty || store.busy)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var modeBinding: Binding<PDFOperation> {
        Binding(
            get: { store.selectedOperation },
            set: { store.selectedOperation = $0 }
        )
    }
}

private struct ExportMenuView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Menu {
            Button("PDF Copy…") { store.exportPDFCopy() }
            Divider()
            Button("Word…") { store.exportOffice(.word) }
            Button("Excel…") { store.exportOffice(.excel) }
            Button("PowerPoint…") { store.exportOffice(.powerpoint) }
            Divider()
            Button("Text…") { store.exportText(.text) }
            Button("Markdown…") { store.exportText(.markdown) }
            Button("HTML…") { store.exportText(.html) }
            Divider()
            Button("PNG Images…") { store.exportImages(.png) }
            Button("JPG Images…") { store.exportImages(.jpg) }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .help("Export")
        .disabled(store.document == nil || store.busy)
    }
}

// MARK: - Tool strip

private struct ToolStripView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            switch store.selectedOperation {
            case .read:
                EmptyView()
            case .annotate:
                annotateTools
            case .fillSign:
                fillSignTools
            case .edit:
                editTools
            case .redline:
                redlineTools
            case .pages:
                pageTools
            case .scanOCR:
                ocrTools
            }
            Spacer()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private static let markupSwatches: [(name: String, hex: String)] = [
        ("Yellow", "#f7d648"), ("Green", "#7ed957"), ("Blue", "#6db5f2"),
        ("Pink", "#f79ac0"), ("Orange", "#f5a742"),
        ("White", "#ffffff"), ("Grey", "#888888"), ("Black", "#111111"),
    ]

    @ViewBuilder
    private var annotateTools: some View {
        ForEach(AnnotateTool.allCases) { tool in
            ToolButton(
                title: tool.title,
                systemImage: tool.systemImage,
                isSelected: store.selectedAnnotateTool == tool
            ) {
                store.selectedAnnotateTool = tool
            }
        }

        if [.highlight, .underline, .strikeout].contains(store.selectedAnnotateTool) {
            Divider().frame(height: 20)
            HStack(spacing: 6) {
                ForEach(Self.markupSwatches, id: \.hex) { swatch in
                    Button {
                        store.markupColorHex = store.markupColorHex == swatch.hex ? "" : swatch.hex
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(engineHex: swatch.hex) ?? .yellow))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().stroke(
                                    store.markupColorHex == swatch.hex ? Color.accentColor : Color.black.opacity(0.2),
                                    lineWidth: store.markupColorHex == swatch.hex ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(swatch.name) — click again for the tool default")
                }
            }
        }

        if store.selectedAnnotateTool == .signature {
            Divider().frame(height: 20)
            SignatureStripControls()
        }
    }

    @ViewBuilder
    private var fillSignTools: some View {
        ForEach(FillSignTool.allCases) { tool in
            ToolButton(
                title: tool.title,
                systemImage: tool.systemImage,
                isSelected: store.selectedFillSignTool == tool
            ) {
                store.selectedFillSignTool = tool
            }
        }

        if store.selectedFillSignTool == .signature {
            Divider().frame(height: 20)
            SignatureStripControls()
        }
    }

    @ViewBuilder
    private var redlineTools: some View {
        ForEach(RedlineTool.allCases) { tool in
            ToolButton(
                title: tool.title,
                systemImage: tool.systemImage,
                isSelected: store.selectedRedlineTool == tool
            ) {
                store.selectedRedlineTool = tool
            }
        }
    }

    @ViewBuilder
    private var editTools: some View {
        ForEach(EditTool.allCases) { tool in
            ToolButton(
                title: tool.title,
                systemImage: tool.systemImage,
                isSelected: store.selectedEditTool == tool
            ) {
                store.selectedEditTool = tool
            }
        }

        Divider().frame(height: 20)

        switch store.selectedEditTool {
        case .contentText:
            Picker("", selection: $store.blockMoveMode) {
                Image(systemName: "character.cursor.ibeam").tag(false)
                    .help("Cursor: click text to type into it")
                Image(systemName: "hand.point.up.left").tag(true)
                    .help("Hand: click a paragraph and drag it anywhere")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)
            .help("Cursor edits text · Hand moves blocks")

            Toggle("Track Changes", isOn: $store.trackChanges)
                .toggleStyle(.checkbox)
                .help("Edits leave a dashed review box holding the original wording")
        case .grab:
            Button {
                store.copySelectedRegion()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(store.selectedPDFRect.isEmpty || store.busy)

            Button {
                store.pasteCopiedRegionAtSelection()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .disabled(!store.hasCopiedRegion || store.busy)

        case .image:
            Button {
                store.chooseImageForInsert()
            } label: {
                Label(store.pendingImageURL?.lastPathComponent ?? "Choose Image…", systemImage: "photo.badge.plus")
            }
            .disabled(store.busy)

        case .redact:
            Button(role: .destructive) {
                store.redactSelectedText()
            } label: {
                Label("Redact Selection", systemImage: "eye.slash.fill")
            }
            .disabled((store.selectedPDFText.isEmpty && store.redactFindText.isEmpty) || store.busy)

        case .link:
            EmptyView()
        }
    }

    @ViewBuilder
    private var pageTools: some View {
        Button {
            store.appendPDFs()
        } label: {
            Label("Add PDFs…", systemImage: "plus.rectangle.on.rectangle")
        }
        .disabled(store.busy)

        Button {
            store.newFromImages()
        } label: {
            Label("New from Images…", systemImage: "photo.on.rectangle.angled")
        }
        .disabled(store.busy)

        Divider().frame(height: 20)

        PageNumbersMenuView()
        ResizePagesMenuView()

        Divider().frame(height: 20)

        Button {
            store.insertBlankPage()
        } label: {
            Label("Insert Page", systemImage: "plus.rectangle.portrait")
        }
        .disabled(store.busy)

        Button {
            store.copySelectedPages()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(store.selectedPageIndices.isEmpty || store.busy)

        Button {
            store.pasteCopiedPages()
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(!store.hasCopiedPages || store.busy)

        Divider().frame(height: 20)

        Button {
            store.rotateSelectedPages()
        } label: {
            Label("Rotate", systemImage: "rotate.right")
        }
        .disabled(store.selectedPageIndices.isEmpty || store.busy)

        Button {
            store.extractSelectedPages()
        } label: {
            Label("Extract…", systemImage: "square.and.arrow.up.on.square")
        }
        .disabled(store.selectedPageIndices.isEmpty || store.busy)

        Button(role: .destructive) {
            store.deleteSelectedPages()
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(store.selectedPageIndices.isEmpty || store.busy)
    }

    @ViewBuilder
    private var ocrTools: some View {
        Button {
            store.runOCR(currentPageOnly: false)
        } label: {
            Label("Recognize Text", systemImage: "text.viewfinder")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(store.busy)

        Button {
            store.runOCR(currentPageOnly: true)
        } label: {
            Label("This Page Only", systemImage: "doc.text.viewfinder")
        }
        .disabled(store.busy)

        Divider().frame(height: 20)

        TextField("Language", text: $store.ocrLanguage)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            .help("OCR language code, e.g. eng")

        Toggle("Re-run OCR", isOn: $store.forceOCR)
            .toggleStyle(.checkbox)
            .help("Recognize again even if the PDF already has text")

        Divider().frame(height: 20)

        EnhanceScanMenuView()
    }

    private var hint: String {
        switch store.selectedOperation {
        case .read:
            return ""
        case .fillSign:
            switch store.selectedFillSignTool {
            case .text: return "Click the page, type, then press Return"
            case .check, .cross, .dot: return "Click the page to stamp a \(store.selectedFillSignTool.title.lowercased())"
            case .date: return "Click the page to stamp today's date"
            case .signature: return "Click the page to place your signature"
            }
        case .redline:
            switch store.selectedRedlineTool {
            case .strikeout, .squiggly: return "Drag across text to mark it"
            case .insert: return "Click where text should be inserted"
            case .replace: return "Drag across text, then type the replacement note"
            case .note: return "Click the page to add a review note"
            }
        case .annotate:
            switch store.selectedAnnotateTool {
            case .highlight, .underline, .strikeout:
                return "Drag across text to \(store.selectedAnnotateTool.title.lowercased()) it"
            case .note:
                return "Click to pin a note · drag across text to attach one to it"
            case .textBox:
                return "Click the page, type, then press Return"
            case .signature:
                return "Click the page to place your signature"
            }
        case .edit:
            if store.selectedEditTool == .contentText {
                return store.blockMoveMode
                    ? "Hand: click a paragraph, then drag it anywhere — blue guides help you align"
                    : "Cursor: click text and type — switch to the hand to move blocks"
            }
            return store.selectedEditTool.help
        case .pages:
            return "Click pages to select · drag to reorder · double-click to open"
        case .scanOCR:
            return "Makes scanned pages searchable and selectable"
        }
    }
}

private struct ToolButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isSelected ? Color.accentColor : nil)
    }
}

/// Sign-tool strip: the active signature thumbnail plus a button to open the
/// Signature Manager (draw / type cursive / pick a saved one).
private struct SignatureStripControls: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            if let url = store.activeSignatureURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 22)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    .help("Active signature — click the page to place it")
            }
            Button {
                store.showSignatureManager = true
            } label: {
                Label(store.activeSignatureURL == nil ? "Create Signature…" : "Signatures…",
                      systemImage: "signature")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

private struct PageNumbersMenuView: View {
    @EnvironmentObject private var store: AppStore
    @State private var show = false
    @State private var position = "bottom-center"
    @State private var format = "n"
    @State private var start = 1

    private static let positions: [(String, String)] = [
        ("bottom-center", "Bottom Center"), ("bottom-left", "Bottom Left"), ("bottom-right", "Bottom Right"),
        ("top-center", "Top Center"), ("top-left", "Top Left"), ("top-right", "Top Right"),
    ]
    private static let formats: [(String, String)] = [
        ("n", "1, 2, 3"), ("page-n", "Page 1"), ("n-of-total", "1 of 12"),
    ]

    var body: some View {
        Button {
            show.toggle()
        } label: {
            Label("Page Numbers…", systemImage: "number")
        }
        .disabled(store.busy)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Position", selection: $position) {
                    ForEach(Self.positions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                Picker("Style", selection: $format) {
                    ForEach(Self.formats, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                Stepper("Start at \(start)", value: $start, in: 1...9999)
                Button("Add Page Numbers") {
                    show = false
                    store.addPageNumbers(position: position, format: format, start: start)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
            .frame(width: 260)
        }
    }
}

private struct ResizePagesMenuView: View {
    @EnvironmentObject private var store: AppStore
    @State private var show = false
    @State private var selection = "letter"

    // Width x height in PDF points.
    private static let presets: [(id: String, name: String, width: Double, height: Double)] = [
        ("letter", "Letter (8.5 × 11 in)", 612, 792),
        ("legal", "Legal (8.5 × 14 in)", 612, 1008),
        ("a4", "A4 (210 × 297 mm)", 595, 842),
        ("a5", "A5 (148 × 210 mm)", 420, 595),
    ]

    var body: some View {
        Button {
            show.toggle()
        } label: {
            Label("Resize Pages…", systemImage: "aspectratio")
        }
        .disabled(store.busy)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Make every page the same size")
                    .font(.headline)
                Picker("Size", selection: $selection) {
                    ForEach(Self.presets, id: \.id) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Content is scaled to fit and centered — handy after merging PDFs of different sizes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Resize All Pages") {
                    show = false
                    if let preset = Self.presets.first(where: { $0.id == selection }) {
                        store.resizePages(width: preset.width, height: preset.height, presetName: preset.name)
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
            .frame(width: 290)
        }
    }
}

private struct EnhanceScanMenuView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showOptions = false

    var body: some View {
        Button {
            showOptions.toggle()
        } label: {
            Label("Enhance Scan", systemImage: "wand.and.stars")
        }
        .disabled(store.busy)
        .popover(isPresented: $showOptions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Grayscale", isOn: $store.enhanceGrayscale)
                Toggle("Denoise", isOn: $store.enhanceDenoise)
                LabeledContent("Contrast") {
                    Slider(value: $store.enhanceContrast, in: 0.8...2.0, step: 0.05)
                        .frame(width: 140)
                }
                LabeledContent("Sharpness") {
                    Slider(value: $store.enhanceSharpness, in: 0.8...2.0, step: 0.05)
                        .frame(width: 140)
                }
                Button("Enhance") {
                    showOptions = false
                    store.enhanceScan()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
            .frame(width: 260)
        }
    }
}

// MARK: - Text style panel (shown while a text block is being edited)

private struct TextStylePanel: View {
    @EnvironmentObject private var store: AppStore

    private static let swatches: [(name: String, hex: String)] = [
        ("Black", "#111111"), ("Dark Gray", "#555555"), ("Gray", "#888888"),
        ("White", "#ffffff"), ("Red", "#c0392b"), ("Blue", "#1a5fb4"),
    ]

    private static let backgroundSwatches: [(name: String, hex: String)] = [
        ("Yellow", "#fff3b0"), ("Green", "#dcf2d0"), ("Blue", "#d7e8fb"),
        ("Pink", "#fbdde9"), ("Gray", "#ececec"), ("White", "#ffffff"),
    ]

    @ViewBuilder
    var body: some View {
        if store.activeBlock != nil {
            blockPanel
        } else if store.newTextDraft != nil {
            newTextPanel
        }
    }

    @ViewBuilder
    private var blockPanel: some View {
        if let block = store.activeBlock {
            VStack(alignment: .leading, spacing: 12) {
                Text("Text")
                    .font(.headline)

                Picker("Font", selection: Binding<String?>(
                    get: { store.activeBlock?.fontFamily },
                    set: { store.setActiveBlockFont($0) }
                )) {
                    Text("Original (\(displayFontName(block.fontName)))").tag(String?.none)
                    ForEach(AppStore.newTextFontChoices, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                    Divider()
                    ForEach(AppStore.allFontFamilies, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Size")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { store.activeBlock?.fontSize ?? 12 },
                            set: { store.activeBlock?.fontSize = max(6, min(96, $0)) }
                        ),
                        step: 1
                    ) {
                        Text("\(Int(block.fontSize)) pt")
                            .monospacedDigit()
                    }
                }

                HStack(spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { store.activeBlock?.bold ?? false },
                        set: { store.activeBlock?.bold = $0 }
                    )) { Image(systemName: "bold") }
                        .help("Bold")
                    Toggle(isOn: Binding(
                        get: { store.activeBlock?.italic ?? false },
                        set: { store.activeBlock?.italic = $0 }
                    )) { Image(systemName: "italic") }
                        .help("Italic")
                    Toggle(isOn: Binding(
                        get: { store.activeBlock?.underline ?? false },
                        set: { store.activeBlock?.underline = $0 }
                    )) { Image(systemName: "underline") }
                        .help("Underline")
                }
                .toggleStyle(.button)

                Picker("", selection: Binding(
                    get: { store.activeBlock?.alignment ?? "left" },
                    set: { store.activeBlock?.alignment = $0 }
                )) {
                    Image(systemName: "text.alignleft").tag("left")
                    Image(systemName: "text.aligncenter").tag("center")
                    Image(systemName: "text.alignright").tag("right")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Alignment")

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Text Color")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: NSColor(engineHex: block.colorHex) ?? .black) },
                            set: { store.activeBlock?.colorHex = $0.engineHex }
                        ))
                        .labelsHidden()
                        .help("Custom text color")
                    }
                    HStack(spacing: 8) {
                        ForEach(Self.swatches, id: \.hex) { swatch in
                            Button {
                                store.activeBlock?.colorHex = swatch.hex
                            } label: {
                                Circle()
                                    .fill(Color(nsColor: NSColor(engineHex: swatch.hex) ?? .black))
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle().stroke(
                                            block.colorHex.lowercased() == swatch.hex ? Color.accentColor : Color.black.opacity(0.2),
                                            lineWidth: block.colorHex.lowercased() == swatch.hex ? 2.5 : 1
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(swatch.name)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Background")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        // "None" clears any pending background shading.
                        Button {
                            store.activeBlock?.backgroundHex = nil
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.clear)
                                .frame(width: 22, height: 18)
                                .overlay(
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 4).stroke(
                                            block.backgroundHex == nil ? Color.accentColor : Color.black.opacity(0.2),
                                            lineWidth: block.backgroundHex == nil ? 2 : 1
                                        )
                                        Image(systemName: "line.diagonal")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                )
                        }
                        .buttonStyle(.plain)
                        .help("No background")
                        ForEach(Self.backgroundSwatches, id: \.hex) { swatch in
                            Button {
                                store.activeBlock?.backgroundHex = swatch.hex
                            } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: NSColor(engineHex: swatch.hex) ?? .white))
                                    .frame(width: 22, height: 18)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                                        block.backgroundHex?.lowercased() == swatch.hex ? Color.accentColor : Color.black.opacity(0.2),
                                        lineWidth: block.backgroundHex?.lowercased() == swatch.hex ? 2 : 1
                                    ))
                            }
                            .buttonStyle(.plain)
                            .help("Shade behind this block: \(swatch.name)")
                        }
                    }
                }

                Text("Click away to apply · Esc cancels")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(width: 210)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
    }

    @ViewBuilder
    private var newTextPanel: some View {
        if let draft = store.newTextDraft {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Text")
                    .font(.headline)

                Picker("Font", selection: Binding(
                    get: { store.newTextDraft?.fontName ?? "Helvetica" },
                    set: { store.newTextDraft?.fontName = $0 }
                )) {
                    ForEach(AppStore.newTextFontChoices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    Divider()
                    ForEach(AppStore.allFontFamilies, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Size")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { store.newTextDraft?.fontSize ?? 12 },
                            set: { store.newTextDraft?.fontSize = max(6, min(96, $0)) }
                        ),
                        step: 1
                    ) {
                        Text("\(Int(draft.fontSize)) pt")
                            .monospacedDigit()
                    }
                }

                HStack(spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { store.newTextDraft?.bold ?? false },
                        set: { store.newTextDraft?.bold = $0 }
                    )) { Image(systemName: "bold") }
                        .help("Bold")
                    Toggle(isOn: Binding(
                        get: { store.newTextDraft?.italic ?? false },
                        set: { store.newTextDraft?.italic = $0 }
                    )) { Image(systemName: "italic") }
                        .help("Italic")
                    Toggle(isOn: Binding(
                        get: { store.newTextDraft?.underline ?? false },
                        set: { store.newTextDraft?.underline = $0 }
                    )) { Image(systemName: "underline") }
                        .help("Underline")
                }
                .toggleStyle(.button)

                Picker("", selection: Binding(
                    get: { store.newTextDraft?.alignment ?? "left" },
                    set: { store.newTextDraft?.alignment = $0 }
                )) {
                    Image(systemName: "text.alignleft").tag("left")
                    Image(systemName: "text.aligncenter").tag("center")
                    Image(systemName: "text.alignright").tag("right")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Alignment")

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Text Color")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: NSColor(engineHex: draft.colorHex) ?? .black) },
                            set: { store.newTextDraft?.colorHex = $0.engineHex }
                        ))
                        .labelsHidden()
                        .help("Custom text color")
                    }
                    HStack(spacing: 8) {
                        ForEach(Self.swatches, id: \.hex) { swatch in
                            Button {
                                store.newTextDraft?.colorHex = swatch.hex
                            } label: {
                                Circle()
                                    .fill(Color(nsColor: NSColor(engineHex: swatch.hex) ?? .black))
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle().stroke(
                                            draft.colorHex.lowercased() == swatch.hex ? Color.accentColor : Color.black.opacity(0.2),
                                            lineWidth: draft.colorHex.lowercased() == swatch.hex ? 2.5 : 1
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(swatch.name)
                        }
                    }
                }

                Text("Click away to apply · Esc cancels")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(width: 210)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
    }

    private func displayFontName(_ raw: String) -> String {
        if raw.isEmpty || raw.lowercased().hasPrefix("font0") {
            return "Document font"
        }
        return raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "MT", with: "")
    }
}

// MARK: - Sheets

private struct NoteSheetView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Note")
                .font(.headline)
            TextEditor(text: $store.pendingNoteText)
                .font(.body)
                .frame(width: 320, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") {
                    store.pendingNote = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Add Note") {
                    store.commitPendingNote()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.pendingNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct LinkSheetView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Link")
                .font(.headline)
            TextField("https://example.com", text: $store.pendingLinkURLText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") {
                    store.pendingLink = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Add Link") {
                    store.commitPendingLink()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct RedlineReplaceSheetView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace With")
                .font(.headline)
            Text("Marks the selected text struck-through with your suggested replacement attached.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
            TextField("Suggested replacement", text: $store.pendingRedlineReplaceText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") {
                    store.pendingRedlineReplace = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Mark Replacement") {
                    store.commitRedlineReplace()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.pendingRedlineReplaceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct PasswordSheetView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Password")
                .font(.headline)
            Text("The password protects the file when you save it. Leave empty to remove a pending password.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
            SecureField("Password", text: $store.passwordText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button("Cancel") {
                    store.passwordText = ""
                    store.showPasswordSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Set Password") {
                    store.setPassword()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

// MARK: - Overlays

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.quaternary))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

private struct DropOverlayView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
            RoundedRectangle(cornerRadius: 8)
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(18)
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 42, weight: .semibold))
                Text("Drop PDF to open")
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(.tint)
        }
        .allowsHitTesting(false)
    }
}
