import Foundation

public enum ScanMode: String, CaseIterable, Sendable {
    case blackAndWhite = "bw"  // 1-bit at the device where supported
    case gray
    case color
}

public struct ScanConfig: Sendable {
    public var dpi: Int
    public var mode: ScanMode
    /// Scan area in millimetres; nil = full bed.
    public var areaMM: CGRect?

    public init(dpi: Int = 300, mode: ScanMode = .gray, areaMM: CGRect? = nil) {
        self.dpi = dpi
        self.mode = mode
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
        switch self {
        case .noDevice: "No scanner found"
        case let .sessionFailed(s): "Could not open scanner session: \(s)"
        case let .scanFailed(s): "Scan failed: \(s)"
        case .cancelled: "Scan cancelled"
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
    /// Cancel a running scan, recovering the device if needed.
    /// Returns true when the device is believed healthy afterwards.
    func cancelScan(scannerName: String) async -> Bool
}

public extension ScannerBackend {
    func cancelScan(scannerName _: String) async -> Bool {
        false
    }
}
