import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ScanSource: String, CaseIterable, Identifiable {
    case feeder, flatbed
    var id: String { rawValue }
    var label: String { self == .feeder ? "Document feeder" : "Flatbed" }
}

enum DuplexMode: String, CaseIterable, Identifiable {
    case manual, hardware, single
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: "Manual duplex (flip stack)"
        case .hardware: "Scanner duplex"
        case .single: "Single-sided"
        }
    }
}

enum BackOrder: String, CaseIterable, Identifiable {
    case reversed, inOrder
    var id: String { rawValue }
    var label: String { self == .reversed ? "Reversed (whole stack flipped)" : "Same order as fronts" }
}

enum PaperSize: String, CaseIterable, Identifiable {
    case a4, letter, legal
    var id: String { rawValue }
    var label: String { self == .a4 ? "A4" : rawValue.capitalized }
}

enum SettingsKey {
    static let scannerName = "scannerName"
    static let exactName = "exactName"
    static let browseSeconds = "browseSeconds"
    static let source = "source"
    static let duplexMode = "duplexMode"
    static let backOrder = "backOrder"
    static let paperSize = "paperSize"
    static let resolution = "resolution"
    static let mono = "mono"
    static let jpegCompressPDF = "jpegCompressPDF"
    static let rotation = "rotation"
    static let verbose = "verbose"
    static let tags = "tags"
    static let summarize = "summarize"
    static let saveSummaryTextFile = "saveSummaryTextFile"
    static let aiTagPrompt = "aiTagPrompt"
    static let namePattern = "namePattern"
    static let nextCounter = "nextCounter"
    static let saveLocally = "saveLocally"
    static let localFolder = "localFolder"
    static let openAfterSave = "openAfterSave"
    static let uploadToDrive = "uploadToDrive"
    static let googleConfigPath = "googleConfigPath"
    static let driveFolderId = "driveFolderId"
    static let driveFolderName = "driveFolderName"
}

/// Snapshot of the user's settings; views edit the same keys through @AppStorage.
struct ScanSettings {
    static let defaultNamePattern = "scan-{date:yyyyMMdd-HHmmss}"
    static let defaultLocalFolder = NSHomeDirectory() + "/Documents/Archive"
    static let defaultGoogleConfigPath = NSHomeDirectory() + "/.config/doubleside-scan/google-oauth.json"
    static let resolutions = [75, 100, 150, 200, 300, 400, 600, 1200]
    static let defaultAITagPrompt = "Identify the main document type or topic. Return one concise tag, using lowercase words separated by hyphens."

    var scannerName = ""
    var exactName = false
    var browseSeconds = 10
    var source = ScanSource.feeder
    var duplexMode = DuplexMode.manual
    var backOrder = BackOrder.reversed
    var paperSize = PaperSize.a4
    var resolution = 300
    var mono = false
    var jpegCompressPDF = false
    var rotation = 0
    var verbose = false
    var tags = ""
    var summarize = false
    var saveSummaryTextFile = false
    var aiTagPrompt = defaultAITagPrompt
    var namePattern = defaultNamePattern
    var nextCounter = 1
    var saveLocally = true
    var localFolder = defaultLocalFolder
    var openAfterSave = false
    var uploadToDrive = false
    var googleConfigPath = defaultGoogleConfigPath

    static func registerDefaults() {
        let d = ScanSettings()
        UserDefaults.standard.register(defaults: [
            SettingsKey.scannerName: d.scannerName,
            SettingsKey.exactName: d.exactName,
            SettingsKey.browseSeconds: d.browseSeconds,
            SettingsKey.source: d.source.rawValue,
            SettingsKey.duplexMode: d.duplexMode.rawValue,
            SettingsKey.backOrder: d.backOrder.rawValue,
            SettingsKey.paperSize: d.paperSize.rawValue,
            SettingsKey.resolution: d.resolution,
            SettingsKey.mono: d.mono,
            SettingsKey.jpegCompressPDF: d.jpegCompressPDF,
            SettingsKey.rotation: d.rotation,
            SettingsKey.verbose: d.verbose,
            SettingsKey.tags: d.tags,
            SettingsKey.summarize: d.summarize,
            SettingsKey.saveSummaryTextFile: d.saveSummaryTextFile,
            SettingsKey.aiTagPrompt: d.aiTagPrompt,
            SettingsKey.namePattern: d.namePattern,
            SettingsKey.nextCounter: d.nextCounter,
            SettingsKey.saveLocally: d.saveLocally,
            SettingsKey.localFolder: d.localFolder,
            SettingsKey.openAfterSave: d.openAfterSave,
            SettingsKey.uploadToDrive: d.uploadToDrive,
            SettingsKey.googleConfigPath: d.googleConfigPath,
        ])
    }

    static func load(from defaults: UserDefaults = .standard) -> ScanSettings {
        var s = ScanSettings()
        s.scannerName = defaults.string(forKey: SettingsKey.scannerName) ?? s.scannerName
        s.exactName = defaults.bool(forKey: SettingsKey.exactName)
        s.browseSeconds = max(1, defaults.integer(forKey: SettingsKey.browseSeconds))
        s.source = ScanSource(rawValue: defaults.string(forKey: SettingsKey.source) ?? "") ?? s.source
        s.duplexMode = DuplexMode(rawValue: defaults.string(forKey: SettingsKey.duplexMode) ?? "") ?? s.duplexMode
        s.backOrder = BackOrder(rawValue: defaults.string(forKey: SettingsKey.backOrder) ?? "") ?? s.backOrder
        s.paperSize = PaperSize(rawValue: defaults.string(forKey: SettingsKey.paperSize) ?? "") ?? s.paperSize
        s.resolution = defaults.integer(forKey: SettingsKey.resolution)
        s.mono = defaults.bool(forKey: SettingsKey.mono)
        s.jpegCompressPDF = defaults.bool(forKey: SettingsKey.jpegCompressPDF)
        s.rotation = defaults.integer(forKey: SettingsKey.rotation)
        s.verbose = defaults.bool(forKey: SettingsKey.verbose)
        s.tags = defaults.string(forKey: SettingsKey.tags) ?? ""
        s.summarize = defaults.bool(forKey: SettingsKey.summarize)
        s.saveSummaryTextFile = defaults.bool(forKey: SettingsKey.saveSummaryTextFile)
        s.aiTagPrompt = defaults.string(forKey: SettingsKey.aiTagPrompt) ?? s.aiTagPrompt
        s.namePattern = defaults.string(forKey: SettingsKey.namePattern) ?? s.namePattern
        s.nextCounter = defaults.integer(forKey: SettingsKey.nextCounter)
        s.saveLocally = defaults.bool(forKey: SettingsKey.saveLocally)
        s.localFolder = defaults.string(forKey: SettingsKey.localFolder) ?? s.localFolder
        s.openAfterSave = defaults.bool(forKey: SettingsKey.openAfterSave)
        s.uploadToDrive = defaults.bool(forKey: SettingsKey.uploadToDrive)
        s.googleConfigPath = defaults.string(forKey: SettingsKey.googleConfigPath) ?? s.googleConfigPath
        return s
    }

    var tagList: [String] {
        tags.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }
    }

    var effectiveDuplexMode: DuplexMode { source == .flatbed ? .single : duplexMode }

    /// Builds a libscanline argument list (same options as the `scanline` CLI).
    func scanlineArguments(duplex: Bool, autoname: Bool, summarize: Bool, name: String?) -> [String] {
        var args = ["-\(paperSize.rawValue)",
                    "-resolution", String(resolution),
                    "-browsesecs", String(browseSeconds)]
        if rotation != 0 { args += ["-rotate", String(rotation)] }
        if mono { args.append("-mono") }
        if source == .flatbed { args.append("-flatbed") }
        if duplex && source == .feeder { args.append("-duplex") }
        if !scannerName.isEmpty {
            args += ["-scanner", scannerName]
            if exactName { args.append("-exactname") }
        }
        if verbose { args.append("-verbose") }
        if autoname { args.append("-autoname") }
        if summarize { args.append("-summarize") }
        if let name { args += ["-name", name] }
        return args + tagList
    }
}
