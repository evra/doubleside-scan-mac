import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: ScanSession

    var body: some View {
        Group {
            switch session.phase {
            case .idle:
                StartView()
            case .scanning(let message):
                ProgressPanel(message: message, cancelTitle: "Cancel Scan")
            case .awaitingBacks(let frontPages):
                BacksPromptView(frontPages: frontPages)
            case .review:
                ReviewView()
            case .saving(let message):
                ProgressPanel(message: message, cancelTitle: "Cancel")
            case .finished(let message):
                FinishedView(message: message)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .alert("Duplex Scan", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK") { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }
}

private struct StartView: View {
    @EnvironmentObject private var session: ScanSession
    @EnvironmentObject private var drive: GoogleDrive
    @AppStorage(SettingsKey.source) private var source = ScanSource.feeder
    @AppStorage(SettingsKey.duplexMode) private var duplexMode = DuplexMode.manual
    @AppStorage(SettingsKey.backOrder) private var backOrder = BackOrder.reversed
    @AppStorage(SettingsKey.mono) private var mono = false
    @AppStorage(SettingsKey.resolution) private var resolution = 300
    @AppStorage(SettingsKey.saveLocally) private var saveLocally = true
    @AppStorage(SettingsKey.localFolder) private var localFolder = ScanSettings.defaultLocalFolder
    @AppStorage(SettingsKey.uploadToDrive) private var uploadToDrive = false
    @AppStorage(SettingsKey.namePattern) private var namePattern = ScanSettings.defaultNamePattern

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text(instructions)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            Form {
                Picker("Source", selection: $source) {
                    ForEach(ScanSource.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sides", selection: $duplexMode) {
                    ForEach(DuplexMode.allCases) { Text($0.label).tag($0) }
                }
                .disabled(source == .flatbed)
                if source == .feeder && duplexMode == .manual {
                    Picker("Back side order", selection: $backOrder) {
                        ForEach(BackOrder.allCases) { Text($0.label).tag($0) }
                    }
                }
                Picker("Resolution", selection: $resolution) {
                    ForEach(ScanSettings.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                }
                Toggle("Monochrome", isOn: $mono)
                Toggle("Save to \(abbreviated(localFolder))", isOn: $saveLocally)
                Toggle("Upload to Google Drive\(drive.folderName.map { " folder \"\($0)\"" } ?? "")", isOn: $uploadToDrive)
                LabeledContent("Name pattern", value: namePattern)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                SettingsLink { Text("Settings…") }
                Button {
                    session.start()
                } label: {
                    Label("Scan", systemImage: "scanner").frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var instructions: String {
        if source == .flatbed { return "Place the page on the scanner glass." }
        switch duplexMode {
        case .manual: return "Put the stack face-up in the document feeder. Front sides are scanned first; then you flip the stack for the back sides."
        case .hardware: return "Put the stack in the document feeder. The scanner scans both sides in one pass."
        case .single: return "Put the stack face-up in the document feeder."
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

private struct BacksPromptView: View {
    @EnvironmentObject private var session: ScanSession
    let frontPages: Int

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Scanned \(frontPages) front page(s).")
                .font(.title2)
              Text("Take the stack out, flip it over as a whole without reordering the sheets, and put it back in the feeder.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack {
                Button("Discard", role: .destructive) { session.discard() }
                Button("Skip Backs") { session.skipBacks() }
                Button("Scan Backs") { session.scanBacks() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProgressPanel: View {
    @EnvironmentObject private var session: ScanSession
    @EnvironmentObject private var drive: GoogleDrive
    let message: String
    let cancelTitle: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(message).font(.title3)
            if let detail = session.progressDetail {
                Text(detail).foregroundStyle(.secondary)
            }
            if let activity = drive.activity {
                Text(activity).foregroundStyle(.secondary)
            }
            Button(cancelTitle) { session.cancel() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FinishedView: View {
    @EnvironmentObject private var session: ScanSession
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.green)
            Text(message)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("PDF size", value: formattedSize)
                LabeledContent("AI tag", value: session.resultAITag ?? "Not generated")
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI summary").font(.headline)
                    Text(session.resultSummary ?? "Not generated")
                        .foregroundStyle(session.resultSummary == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if let url = session.lastResultURL {
                    Button(url.isFileURL ? "Show in Finder" : "Open in Drive") {
                        if url.isFileURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Close") { session.closeReport() }
                Button("Scan Another") { session.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var formattedSize: String {
        guard let size = session.resultPDFSize else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
