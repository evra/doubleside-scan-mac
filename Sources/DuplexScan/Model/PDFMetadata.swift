import PDFKit

@MainActor
enum PDFMetadata {
    static func apply(to document: PDFDocument, title: String, summary: String?, tag: String?) {
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title
        attributes[PDFDocumentAttribute.creatorAttribute] = "scanline-ui"

        if let summary = nonEmpty(summary) {
            attributes[PDFDocumentAttribute.subjectAttribute] = summary
        } else {
            attributes.removeValue(forKey: PDFDocumentAttribute.subjectAttribute)
        }

        if let tag = nonEmpty(tag) {
            attributes[PDFDocumentAttribute.keywordsAttribute] = [tag]
        } else {
            attributes.removeValue(forKey: PDFDocumentAttribute.keywordsAttribute)
        }
        document.documentAttributes = attributes
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
