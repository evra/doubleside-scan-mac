import AppKit
import PDFKit

/// Drives one scan job: scanline passes → manual duplex merge → review/edit → name → save locally and/or upload.
@MainActor
final class ScanSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(String)
        case awaitingBacks(frontPages: Int)
        case review
        case saving(String)
        case finished(String)
    }

    @Published private(set) var phase = Phase.idle
    @Published var errorMessage: String?
    @Published private(set) var warning: String?
    @Published var fileName = ""
    @Published private(set) var nameEdited = false
    @Published private(set) var lastResultURL: URL?
    @Published private(set) var progressDetail: String?
    @Published private(set) var aiStatus: String?
    @Published private(set) var resultPDFSize: Int64?
    @Published private(set) var resultSummary: String?
    @Published private(set) var resultAITag: String?
    @Published private(set) var selectedTag: String?

    let editor = PDFEditor()
    private let drive: GoogleDrive
    private let runner = ScanlineRunner()
    private var settings = ScanSettings.load()
    private var workDirectory: URL?
    private var fronts: PDFDocument?
    private var aiName: String?
    private var aiTag: String?
    private var tagManuallySelected = false
    private var summary: String?
    private var scanDate = Date()
    private var passNumber = 0
    private var savedLocalURL: URL?
    private var driveLink: URL?
    private var task: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var aiPending = 0
    private var generation = 0
    private var job = 0

    init(drive: GoogleDrive) {
        self.drive = drive
    }

    var isBusy: Bool {
        switch phase {
        case .scanning, .saving: true
        default: false
        }
    }

    var estimatedPDFSize: Int64 { editor.pdfDataSize }
    var tagChoices: [String] {
        var choices = settings.tagList
        if let aiTag, !choices.contains(aiTag) { choices.insert(aiTag, at: 0) }
        return choices
    }
    var displayedSummary: String? { summary ?? resultSummary }
    var displayedAITag: String? { aiTag ?? resultAITag }

    // MARK: - Scanning

    func start() {
        guard !isBusy else { return }
        cleanUp()
        job += 1
        settings = ScanSettings.load()
        scanDate = Date()
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DuplexScan-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            workDirectory = directory
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        run { [self] in
            switch settings.effectiveDuplexMode {
            case .manual:
                let doc = try await pass(message: "Scanning front sides…", duplex: false)
                fronts = doc
                phase = .awaitingBacks(frontPages: doc.pageCount)
            case .hardware:
                enterReview(try await pass(message: "Scanning both sides…", duplex: true))
            case .single:
                enterReview(try await pass(message: "Scanning…", duplex: false))
            }
        }
    }

    func scanBacks() {
        guard let fronts else { return }
        run { [self] in
            let backs = try await pass(message: "Scanning back sides…", duplex: false)
            if backs.pageCount != fronts.pageCount {
                warning = "Front pass has \(fronts.pageCount) page(s) but back pass has \(backs.pageCount). Check the page order before saving."
            }
            enterReview(DuplexMerger.merge(fronts: fronts, backs: backs, order: settings.backOrder))
        }
    }

    func skipBacks() {
        guard let fronts else { return }
        enterReview(fronts)
    }

    /// Scans more pages and appends them (the GUI equivalent of scanline's -batch).
    func scanMorePages() {
        guard phase == .review else { return }
        run { [self] in
            editor.append(try await pass(message: "Scanning additional pages…", duplex: settings.effectiveDuplexMode == .hardware))
            updateNameFromPattern()
            phase = .review
            startAI()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func closeReport() {
        guard case .finished = phase else { return }
        phase = .idle
    }

    func discard() {
        task?.cancel()
        generation += 1
        job += 1
        cleanUp()
        phase = .idle
    }

    private func pass(message: String, duplex: Bool) async throws -> PDFDocument {
        guard let workDirectory else { throw AppError("No scan in progress.") }
        phase = .scanning(message)
        // libscanline's output processor always writes $TMPDIR/scan.pdf, so it must not run concurrently.
        if aiPending > 0 {
            progressDetail = "Waiting for Apple Intelligence to finish the previous document…"
            await aiTask?.value
        }
        progressDetail = nil
        passNumber += 1
        let label = "pass\(passNumber)"
        var pages = 0
        StdoutTap.shared.observe(echo: settings.verbose) { [weak self] line in
            if line.hasPrefix("didScanTo") {
                pages += 1
                self?.progressDetail = "Received page \(pages)"
            } else if line.hasPrefix("Starting scan") {
                self?.progressDetail = "Scanner started…"
            } else if line.localizedCaseInsensitiveContains("error") {
                self?.progressDetail = line
            }
        }
        defer {
            StdoutTap.shared.observe(echo: settings.verbose, nil)
            progressDetail = nil
        }
        // -verbose is always on so per-page progress (didScanTo) can be shown; echoing follows the setting.
        var arguments = settings.scanlineArguments(duplex: duplex, autoname: false, summarize: false, name: label)
        if !arguments.contains("-verbose") { arguments.append("-verbose") }
        let output = try await runner.scan(arguments: arguments, outputDirectory: workDirectory.appendingPathComponent(label))
        guard let document = PDFDocument(url: output.pdf), document.pageCount > 0 else {
            throw AppError("The scanned PDF could not be opened or has no pages.")
        }
        return document
    }

    private func enterReview(_ document: PDFDocument) {
        editor.load(document)
        selectedTag = nil
        tagManuallySelected = false
        nameEdited = false
        updateNameFromPattern()
        phase = .review
        startAI()
    }

    /// Generates the {ai} name and summary in the background while the user reviews the pages.
    private func startAI() {
        let autoname = FileNamer.usesAI(settings.namePattern)
        let tagPrompt = settings.aiTagPrompt
        guard autoname || settings.summarize || !tagPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = editor.document?.dataRepresentation() else { return }
        let summarize = settings.summarize
        let tags = settings.tagList
        let current = job
        let previous = aiTask
        aiStatus = "Apple Intelligence is reading the document…"
        aiPending += 1
        aiTask = Task { [self] in
            await previous?.value
            let result = await Task.detached {
                await DocumentAI.analyze(pdfData: data, autoname: autoname, summarize: summarize,
                                         tags: tags, tagPrompt: tagPrompt)
            }.value
            aiPending -= 1
            guard current == job else { return }
            if autoname { aiName = result.name }
            if summarize { summary = result.summary }
            aiTag = result.aiTag
            if !tagManuallySelected {
                selectedTag = result.aiTag
            }
            aiStatus = nil
            updateNameFromPattern()
        }
    }

    // MARK: - Naming and editing

    func setFileName(_ name: String) {
        fileName = name
        nameEdited = true
    }

    func selectTag(_ tag: String?) {
        selectedTag = tag
        tagManuallySelected = true
        updateNameFromPattern()
    }

    func resetFileName() {
        nameEdited = false
        updateNameFromPattern()
    }

    func removeSelectedPages() {
        if !editor.removeSelectedPages() {
            errorMessage = "Select the pages to remove. At least one page must remain; use Discard to drop the whole scan."
        }
        updateNameFromPattern()
    }

    func undoRemoval() {
        editor.undo()
        updateNameFromPattern()
    }

    private func updateNameFromPattern() {
        guard !nameEdited else { return }
        fileName = FileNamer.render(settings.namePattern, .init(
            date: scanDate, aiName: aiName, tag: selectedTag, tags: settings.tagList,
            pageCount: editor.pageCount, counter: ScanSettings.load().nextCounter))
    }

    // MARK: - Saving

    func save() {
        guard phase == .review, let document = editor.document, let workDirectory else { return }
        settings = ScanSettings.load()
        guard settings.saveLocally || settings.uploadToDrive else {
            errorMessage = "Enable saving to a local folder or uploading to Google Drive in Settings."
            return
        }
        run { [self] in
            if aiTask != nil, aiStatus != nil {
                phase = .saving("Waiting for Apple Intelligence…")
                await aiTask?.value
            }
            let name = FileNamer.sanitize(fileName)
            phase = .saving("Writing PDF…")
            let file = workDirectory.appendingPathComponent("\(name).pdf")
            PDFMetadata.apply(to: document, title: aiName ?? name, summary: summary, tag: selectedTag)
            let wrotePDF: Bool
            if settings.jpegCompressPDF {
                wrotePDF = document.write(to: file, withOptions: [.saveImagesAsJPEGOption: true])
            } else {
                wrotePDF = document.write(to: file)
            }
            guard wrotePDF else { throw AppError("Could not write the PDF.") }
            let pdfSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value

            var results: [String] = []
            if settings.saveLocally {
                if savedLocalURL == nil { savedLocalURL = try saveLocalCopy(of: file, name: name) }
                results.append("Saved to \(savedLocalURL!.path)")
            }
            if settings.uploadToDrive {
                if driveLink == nil {
                    phase = .saving("Uploading to Google Drive…")
                    driveLink = try await drive.upload(file: file, name: "\(name).pdf", description: summary)
                        ?? URL(string: "https://drive.google.com/")
                }
                results.append("Uploaded \(name).pdf to Google Drive\(drive.folderName.map { " (\($0))" } ?? "")")
            }

            lastResultURL = savedLocalURL ?? driveLink
            resultPDFSize = pdfSize
            resultSummary = summary
            resultAITag = aiTag
            if settings.openAfterSave, let url = lastResultURL { NSWorkspace.shared.open(url) }
            UserDefaults.standard.set(settings.nextCounter + 1, forKey: SettingsKey.nextCounter)
            cleanUp(keepResult: true)
            phase = .finished(results.joined(separator: "\n"))
        }
    }

    private func saveLocalCopy(of file: URL, name: String) throws -> URL {
        let folder = URL(fileURLWithPath: (settings.localFolder as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent("\(name).pdf")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(name)-\(suffix).pdf")
            suffix += 1
        }
        try FileManager.default.copyItem(at: file, to: destination)
        if settings.saveSummaryTextFile, let summary, !summary.isEmpty {
            let summaryURL = destination.deletingPathExtension().appendingPathExtension("summary.txt")
            try? summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        }
        return destination
    }

    // MARK: - Plumbing

    private func run(_ body: @escaping () async throws -> Void) {
        generation += 1
        let current = generation
        task = Task { [self] in
            do {
                try await body()
            } catch {
                // A discarded job must not reset a newer one.
                guard current == generation else { return }
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
                recoverPhase()
            }
        }
    }

    /// Returns to the last stable step so a failed or cancelled action can be retried.
    private func recoverPhase() {
        if editor.document != nil {
            phase = .review
        } else if let fronts {
            phase = .awaitingBacks(frontPages: fronts.pageCount)
        } else {
            cleanUp()
            phase = .idle
        }
    }

    private func cleanUp(keepResult: Bool = false) {
        runner.endSession()
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
        fronts = nil
        aiName = nil
        aiTag = nil
        selectedTag = nil
        tagManuallySelected = false
        aiStatus = nil
        summary = nil
        warning = nil
        passNumber = 0
        savedLocalURL = nil
        driveLink = nil
        editor.load(nil)
        if !keepResult {
            lastResultURL = nil
            resultPDFSize = nil
            resultSummary = nil
            resultAITag = nil
        }
    }
}
