import Foundation

public enum ScanMode: String, CaseIterable, Sendable {
    case blackAndWhite = "bw"  // 1-bit at the device where supported
    case gray
    case color
}

/// Where a page comes from. `.auto` uses the feeder when it holds paper,
/// otherwise the flatbed. Honoured by backends that expose both (eSCL).
public enum ScanSource: String, CaseIterable, Sendable {
    case auto
    case flatbed
    case feeder
}

public struct ScanConfig: Sendable {
    public var dpi: Int
    public var mode: ScanMode
    public var source: ScanSource
    /// Scan area in millimetres; nil = full bed.
    public var areaMM: CGRect?

    public init(
        dpi: Int = 300, mode: ScanMode = .gray,
        source: ScanSource = .auto, areaMM: CGRect? = nil
    ) {
        self.dpi = dpi
        self.mode = mode
        self.source = source
        self.areaMM = areaMM
    }
}

public struct ScannerInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Name without backend decoration — the single strip point.
    public var baseName: String {
        name.replacingOccurrences(of: " (SANE)", with: "")
            .replacingOccurrences(of: " (eSCL)", with: "")
    }

    /// True when two device names refer to the same model despite vendor
    /// spelling differences ("Canon LiDE 110" vs "CanoScan LiDE 110"):
    /// compares normalized alphanumeric suffixes.
    public static func sameModel(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "(SANE)", with: "")
                .replacingOccurrences(of: "(eSCL)", with: "")
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
        }
        let (na, nb) = (norm(a), norm(b))
        let common = zip(na.reversed(), nb.reversed()).prefix { $0 == $1 }.count
        return common >= 6
    }
}

public struct ScannerCapabilities: Sendable {
    public let resolutions: [Int]
    public let bedSizeMM: CGSize
    public init(resolutions: [Int], bedSizeMM: CGSize) {
        self.resolutions = resolutions
        self.bedSizeMM = bedSizeMM
    }
}

public enum ScanError: LocalizedError {
    case noDevice
    case sessionFailed(String)
    case scanFailed(String)
    case cancelled

    public var errorDescription: String? {
        // Localized in the app's main bundle (ScanKit links into the app).
        switch self {
        case .noDevice: String(localized: "No scanner found")
        case let .sessionFailed(s): String(localized: "Could not open scanner session: \(s)")
        case let .scanFailed(s): String(localized: "Scan failed: \(s)")
        case .cancelled: String(localized: "Scan cancelled")
        }
    }
}

/// A scanning backend (ImageCaptureCore, SANE).
public protocol ScannerBackend {
    /// Browse for devices for up to `timeout` seconds.
    func discover(timeout: TimeInterval) async -> [ScannerInfo]
    func capabilities(of scanner: ScannerInfo) async throws -> ScannerCapabilities
    /// Scan one page to a file (TIFF) and return its URL.
    func scan(
        with scanner: ScannerInfo, config: ScanConfig,
        to directory: URL
    ) async throws -> URL
    /// Scan every page of the job to files and return their URLs. For a
    /// loaded document feeder this is the whole stack; for the flatbed it is
    /// a single page. `onPage` fires as each page's file is written, so the
    /// UI can show pages as they arrive rather than all at the end. Backends
    /// without feeder support get the default below.
    func scanBatch(
        with scanner: ScannerInfo, config: ScanConfig,
        to directory: URL, maxPages: Int,
        onPage: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> [URL]
    /// Cancel a running scan, recovering the device if needed.
    /// Returns true when the device is believed healthy afterwards.
    func cancelScan(scannerName: String) async -> Bool
}

public extension ScannerBackend {
    func scanBatch(
        with scanner: ScannerInfo, config: ScanConfig, to directory: URL,
        maxPages _: Int = .max,
        onPage: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> [URL] {
        let url = try await scan(with: scanner, config: config, to: directory)
        try await onPage(url)
        return [url]
    }

    func cancelScan(scannerName _: String) async -> Bool {
        false
    }
}
