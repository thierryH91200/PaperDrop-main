import Foundation
@preconcurrency import ImageCaptureCore

/// ImageCaptureCore backend — drives any scanner macOS supports
/// (local ICA/TWAIN devices and AirScan/eSCL network scanners).
public final class ICCBackend: ScannerBackend {
    /// One browser for the backend's lifetime, and the sole owner of it.
    /// ImageCaptureCore posts blocks to the main thread that outlive a
    /// browse and retain the ICDeviceBrowser when they run, so a per-call
    /// browser that deallocates on return crashes in objc_retain; releasing
    /// it also invalidates the devices it handed out, mid-session.
    private let browser = DeviceBrowser()

    public init() {}

    public func discover(timeout: TimeInterval) async -> [ScannerInfo] {
        await browser.browse(for: timeout).map {
            ScannerInfo(
                id: $0.persistentIDString ?? $0.name ?? UUID().uuidString,
                name: $0.name ?? "Unknown scanner"
            )
        }
    }

    public func capabilities(of scanner: ScannerInfo) async throws -> ScannerCapabilities {
        let session = try await openSession(for: scanner)
        defer { session.close() }
        let unit = try await session.selectFlatbed()
        let res = unit.supportedResolutions.sorted()
        let size = unit.physicalSize  // in current measurement unit
        let mm =
            unit.measurementUnit == .inches
            ? CGSize(width: size.width * 25.4, height: size.height * 25.4)
            : CGSize(width: size.width * 10, height: size.height * 10)
        return ScannerCapabilities(resolutions: res, bedSizeMM: mm)
    }

    public func scan(
        with scanner: ScannerInfo, config: ScanConfig,
        to directory: URL
    ) async throws -> URL {
        let session = try await openSession(for: scanner)
        defer { session.close() }
        _ = try await session.selectFlatbed()
        return try await session.scan(config: config, to: directory)
    }

    private func openSession(for scanner: ScannerInfo) async throws -> ScanSession {
        let devices = await browser.browse(for: 8)
        guard
            let device = devices.first(where: {
                ($0.persistentIDString ?? $0.name) == scanner.id || $0.name == scanner.name
            })
        else { throw ScanError.noDevice }
        let session = ScanSession(device: device)
        try await session.open()
        return session
    }
}

// MARK: - Device browsing

private final class DeviceBrowser: NSObject, ICDeviceBrowserDelegate, @unchecked Sendable {
    private let browser = ICDeviceBrowser()
    private var found: [ICScannerDevice] = []
    private var waiting: [CheckedContinuation<[ICScannerDevice], Never>] = []
    private let lock = NSLock()

    /// The browser outlives every browse, so its delegate and device mask
    /// are one-time setup rather than per-call configuration.
    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.scanner.rawValue
                | ICDeviceLocationTypeMask.local.rawValue
                | ICDeviceLocationTypeMask.shared.rawValue
                | ICDeviceLocationTypeMask.bonjour.rawValue
        )!
    }

    /// A caller arriving while a browse is in flight joins it rather than
    /// restarting the shared browser — cancelling the running one would
    /// hand its caller an empty device list. The first caller's timeout
    /// governs; a browse is short and both callers want the same answer.
    func browse(for timeout: TimeInterval) async -> [ICScannerDevice] {
        await withCheckedContinuation { cont in
            let startBrowse = lock.withLock { () -> Bool in
                waiting.append(cont)
                guard waiting.count == 1 else { return false }
                found.removeAll()
                return true
            }
            guard startBrowse else { return }
            browser.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish()
            }
        }
    }

    /// Both the early-stop and the timeout path call this; whichever claims
    /// the waiters stops the browser and answers them all. Clearing `found`
    /// here releases the ImageCaptureCore devices rather than holding them
    /// until the next browse.
    private func finish() {
        let (waiters, devices) = lock.withLock {
            defer {
                waiting.removeAll()
                found.removeAll()
            }
            return (waiting, found)
        }
        guard !waiters.isEmpty else { return }
        browser.stop()
        for cont in waiters {
            cont.resume(returning: devices)
        }
    }

    func deviceBrowser(_: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        if let scanner = device as? ICScannerDevice {
            lock.withLock { found.append(scanner) }
            // Local scanners arrive fast; stop early when the browser says so.
            if !moreComing {
                finish()
            }
        }
    }

    func deviceBrowser(_: ICDeviceBrowser, didRemove _: ICDevice, moreGoing _: Bool) {}
}

// MARK: - Scan session

private final class ScanSession: NSObject, ICScannerDeviceDelegate, @unchecked Sendable {
    private let device: ICScannerDevice

    private var openCont: CheckedContinuation<Void, Error>?
    private var selectCont: CheckedContinuation<ICScannerFunctionalUnit, Error>?
    private var scanCont: CheckedContinuation<URL, Error>?
    private var scannedURL: URL?
    private let lock = NSLock()

    init(device: ICScannerDevice) {
        self.device = device
        super.init()
        device.delegate = self
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            openCont = cont
            device.requestOpenSession()
        }
    }

    func close() {
        device.requestCloseSession()
    }

    func selectFlatbed() async throws -> ICScannerFunctionalUnit {
        try await withCheckedThrowingContinuation { cont in
            selectCont = cont
            device.requestSelect(.flatbed)
        }
    }

    func scan(config: ScanConfig, to directory: URL) async throws -> URL {
        let unit = device.selectedFunctionalUnit
        // Nearest supported resolution at or above the request.
        let supported = unit.supportedResolutions.sorted()
        let dpi = supported.first(where: { $0 >= config.dpi }) ?? supported.last ?? config.dpi
        unit.resolution = dpi
        unit.pixelDataType =
            switch config.mode {
            case .blackAndWhite: .BW
            case .gray: .gray
            case .color: .RGB
            }
        unit.bitDepth = config.mode == .blackAndWhite ? .depth1Bit : .depth8Bits
        unit.measurementUnit = .inches
        let bed = unit.physicalSize
        if let mm = config.areaMM {
            unit.scanArea = CGRect(
                x: mm.minX / 25.4, y: mm.minY / 25.4,
                width: mm.width / 25.4, height: mm.height / 25.4
            )
        } else {
            unit.scanArea = CGRect(origin: .zero, size: bed)
        }

        device.transferMode = .fileBased
        device.downloadsDirectory = directory
        device.documentName = "scan-\(Int(Date().timeIntervalSince1970))"
        device.documentUTI = "public.tiff"

        return try await withCheckedThrowingContinuation { cont in
            scanCont = cont
            device.requestScan()
        }
    }

    // MARK: ICDeviceDelegate

    func device(_: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            openCont?.resume(throwing: ScanError.sessionFailed(error.localizedDescription))
            openCont = nil
        }
    }

    func deviceDidBecomeReady(_: ICDevice) {
        openCont?.resume()
        openCont = nil
    }

    func device(_: ICDevice, didCloseSessionWithError _: Error?) {}
    func didRemove(_: ICDevice) {
        let err = ScanError.scanFailed("Scanner disconnected")
        openCont?.resume(throwing: err)
        openCont = nil
        selectCont?.resume(throwing: err)
        selectCont = nil
        scanCont?.resume(throwing: err)
        scanCont = nil
    }

    // MARK: ICScannerDeviceDelegate

    func scannerDevice(
        _: ICScannerDevice,
        didSelect unit: ICScannerFunctionalUnit, error: Error?
    ) {
        if let error {
            selectCont?.resume(throwing: ScanError.sessionFailed(error.localizedDescription))
        } else {
            selectCont?.resume(returning: unit)
        }
        selectCont = nil
    }

    func scannerDevice(_: ICScannerDevice, didScanTo url: URL) {
        lock.lock()
        scannedURL = url
        lock.unlock()
    }

    func scannerDevice(
        _: ICScannerDevice,
        didCompleteScanWithError error: Error?
    ) {
        if let error {
            scanCont?.resume(throwing: ScanError.scanFailed(error.localizedDescription))
        } else if let url = scannedURL {
            scanCont?.resume(returning: url)
        } else {
            scanCont?.resume(throwing: ScanError.scanFailed("No file produced"))
        }
        scanCont = nil
    }
}
