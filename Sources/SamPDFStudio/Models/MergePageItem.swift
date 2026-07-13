import Foundation

struct MergePageItem: Identifiable, Equatable {
    let id = UUID()
    let sourceURL: URL
    let sourceName: String
    let pageNumber: Int

    var title: String {
        "\(sourceName) - page \(pageNumber)"
    }
}
