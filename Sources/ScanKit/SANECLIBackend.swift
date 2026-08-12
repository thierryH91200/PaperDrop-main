import Foundation

/// SANE backend that shells out to scanimage — preferring the copy
/// bundled inside the app (Contents/Helpers, with its own libsane +
/// backends), falling back to Homebrew. Carries the LiDE 110 reliability
/// lore: force-calibration on every scan, never kill a scan mid-pass.
public final class SANECLIBackend: ScannerBackend {
    private let scanimage: URL?
    /// SANE env vars pointing the bundled scanimage at the bundled
    /// configs and backends. nil when using a system scanimage.
    private let saneEnvironment: [String: String]?
    private let processLock = NSLock()
    private var currentScanProcess: Process?
    private var cancelRequested = false

    /// Synchronous locked access — NSLock.lock is not callable directly
    /// from async contexts.
    private func withProcessLock<T>(_ body: () -> T) -> T {
        processLock.lock()
        defer { processLock.unlock() }
        return body()
    }

    public init() {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let bundled = contents.appendingPathComponent("Helpers/scanimage")
        if FileManager.default.fileExists(atPath: bundled.path) {
            scanimage = bundled
            // These are read by libsane's own code (not dyld), so they
            // survive hardened runtime. Dylib resolution itself works via
            // the @rpath entries baked in by scripts/vendor-sane.sh.
            // Pre-merged with the app environment once; Process.environment
            // replaces the inherited environment wholesale.
            saneEnvironment = ProcessInfo.processInfo.environment.merging([
                "SANE_CONFIG_DIR": contents.appendingPathComponent("Resources/sane.d").path,
                "LD_LIBRARY_PATH": contents.appendingPathComponent("Frameworks/sane").path,
            ]) { _, new in new }
        } else {
            let candidates = ["/opt/homebrew/bin/scanimage", "/usr/local/bin/scanimage"]
            scanimage = candidates.first { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
            saneEnvironment = nil
        }
    }

    public func discover(timeout: TimeInterval) async -> [ScannerInfo] {
        guard let scanimage else { return [] }
        await releaseHijackedUSB()
        guard
            let out = try? await runAsync(
                scanimage, ["-f", "%d|%v %m%n"],
                // Floor: a full SANE probe genuinely takes up to ~15 s;
                // shorter caller timeouts would just guarantee failure.
                timeout: max(timeout, 15)
            )
        else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return ScannerInfo(id: "sane:" + parts[0], name: parts[1] + " (SANE)")
        }
    }

    public func capabilities(of _: ScannerInfo) async throws -> ScannerCapabilities {
        // genesys devices: trust the common set; full parse of --help later.
        ScannerCapabilities(
            resolutions: [75, 100, 150, 300, 600, 1200, 2400],
            bedSizeMM: CGSize(width: 216.7, height: 300)
        )
    }

    /// Legacy vendor ICA drivers (e.g. "Canon IJScanner2") grab exclusive
    /// USB ownership when ImageCaptureCore browses, then fail to work —
    /// blocking SANE until the device is replugged. Detect and release.
    private func releaseHijackedUSB() async {
        guard
            let out = try? await runAsync(
                URL(fileURLWithPath: "/usr/sbin/ioreg"),
                ["-p", "IOUSB", "-l", "-w0"], timeout: 10
            )
        else { return }
        for line in out.split(separator: "\n")
        where line.contains("UsbExclusiveOwner") && line.contains("IJScanner") {
            // e.g.  "UsbExclusiveOwner" = "pid 2306, Canon IJScanner2"
            if let match = line.range(of: #"pid (\d+)"#, options: .regularExpression),
                let pid = Int32(line[match].dropFirst(4))
            {
                Darwin.kill(pid, SIGTERM)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    /// libusb device addresses change on every replug (and after legacy
    /// vendor drivers are killed), so stored IDs go stale. Re-resolve the
    /// current device string by model name at scan time.
    private func resolveDevice(matching scanner: ScannerInfo) async -> String? {
        let current = await discover(timeout: 15)
        if let exact = current.first(where: { $0.id == scanner.id }) {
            return String(exact.id.dropFirst(5))
        }
        if let byName = current.first(where: {
            ScannerInfo.sameModel($0.name, scanner.name)
        }) {
            return String(byName.id.dropFirst(5))
        }
        return current.count == 1 ? String(current[0].id.dropFirst(5)) : nil
    }

    /// Cancel the running scan and reset the scanner's USB device —
    /// terminating scanimage mid-pass wedges the hardware, and only a
    /// re-enumeration (or physical replug) recovers it.
    public func cancelScan(scannerName: String) async -> Bool {
        let p = withProcessLock { () -> Process? in
            cancelRequested = true
            return currentScanProcess
        }
        guard let p, p.isRunning else { return false }
        p.terminate()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let tokens = ScannerInfo(id: "", name: scannerName).baseName
            .split(separator: " ").map(String.init)
        let reset = USBReset.resetDevice(nameTokens: tokens)
        if reset {
            // Give the device time to re-enumerate.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return reset
    }

    public func scan(
        with scanner: ScannerInfo, config: ScanConfig,
        to directory: URL
    ) async throws -> URL {
        withProcessLock { cancelRequested = false }
        // resolveDevice → discover already releases any hijacked USB device.
        guard let device = await resolveDevice(matching: scanner) else {
            throw ScanError.scanFailed(
                "Scanner not found — check it is connected and powered"
            )
        }
        var lastError: Error = ScanError.scanFailed(String(localized: "scan did not run"))
        for attempt in 1...3 {
            do {
                return try await scanOnce(
                    device: device, config: config,
                    to: directory
                )
            } catch {
                if withProcessLock({ cancelRequested }) {
                    throw ScanError.cancelled
                }
                lastError = error
                let msg = error.localizedDescription
                // Stale/claimed device: release and retry. Anything else
                // (paper jam, cancel) fails immediately.
                guard
                    msg.contains("Invalid argument")
                        || msg.contains("Device busy")
                        || msg.contains("failed: Error during device I/O")
                else { throw error }
                if attempt < 3 {
                    await releaseHijackedUSB()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        throw lastError
    }

    private func scanOnce(
        device: String, config: ScanConfig,
        to directory: URL
    ) async throws -> URL {
        guard let scanimage else { throw ScanError.noDevice }
        let dest = directory.appendingPathComponent(
            "sane-\(Int(Date().timeIntervalSince1970)).tiff"
        )
        var args = [
            "-d", device,
            "--force-calibration",
            "--mode", config.mode == .color ? "Color" : "Gray",
            "--depth", "8",
            "--resolution", String(config.dpi),
            "--format=tiff", "-o", dest.path,
        ]
        if let mm = config.areaMM {
            args += [
                "-l", String(format: "%.1f", mm.minX),
                "-t", String(format: "%.1f", mm.minY),
                "-x", String(format: "%.1f", mm.width),
                "-y", String(format: "%.1f", mm.height),
            ]
        }
        // Generous timeout: killing scanimage mid-pass wedges the scanner.
        _ = try await runAsync(scanimage, args, timeout: 1200, track: true)
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw ScanError.scanFailed(String(localized: "scanimage produced no file"))
        }
        return dest
    }

    private func runAsync(
        _ exe: URL, _ args: [String],
        timeout: TimeInterval,
        track: Bool = false
    ) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            if let saneEnvironment {
                p.environment = saneEnvironment
            }
            if track {
                withProcessLock { currentScanProcess = p }
            }
            // Enforce the timeout (probes can hang when a legacy driver
            // holds the USB device). Scans pass a generous timeout — never
            // kill a scan mid-pass lightly; it wedges the scanner.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning {
                    p.terminate()
                }
            }
            p.terminationHandler = { [weak self] proc in
                if track, let self {
                    self.withProcessLock { self.currentScanProcess = nil }
                }
                let stdout =
                    String(
                        data: out.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: stdout)
                } else {
                    let stderr =
                        String(
                            data: err.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8
                        ) ?? ""
                    cont.resume(
                        throwing: ScanError.scanFailed(
                            stderr.isEmpty ? "scanimage exit \(proc.terminationStatus)" : stderr
                        )
                    )
                }
            }
            do { try p.run() } catch {
                cont.resume(throwing: ScanError.scanFailed(error.localizedDescription))
            }
        }
    }
}
