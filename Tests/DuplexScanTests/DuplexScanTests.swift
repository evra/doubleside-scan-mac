import PDFKit
import XCTest
@testable import DuplexScan

final class FileNamerTests: XCTestCase {
    private let date: Date = {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 3, 7)
        (components.hour, components.minute, components.second) = (9, 5, 2)
        return Calendar.current.date(from: components)!
    }()

    func testDefaultPatternMatchesShellNaming() {
        XCTAssertEqual(FileNamer.render(ScanSettings.defaultNamePattern, .init(date: date)), "scan-20260307-090502")
    }

    func testTokens() {
        let context = FileNamer.Context(date: date, aiName: "fidelity-statement", tag: "dental", tags: ["bills", "dental"], pageCount: 3, counter: 7)
        XCTAssertEqual(FileNamer.render("{date}_{ai}_{tag}_{tags}_{pages}p_{counter:3}", context),
                       "2026-03-07_fidelity-statement_dental_bills-dental_3p_007")
        XCTAssertEqual(FileNamer.render("{tags:+} {time}", context), "bills+dental 090502")
        XCTAssertEqual(FileNamer.render("{unknown}-x", context), "{unknown}-x")
    }

    func testAIFallback() {
        XCTAssertEqual(FileNamer.render("{ai}", .init(date: date)), "scan")
        XCTAssertEqual(FileNamer.render("{ai:document}", .init(date: date, aiName: "  ")), "document")
        XCTAssertTrue(FileNamer.usesAI("x-{AI:y}"))
        XCTAssertFalse(FileNamer.usesAI("{date}"))
    }

    func testSanitize() {
        XCTAssertEqual(FileNamer.sanitize(" ../a/b:c.pdf "), "-a-b-c")
        XCTAssertEqual(FileNamer.sanitize("line\nbreak"), "linebreak")
        XCTAssertEqual(FileNamer.sanitize("..."), "scan")
        XCTAssertLessThanOrEqual(FileNamer.sanitize(String(repeating: "ä", count: 300)).utf8.count, 200)
    }
}

final class DuplexMergerTests: XCTestCase {
    /// Builds a PDF whose page widths encode their labels so order can be asserted.
    private func document(_ widths: [Int]) -> PDFDocument {
        let doc = PDFDocument()
        for width in widths {
            let page = PDFPage()
            page.setBounds(NSRect(x: 0, y: 0, width: width, height: 10), for: .mediaBox)
            doc.insert(page, at: doc.pageCount)
        }
        return doc
    }

    private func widths(_ doc: PDFDocument) -> [Int] {
        (0..<doc.pageCount).map { Int(doc.page(at: $0)!.bounds(for: .mediaBox).width) }
    }

    func testReversedBacks() {
        // Fronts 1,3,5; flipped stack yields backs 6,4,2.
        let merged = DuplexMerger.merge(fronts: document([10, 30, 50]), backs: document([60, 40, 20]), order: .reversed)
        XCTAssertEqual(widths(merged), [10, 20, 30, 40, 50, 60])
    }

    func testInOrderBacks() {
        let merged = DuplexMerger.merge(fronts: document([10, 30]), backs: document([20, 40]), order: .inOrder)
        XCTAssertEqual(widths(merged), [10, 20, 30, 40])
    }

    func testUnevenCountsKeepAllPages() {
        let merged = DuplexMerger.merge(fronts: document([10, 30, 50]), backs: document([20]), order: .inOrder)
        XCTAssertEqual(widths(merged), [10, 20, 30, 50])
    }
}

@MainActor
final class PDFMetadataTests: XCTestCase {
    func testAppliesMetadata() {
        let document = PDFDocument()
        PDFMetadata.apply(to: document, title: "AI title", summary: "Document summary", tag: "invoice")
        let attributes = document.documentAttributes!
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "AI title")
        XCTAssertEqual(attributes[PDFDocumentAttribute.subjectAttribute] as? String, "Document summary")
        XCTAssertEqual(attributes[PDFDocumentAttribute.keywordsAttribute] as? [String], ["invoice"])
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "scanline-ui")
    }

    func testFilenameFallbackAndOmittedEmptyFields() {
        let document = PDFDocument()
        PDFMetadata.apply(to: document, title: "scan-20261011", summary: "  ", tag: nil)
        let attributes = document.documentAttributes!
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "scan-20261011")
        XCTAssertNil(attributes[PDFDocumentAttribute.subjectAttribute])
        XCTAssertNil(attributes[PDFDocumentAttribute.keywordsAttribute])
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "scanline-ui")
    }
}

final class ScanSettingsTests: XCTestCase {
    func testSummaryTextFilePreferenceDefaultsOffAndPersists() {
        let suite = "DuplexScanTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ScanSettings.load(from: defaults).saveSummaryTextFile)
        defaults.set(true, forKey: SettingsKey.saveSummaryTextFile)
        XCTAssertTrue(ScanSettings.load(from: defaults).saveSummaryTextFile)
    }

    func testJPEGCompressionPreferencePersists() {
        let suite = "DuplexScanTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SettingsKey.jpegCompressPDF)
        XCTAssertTrue(ScanSettings.load(from: defaults).jpegCompressPDF)
    }

    func testAITagPromptDefaultAndPersistence() {
        XCTAssertFalse(ScanSettings.defaultAITagPrompt.isEmpty)
        let suite = "DuplexScanTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Choose the organization name.", forKey: SettingsKey.aiTagPrompt)
        XCTAssertEqual(ScanSettings.load(from: defaults).aiTagPrompt, "Choose the organization name.")
    }

    func testScanlineArguments() {
        var settings = ScanSettings()
        settings.scannerName = "epson"
        settings.exactName = true
        settings.mono = true
        settings.rotation = 180
        settings.tags = "bills, -dental ../x"
        let args = settings.scanlineArguments(duplex: true, autoname: true, summarize: false, name: nil)
        XCTAssertEqual(args, ["-a4", "-resolution", "300", "-browsesecs", "10", "-rotate", "180", "-mono", "-duplex",
                              "-scanner", "epson", "-exactname", "-autoname", "bills", "dental"])
    }

    func testFlatbedDisablesDuplex() {
        var settings = ScanSettings()
        settings.source = .flatbed
        settings.duplexMode = .hardware
        XCTAssertEqual(settings.effectiveDuplexMode, .single)
        let args = settings.scanlineArguments(duplex: true, autoname: false, summarize: false, name: "pass1")
        XCTAssertTrue(args.contains("-flatbed"))
        XCTAssertFalse(args.contains("-duplex"))
        XCTAssertEqual(Array(args.suffix(2)), ["-name", "pass1"])
    }
}
