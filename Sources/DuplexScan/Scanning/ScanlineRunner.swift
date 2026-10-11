import Foundation
import ImageCaptureCore
import LibScanline

struct ScanlineOutput {
    let pdf: URL
    let summary: String?
}

/// Runs libscanline passes (browse → open session → scan → write PDF). Unlike the CLI, the process outlives each scan:
/// the device is reused across passes and jobs, and ImageCaptureCore's unretained (`assign`) delegates are never freed.
@MainActor
final class ScanlineRunner: NSObject {
    /// Browsers and device delegates that ImageCaptureCore may still call; releasing them would crash.
    private static var retired: [AnyObject] = []

    private var configuration: ScanConfiguration?
    private var logger: LibScanline.Logger?
    private var browser: ScannerBrowser?
    private var controller: ScannerController?
    private var deviceProxy: ScannerDelegateProxy?
    private var device: ICScannerDevice?
    private var deviceKey: String?
    private var browseTimer: Timer?
    private var outputDirectory: URL?
    private var continuation: CheckedContinuation<ScanlineOutput, Error>?

    func scan(arguments: [String], outputDirectory: URL) async throws -> ScanlineOutput {
        guard continuation == nil else { throw AppError("A scan is already running.") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.outputDirectory = outputDirectory
                // An empty config path keeps ~/.scanline.conf (e.g. -open, -dir) from interfering with the app's settings.
                let config = ScanConfiguration(arguments: arguments + ["-dir", outputDirectory.path], configFilePath: "")
                let logger = LibScanline.Logger(configuration: config)
                self.configuration = config
                self.logger = logger

                let key = Self.deviceKey(for: config)
                if let device, key == deviceKey {
                    startController(on: device, sessionIsOpen: device.hasOpenSession)
                    return
                }
                forgetDevice()
                deviceKey = key
                let browser = ScannerBrowser(configuration: config, logger: logger)
                browser.delegate = self
                self.browser = browser
                browser.browse()

                let seconds = Double(config.config[ScanlineConfigOptionBrowseSecs] as? String ?? "10") ?? 10
                browseTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.browser?.stopBrowsing() }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    /// Closes the scanner session; call when a scan job ends. The device is kept for the next job.
    func endSession() {
        controller?.delegate = nil
        controller = nil
        deviceProxy?.controller = nil
        if let device, device.hasOpenSession { device.requestCloseSession() }
    }

    private func forgetDevice() {
        endSession()
        if let deviceProxy { Self.retired.append(deviceProxy) }
        if let browser {
            browser.delegate = nil
            Self.retired.append(browser)
        }
        deviceProxy = nil
        device = nil
        deviceKey = nil
        browser = nil
    }

    private static func deviceKey(for config: ScanConfiguration) -> String {
        "\(config.config[ScanlineConfigOptionScanner] ?? "")|\(config.config[ScanlineConfigOptionExactName] != nil)"
    }

    private func browsingFinished(with scanner: ICScannerDevice?) {
        guard continuation != nil, let configuration else { return }
        browseTimer?.invalidate()
        browseTimer = nil
        guard let scanner else {
            let wanted = configuration.config[ScanlineConfigOptionScanner] as? String
            finish(.failure(AppError(wanted.map { "Scanner \"\($0)\" was not found." } ?? "No scanner was found.")))
            return
        }
        device = scanner
        startController(on: scanner, sessionIsOpen: false)
    }

    private func startController(on scanner: ICScannerDevice, sessionIsOpen: Bool) {
        guard let configuration, let logger else { return }
        let controller = ScannerController(scanner: scanner, configuration: configuration, logger: logger)
        controller.delegate = self
        self.controller = controller
        let proxy = deviceProxy ?? ScannerDelegateProxy()
        deviceProxy = proxy
        proxy.controller = controller
        scanner.delegate = proxy
        if sessionIsOpen {
            proxy.deliverReady(scanner)
        } else {
            controller.scan()
        }
    }

    private func controllerFinished(_ controller: ScannerController, success: Bool) {
        guard controller === self.controller, let outputDirectory else { return }
        guard success else {
            finish(.failure(AppError("The scan failed. Check that paper is loaded and the scanner is not busy.")))
            return
        }
        guard let output = Self.locateOutput(in: outputDirectory) else {
            finish(.failure(AppError("The scanner did not produce a PDF.")))
            return
        }
        finish(.success(output))
    }

    private func finish(_ result: Result<ScanlineOutput, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        browseTimer?.invalidate()
        browseTimer = nil
        if case .failure = result {
            device?.cancelScan()
            forgetDevice()
        } else {
            controller?.delegate = nil
            controller = nil
            deviceProxy?.controller = nil
        }
        configuration = nil
        logger = nil
        continuation.resume(with: result)
    }

    /// libscanline files output under `dir[/tag/year]/name.pdf`; tag aliases are symlinks and are skipped.
    nonisolated static func locateOutput(in directory: URL) -> ScanlineOutput? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return nil }
        var pdf: URL?
        var summary: String?
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            if url.lastPathComponent.hasSuffix(".summary.txt") {
                summary = summary ?? (try? String(contentsOf: url, encoding: .utf8))
            } else if url.pathExtension.lowercased() == "pdf", pdf == nil {
                pdf = url
            }
        }
        return pdf.map { ScanlineOutput(pdf: $0, summary: summary) }
    }
}

extension ScanlineRunner: ScannerBrowserDelegate {
    nonisolated func scannerBrowser(_ scannerBrowser: ScannerBrowser, didFinishBrowsingWithScanner scanner: ICScannerDevice?) {
        Task { @MainActor in self.browsingFinished(with: scanner) }
    }

    nonisolated func scannerBrowser(_ scannerBrowser: ScannerBrowser, didUpdateAvailableScanners availableScanners: [String]) {}
}

extension ScanlineRunner: ScannerControllerDelegate {
    nonisolated func scannerControllerDidFail(_ scannerController: ScannerController) {
        Task { @MainActor in self.controllerFinished(scannerController, success: false) }
    }

    nonisolated func scannerControllerDidSucceed(_ scannerController: ScannerController) {
        Task { @MainActor in self.controllerFinished(scannerController, success: true) }
    }

    nonisolated func scannerController(_ scannerController: ScannerController, didObtainResolutions resolutions: IndexSet) {}
}

/// Forwards device callbacks to libscanline's ScannerController. A session re-opened on a device this process has
/// already used may never send `deviceDidBecomeReady`, which libscanline waits for, so the proxy supplies it.
final class ScannerDelegateProxy: NSObject, ICScannerDeviceDelegate {
    var controller: ScannerController? {
        didSet {
            readyFallback?.cancel()
            readyDelivered = false
        }
    }
    private var readyDelivered = false
    private var readyFallback: DispatchWorkItem?

    func deliverReady(_ device: ICDevice) {
        readyFallback?.cancel()
        guard !readyDelivered, let controller else { return }
        readyDelivered = true
        controller.deviceDidBecomeReady(device)
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        controller?.device(device, didOpenSessionWithError: error)
        guard error == nil else { return }
        let fallback = DispatchWorkItem { [weak self] in self?.deliverReady(device) }
        readyFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: fallback)
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        deliverReady(device)
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        readyFallback?.cancel()
        controller?.device(device, didCloseSessionWithError: error)
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        controller?.device(device, didEncounterError: error)
    }

    func didRemove(_ device: ICDevice) {
        controller?.didRemove(device)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        controller?.scannerDevice(scanner, didSelect: functionalUnit, error: error)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        controller?.scannerDevice(scanner, didScanTo: url)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        controller?.scannerDevice(scanner, didCompleteScanWithError: error)
    }
}

/// Keeps a libscanline browser in `-list` mode running to show available scanners in Settings.
@MainActor
final class ScannerList: NSObject, ObservableObject, ScannerBrowserDelegate {
    @Published private(set) var names: [String] = []
    private var browser: ScannerBrowser?

    func start() {
        guard browser == nil else { return }
        let config = ScanConfiguration(arguments: ["-list"], configFilePath: "")
        let browser = ScannerBrowser(configuration: config, logger: LibScanline.Logger(configuration: config))
        browser.delegate = self
        self.browser = browser
        browser.browse()
    }

    nonisolated func scannerBrowser(_ scannerBrowser: ScannerBrowser, didUpdateAvailableScanners availableScanners: [String]) {
        Task { @MainActor in
            var seen = Set<String>()
            self.names = availableScanners.filter { seen.insert($0).inserted }
        }
    }

    nonisolated func scannerBrowser(_ scannerBrowser: ScannerBrowser, didFinishBrowsingWithScanner scanner: ICScannerDevice?) {}
}
