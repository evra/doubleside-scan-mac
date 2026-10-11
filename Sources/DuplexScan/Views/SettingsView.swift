import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ScannerSettings().tabItem { Label("Scanner", systemImage: "scanner") }
            NamingSettings().tabItem { Label("Naming", systemImage: "textformat") }
            OutputSettings().tabItem { Label("Output", systemImage: "icloud.and.arrow.up") }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

/// libscanline options: -scanner, -exactname, -browsesecs, -flatbed, -duplex, -a4/-letter/-legal, -resolution, -mono, -rotate, -verbose.
private struct ScannerSettings: View {
    @EnvironmentObject private var scanners: ScannerList
    @AppStorage(SettingsKey.scannerName) private var scannerName = ""
    @AppStorage(SettingsKey.exactName) private var exactName = false
    @AppStorage(SettingsKey.browseSeconds) private var browseSeconds = 10
    @AppStorage(SettingsKey.source) private var source = ScanSource.feeder
    @AppStorage(SettingsKey.duplexMode) private var duplexMode = DuplexMode.manual
    @AppStorage(SettingsKey.backOrder) private var backOrder = BackOrder.reversed
    @AppStorage(SettingsKey.paperSize) private var paperSize = PaperSize.a4
    @AppStorage(SettingsKey.resolution) private var resolution = 300
    @AppStorage(SettingsKey.mono) private var mono = false
    @AppStorage(SettingsKey.jpegCompressPDF) private var jpegCompressPDF = false
    @AppStorage(SettingsKey.rotation) private var rotation = 0
    @AppStorage(SettingsKey.verbose) private var verbose = false

    var body: some View {
        Form {
            Section("Device") {
                Picker("Scanner", selection: $scannerName) {
                    Text("First available").tag("")
                    ForEach(scannerChoices, id: \.self) { Text($0).tag($0) }
                }
                TextField("Scanner name", text: $scannerName, prompt: Text("Prefix match, e.g. epson"))
                Toggle("Exact name match", isOn: $exactName)
                Stepper("Search for scanners: \(browseSeconds) s", value: $browseSeconds, in: 1...60)
            }
            Section("Scan") {
                Picker("Source", selection: $source) {
                    ForEach(ScanSource.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sides", selection: $duplexMode) {
                    ForEach(DuplexMode.allCases) { Text($0.label).tag($0) }
                }
                .disabled(source == .flatbed)
                Picker("Back side order", selection: $backOrder) {
                    ForEach(BackOrder.allCases) { Text($0.label).tag($0) }
                }
                .disabled(source == .flatbed || duplexMode != .manual)
                Picker("Paper size", selection: $paperSize) {
                    ForEach(PaperSize.allCases) { Text($0.label).tag($0) }
                }
                Picker("Minimum resolution", selection: $resolution) {
                    ForEach(ScanSettings.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                }
                Toggle("Monochrome", isOn: $mono)
                Toggle("Compress PDF images as JPEG", isOn: $jpegCompressPDF)
                Text("Lossy compression can reduce file size; inspect fine text and image quality.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Rotate pages", selection: $rotation) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                Toggle("Echo libscanline log to stdout", isOn: $verbose)
            }
        }
        .formStyle(.grouped)
    }

    private var scannerChoices: [String] {
        var names = scanners.names
        if !scannerName.isEmpty && !names.contains(scannerName) { names.append(scannerName) }
        return names
    }
}

/// libscanline options: -autoname (via {ai}), -summarize, tags.
private struct NamingSettings: View {
    @AppStorage(SettingsKey.namePattern) private var namePattern = ScanSettings.defaultNamePattern
    @AppStorage(SettingsKey.tags) private var tags = ""
    @AppStorage(SettingsKey.summarize) private var summarize = false
    @AppStorage(SettingsKey.saveSummaryTextFile) private var saveSummaryTextFile = false
    @AppStorage(SettingsKey.aiTagPrompt) private var aiTagPrompt = ScanSettings.defaultAITagPrompt
    @AppStorage(SettingsKey.nextCounter) private var nextCounter = 1

    var body: some View {
        Form {
            Section("File name") {
                TextField("Available tags", text: $tags, prompt: Text("e.g. bills, dental, tax"))
                Text("Choose one in scan results; the AI tag is selected by default. {tag} uses the selection, while {tags} includes this full list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Pattern", text: $namePattern)
                LabeledContent("Preview", value: preview + ".pdf")
                Stepper("Next counter: \(nextCounter)", value: $nextCounter, in: 1...999_999)
                Grid(alignment: .leading, verticalSpacing: 4) {
                    ForEach(FileNamer.tokenHelp, id: \.token) { item in
                        GridRow {
                            Text(item.token).font(.system(.body, design: .monospaced))
                            Text(item.meaning).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
            }
            Section {
                Toggle("Summarize with Apple Intelligence", isOn: $summarize)
                Toggle("Save summary as .summary.txt next to local PDF", isOn: $saveSummaryTextFile)
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI tag instruction")
                    TextEditor(text: $aiTagPrompt)
                        .font(.body)
                        .frame(height: 78)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                    Text("Applied to OCR text. The model returns one short tag.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("The AI tag instruction generates a separate document label. Summaries are stored as the Drive file description and as a .summary.txt next to local copies. Generative AI – review the results.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var preview: String {
        var settings = ScanSettings()
        settings.tags = tags
        return FileNamer.render(namePattern, .init(aiName: "fidelity-statement", tag: settings.tagList.first,
                              tags: settings.tagList, pageCount: 4, counter: nextCounter))
    }
}

private struct OutputSettings: View {
    @EnvironmentObject private var drive: GoogleDrive
    @AppStorage(SettingsKey.saveLocally) private var saveLocally = true
    @AppStorage(SettingsKey.localFolder) private var localFolder = ScanSettings.defaultLocalFolder
    @AppStorage(SettingsKey.openAfterSave) private var openAfterSave = false
    @AppStorage(SettingsKey.uploadToDrive) private var uploadToDrive = false
    @AppStorage(SettingsKey.googleConfigPath) private var googleConfigPath = ScanSettings.defaultGoogleConfigPath
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Local folder") {
                Toggle("Save a copy locally", isOn: $saveLocally)
                LabeledContent("Folder") {
                    HStack {
                        Text((localFolder as NSString).abbreviatingWithTildeInPath).truncationMode(.middle).lineLimit(1)
                        Button("Choose…") { chooseLocalFolder() }
                    }
                }
                Toggle("Open the result after saving", isOn: $openAfterSave)
            }
            Section("Google Drive") {
                Toggle("Upload automatically when saving", isOn: $uploadToDrive)
                LabeledContent("OAuth config") {
                    HStack {
                        Text((googleConfigPath as NSString).abbreviatingWithTildeInPath).truncationMode(.middle).lineLimit(1)
                        Button("Choose…") { chooseConfigFile() }
                    }
                }
                LabeledContent("Account", value: drive.accountStatus)
                LabeledContent("Folder", value: drive.folderName ?? "Not selected")
                HStack {
                    if drive.isSignedIn {
                        Button("Sign Out") { drive.signOut() }
                    } else {
                        Button("Sign In…") { perform { try await drive.signIn() } }
                    }
                    Button("Choose Folder…") { perform { try await drive.chooseFolder() } }
                    if working { ProgressView().controlSize(.small) }
                }
                .disabled(working)
                if let activity = drive.activity { Text(activity).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await action() } catch is CancellationError {} catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (localFolder as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { localFolder = url.path }
    }

    private func chooseConfigFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = URL(fileURLWithPath: (googleConfigPath as NSString).expandingTildeInPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            googleConfigPath = url.path
            drive.configurationChanged()
        }
    }
}
