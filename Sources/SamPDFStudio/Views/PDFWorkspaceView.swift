import PDFKit
import SwiftUI

struct PDFWorkspaceView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if let document = store.document {
                if store.selectedOperation == .pages {
                    PagesGridView()
                } else {
                    PDFPreviewView(
                        document: document,
                        selectedText: $store.selectedPDFText,
                        selectedPage: $store.selectedPDFPage,
                        selectedRect: $store.selectedPDFRect,
                        isEditing: store.selectedOperation == .edit,
                        isAnnotating: store.selectedOperation == .annotate,
                        isFillSign: store.selectedOperation == .fillSign,
                        isRedline: store.selectedOperation == .redline,
                        blockMoveMode: store.blockMoveMode,
                        editTool: store.selectedEditTool,
                        annotateTool: store.selectedAnnotateTool,
                        fillSignTool: store.selectedFillSignTool,
                        redlineTool: store.selectedRedlineTool,
                        activeBlock: store.activeBlock,
                        activeBlockGuides: store.activeBlockGuides,
                        newTextDraft: store.newTextDraft,
                        pdfViewProxy: store.pdfViewProxy,
                        onEditBlock: { page, x, y in
                            store.editBlock(page: page, x: x, y: y)
                        },
                        onCommitBlock: { block, text in
                            store.commitBlockEdit(block: block, newText: text)
                        },
                        onCancelBlock: { block in
                            store.cancelBlockEdit(block: block)
                        },
                        onMoveBlock: { block, text, x, y in
                            store.moveActiveBlock(block: block, text: text, toEngineX: x, y: y)
                        },
                        onCommitNewText: { draft, text in
                            store.commitNewText(draft: draft, text: text)
                        },
                        onCancelNewText: { draft in
                            store.cancelNewText(draft: draft)
                        },
                        onCopyRegion: {
                            store.copySelectedRegion()
                        },
                        onPasteRegion: { page, x, y in
                            store.pasteCopiedRegion(page: page, x: x, y: y)
                        },
                        onMoveRegion: { page, x, y in
                            store.moveSelectedRegion(page: page, x: x, y: y)
                        },
                        onGrabGuideRects: { store.guideRects(forPage: $0) },
                        liveActiveBlock: { store.activeBlock },
                        liveNewTextDraft: { store.newTextDraft },
                        onMarkupSelection: { selection in
                            store.applyMarkup(selection, kind: markupKind)
                        },
                        onPlaceNote: { pageIndex, point in
                            store.placeNote(pageIndex: pageIndex, pdfKitPoint: point)
                        },
                        onAddTextBox: { pageIndex, point, text in
                            store.addTextBox(pageIndex: pageIndex, pdfKitPoint: point, text: text)
                        },
                        onPlaceSignature: { page, x, y in
                            store.placeSignature(page: page, x: x, y: y)
                        },
                        onPlaceImage: { page, x, y in
                            store.placeImage(page: page, x: x, y: y)
                        },
                        onPlaceTextDraft: { page, x, y in
                            store.placeTextDraft(page: page, x: x, y: y)
                        },
                        onLinkRegion: { pageIndex, rect in
                            store.linkRegionSelected(pageIndex: pageIndex, pdfKitRect: rect)
                        },
                        onFillSignClick: { page, x, y in
                            store.fillSignClick(page: page, x: x, y: y)
                        },
                        onRedlineSelection: { selection in
                            store.applyRedline(selection)
                        },
                        onRedlineCaret: { page, x, y in
                            store.redlineCaret(page: page, x: x, y: y)
                        },
                        onNoteSelection: { selection in
                            store.noteOnSelection(selection)
                        },
                        onAnnotationEdited: { title in
                            store.annotationEdited(title: title)
                        }
                    )
                }
            } else {
                WelcomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var markupKind: AnnotationKind {
        switch store.selectedAnnotateTool {
        case .underline: .underline
        case .strikeout: .strikeout
        default: .highlight
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop a PDF anywhere to open it")
                    .font(.title3.weight(.medium))
                Text("or")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        store.openPDF()
                    } label: {
                        Label("Open PDF…", systemImage: "folder")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("o")

                    Button {
                        store.mergePDFFiles()
                    } label: {
                        Label("Merge PDFs…", systemImage: "square.stack.3d.down.right")
                    }
                    .controlSize(.large)
                }
            }

            if !store.recentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                    ForEach(store.recentFiles.prefix(6), id: \.self) { url in
                        Button {
                            store.loadPDF(url, checkDirty: true)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                                Text(url.deletingLastPathComponent().lastPathComponent)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(width: 380)
            }

            Spacer()
            Spacer()

            // Build marker — lets us confirm at a glance whether the running
            // window is the latest build (stale windows keep old bugs).
            if let build = Bundle.main.object(forInfoDictionaryKey: "SamPDFBuildTime") as? String {
                Text("Build \(build)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
