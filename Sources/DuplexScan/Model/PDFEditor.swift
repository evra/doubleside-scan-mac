import PDFKit

/// Owns the preview (PDFView + thumbnails) and page removal with undo.
@MainActor
final class PDFEditor: ObservableObject {
    let pdfView = PDFView()
    let thumbnailView = PDFThumbnailView()
    @Published private(set) var pageCount = 0
    @Published private(set) var canUndo = false
    @Published private(set) var pdfDataSize: Int64 = 0

    private var undoStack: [[(index: Int, page: PDFPage)]] = []

    init() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        thumbnailView.pdfView = pdfView
        thumbnailView.allowsMultipleSelection = true
        thumbnailView.thumbnailSize = CGSize(width: 120, height: 160)
        thumbnailView.backgroundColor = .windowBackgroundColor
    }

    var document: PDFDocument? { pdfView.document }

    func load(_ document: PDFDocument?) {
        undoStack = []
        pdfView.document = document
        refresh()
    }

    func append(_ pages: PDFDocument) {
        guard let document else { return load(pages) }
        let firstNew = document.pageCount
        DuplexMerger.append(pages, to: document)
        reload(showing: firstNew)
    }

    /// Removes the pages selected in the sidebar, or the current page if none are selected.
    @discardableResult
    func removeSelectedPages() -> Bool {
        guard let document else { return false }
        var pages = thumbnailView.selectedPages ?? []
        if pages.isEmpty, let current = pdfView.currentPage { pages = [current] }
        let indices = Set(pages.map { document.index(for: $0) }).filter { $0 != NSNotFound }.sorted(by: >)
        guard !indices.isEmpty, indices.count < document.pageCount else { return false }

        var removed: [(index: Int, page: PDFPage)] = []
        for index in indices {
            if let page = document.page(at: index) {
                removed.append((index, page))
                document.removePage(at: index)
            }
        }
        undoStack.append(removed)
        reload(showing: min(indices.last ?? 0, document.pageCount - 1))
        return true
    }

    func undo() {
        guard let document, let removed = undoStack.popLast() else { return }
        // Removed in descending order, so re-insert ascending to restore the original positions.
        for entry in removed.reversed() {
            document.insert(entry.page, at: entry.index)
        }
        reload(showing: removed.last?.index ?? 0)
    }

    private func reload(showing index: Int) {
        let document = pdfView.document
        pdfView.document = nil
        pdfView.document = document
        if let page = document?.page(at: max(0, index)) { pdfView.go(to: page) }
        refresh()
    }

    private func refresh() {
        pageCount = pdfView.document?.pageCount ?? 0
        canUndo = !undoStack.isEmpty
        pdfDataSize = Int64(pdfView.document?.dataRepresentation()?.count ?? 0)
    }
}
