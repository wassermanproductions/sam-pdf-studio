import PDFKit
import SwiftUI

/// Sidebar thumbnails. Hand-rolled (not PDFKit's PDFThumbnailView, whose
/// internal collection view performs AutoLayout off the main thread when the
/// document is swapped mid-generation — a hard crash).
struct PDFThumbnailRailView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(0..<store.pageCount, id: \.self) { index in
                    VStack(spacing: 4) {
                        RailThumbnail(document: store.document, index: index)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.black.opacity(0.15), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let pdfView = store.pdfViewProxy.pdfView,
                           let page = pdfView.document?.page(at: index) {
                            pdfView.go(to: page)
                        }
                    }
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .id(store.documentRevision)
        }
    }
}

private struct RailThumbnail: View {
    let document: PDFDocument?
    let index: Int

    var body: some View {
        if let page = document?.page(at: index) {
            Image(nsImage: page.thumbnail(of: NSSize(width: 132, height: 176), for: .cropBox))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 132)
        } else {
            Rectangle()
                .fill(.white)
                .frame(width: 132, height: 170)
        }
    }
}
