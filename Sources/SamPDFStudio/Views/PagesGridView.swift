import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Page management: a grid of page thumbnails that supports
/// click-to-select, drag-to-reorder, and double-click to jump into reading.
struct PagesGridView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draggedIndex: Int?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(0..<store.pageCount, id: \.self) { index in
                    PageThumbnailCell(
                        index: index,
                        document: store.document,
                        isSelected: store.selectedPageIndices.contains(index)
                    )
                    .onTapGesture(count: 2) {
                        openPage(index)
                    }
                    .onTapGesture {
                        toggleSelection(index)
                    }
                    .onDrag {
                        draggedIndex = index
                        return NSItemProvider(object: String(index) as NSString)
                    }
                    .onDrop(
                        of: [UTType.text.identifier],
                        delegate: PageDropDelegate(
                            targetIndex: index,
                            draggedIndex: $draggedIndex,
                            store: store
                        )
                    )
                }
            }
            .padding(24)
            .id(store.documentRevision)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func toggleSelection(_ index: Int) {
        if store.selectedPageIndices.contains(index) {
            store.selectedPageIndices.remove(index)
        } else {
            store.selectedPageIndices.insert(index)
        }
    }

    private func openPage(_ index: Int) {
        store.selectedOperation = .read
        DispatchQueue.main.async {
            if let pdfView = store.pdfViewProxy.pdfView,
               let page = pdfView.document?.page(at: index) {
                pdfView.go(to: page)
            }
        }
    }
}

private struct PageThumbnailCell: View {
    let index: Int
    let document: PDFDocument?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : Color.black.opacity(0.12), lineWidth: isSelected ? 3 : 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)

            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .padding(4)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        Group {
            if let image = renderThumbnail() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(.white)
                    .aspectRatio(0.77, contentMode: .fit)
            }
        }
    }

    private func renderThumbnail() -> NSImage? {
        guard let page = document?.page(at: index) else { return nil }
        return page.thumbnail(of: NSSize(width: 300, height: 400), for: .cropBox)
    }
}

private struct PageDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggedIndex: Int?
    let store: AppStore

    func dropEntered(info: DropInfo) {}

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let source = draggedIndex else { return false }
        draggedIndex = nil
        guard source != targetIndex else { return false }
        store.movePage(from: source, to: targetIndex > source ? targetIndex + 1 : targetIndex)
        return true
    }
}
