import PDFKit

enum DuplexMerger {
    /// Interleaves front and back passes. With `.reversed` the stack was flipped, so back page 1 belongs to the last front.
    static func merge(fronts: PDFDocument, backs: PDFDocument, order: BackOrder) -> PDFDocument {
        let output = PDFDocument()
        let frontCount = fronts.pageCount
        let backCount = backs.pageCount
        for i in 0..<max(frontCount, backCount) {
            if i < frontCount, let page = fronts.page(at: i)?.copy() as? PDFPage {
                output.insert(page, at: output.pageCount)
            }
            let j = order == .reversed ? backCount - 1 - i : i
            if j >= 0, j < backCount, let page = backs.page(at: j)?.copy() as? PDFPage {
                output.insert(page, at: output.pageCount)
            }
        }
        return output
    }

    static func append(_ source: PDFDocument, to destination: PDFDocument) {
        for i in 0..<source.pageCount {
            if let page = source.page(at: i)?.copy() as? PDFPage {
                destination.insert(page, at: destination.pageCount)
            }
        }
    }
}
