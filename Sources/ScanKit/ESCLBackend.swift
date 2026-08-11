import Foundation

/// Driverless network-scanning backend speaking eSCL / AirScan (the same
/// protocol Apple's AirScan and most modern network scanners use) directly
/// over HTTP(S) with URLSession.
///
/// This exists because Apple's ImageCaptureCore cannot open a session to
/// some network scanners whose only working macOS path is the vendor's own
/// app (e.g. Epson WF series: ImageCaptureCore returns -9902, yet the device
/// serves a perfectly good eSCL endpoint). eSCL is a small HTTP protocol:
///   POST <base>/ScanJobs   (ScanSettings XML)  -> 201 + Location: <job>
///   GET  <job>/NextDocument                    -> the page bytes (JPEG)
///   DELETE <job>                               -> cancel
///
/// Device certificates are self-signed, so the session trusts them (the
/// session is used only for eSCL scanning).
public final class ESCLBackend: NSObject, ScannerBackend, URLSessionDelegate, @unchecked Sendable {
    private lazy var session = URLSession(
        configuration: .ephemeral, delegate: self, delegateQueue: nil
    )

    /// The in-flight job URL, so cancelScan can DELETE it.
    private let jobLock = NSLock()
    private var currentJob: URL?

    public override init() { super.init() }

    // MARK: Discovery

    /// Some scanners (e.g. Epson WF) serve a working eSCL endpoint but never
    /// advertise `_uscan._tcp` over Bonjour — they only advertise their
    /// AirPrint printer half (`_ipp(s)._tcp`). So we gather hosts from both
    /// the scan and the printer service types, then *confirm* eSCL by fetching
    /// ScannerCapabilities from each candidate; a 200 means it really scans.
    public func discover(timeout: TimeInterval) async -> [ScannerInfo] {
        let candidates = await ESCLDiscovery().run(timeout: min(timeout, 5))
        var byHost: [String: ScannerInfo] = [:]
        await withTaskGroup(of: (String, ScannerInfo)?.self) { group in
            for cand in candidates {
                group.addTask { [self] in
                    for base in cand.baseURLCandidates() where await probeESCL(base) {
                        return (
                            cand.host.lowercased(),
                            ScannerInfo(
                                id: "escl:\(base.absoluteString)",
                                name: "\(cand.name) (eSCL)"
                            )
                        )
                    }
                    return nil
                }
            }
            for await case let (host, info)? in group where byHost[host] == nil {
                byHost[host] = info
            }
        }
        return Array(byHost.values)
    }

    /// True when <base>/ScannerCapabilities answers 200 — the authoritative
    /// test that a host speaks eSCL at this base URL.
    private func probeESCL(_ base: URL) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("ScannerCapabilities"))
        req.timeoutInterval = 4
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Capabilities

    public func capabilities(of scanner: ScannerInfo) async throws -> ScannerCapabilities {
        guard let base = Self.baseURL(from: scanner.id) else { throw ScanError.noDevice }
        let caps = try await fetchCaps(base)
        return ScannerCapabilities(
            resolutions: caps.resolutions,
            // eSCL region units are 1/300", so 300ths -> mm.
            bedSizeMM: CGSize(
                width: Double(caps.maxW) / 300 * 25.4,
                height: Double(caps.maxH) / 300 * 25.4
            )
        )
    }

    // MARK: Scan

    public func scan(
        with scanner: ScannerInfo, config: ScanConfig, to directory: URL
    ) async throws -> URL {
        guard let base = Self.baseURL(from: scanner.id) else { throw ScanError.noDevice }
        let caps = try await fetchCaps(base)
        // Nearest supported resolution at or above the request.
        let dpi = caps.resolutions.first(where: { $0 >= config.dpi })
            ?? caps.resolutions.last ?? config.dpi

        // Region in 1/300" units; a nil area means the full bed.
        let mm = config.areaMM
        let width = mm.map { Int($0.width / 25.4 * 300) } ?? caps.maxW
        let height = mm.map { Int($0.height / 25.4 * 300) } ?? caps.maxH
        let xOff = mm.map { Int($0.minX / 25.4 * 300) } ?? 0
        let yOff = mm.map { Int($0.minY / 25.4 * 300) } ?? 0

        let settings = Self.scanSettingsXML(
            dpi: dpi, mode: config.mode,
            width: width, height: height, xOffset: xOff, yOffset: yOff
        )

        let job = try await postJob(base: base, settings: settings)
        setCurrentJob(job)
        defer { setCurrentJob(nil) }

        let data = try await fetchDocument(job: job)
        // Close the job so the scanner returns to Idle: eSCL expects a
        // trailing NextDocument (which now 404s for a single flatbed page).
        // Skipping this leaves the device "Processing", and the next scan
        // gets 503 Busy — i.e. page 1 works but page 2 fails.
        await closeJob(job)

        let out = directory.appendingPathComponent(
            "escl-\(Int(Date().timeIntervalSince1970)).jpg"
        )
        try data.write(to: out)
        return out
    }

    // MARK: Cancel

    public func cancelScan(scannerName _: String) async -> Bool {
        guard let job = withJobLock({ currentJob }) else { return true }
        var req = URLRequest(url: job)
        req.httpMethod = "DELETE"
        _ = try? await session.data(for: req)
        return true
    }

    // MARK: - eSCL requests

    /// GET <base>/ScannerCapabilities and pull the discrete resolutions and
    /// the platen's max dimensions (in 1/300" units).
    private func fetchCaps(_ base: URL) async throws
        -> (resolutions: [Int], maxW: Int, maxH: Int)
    {
        let (data, resp) = try await session.data(
            from: base.appendingPathComponent("ScannerCapabilities")
        )
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
            let xml = String(data: data, encoding: .utf8)
        else { throw ScanError.sessionFailed("scanner did not return capabilities") }

        let res = Self.allInts(in: xml, tag: "scan:XResolution")
        let resolutions = Array(Set(res)).sorted()
        let maxW = Self.firstInt(in: xml, tag: "scan:MaxWidth") ?? 2550
        let maxH = Self.firstInt(in: xml, tag: "scan:MaxHeight") ?? 3510
        return (
            resolutions.isEmpty ? [100, 200, 300, 600] : resolutions,
            maxW, maxH
        )
    }

    /// POST ScanSettings; returns the created job URL. Honours a 503 +
    /// Retry-After (scanner busy) with a couple of retries.
    private func postJob(base: URL, settings: String) async throws -> URL {
        let scanJobs = base.appendingPathComponent("ScanJobs")
        for attempt in 0..<3 {
            var req = URLRequest(url: scanJobs)
            req.httpMethod = "POST"
            req.setValue("text/xml", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(settings.utf8)
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw ScanError.scanFailed("no HTTP response from scanner")
            }
            switch http.statusCode {
            case 201:
                guard let loc = http.value(forHTTPHeaderField: "Location"),
                    let job = URL(string: loc, relativeTo: base)?.absoluteURL
                else { throw ScanError.scanFailed("scanner returned no job location") }
                return job
            case 503 where attempt < 2:
                // Busy — wait the advertised Retry-After (default a few s).
                let wait = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? 5
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            case 409:
                throw ScanError.scanFailed("scanner rejected the scan settings")
            default:
                throw ScanError.scanFailed("scanner returned HTTP \(http.statusCode)")
            }
        }
        throw ScanError.scanFailed("scanner busy")
    }

    /// GET <job>/NextDocument — the bytes of the (single flatbed) page.
    private func fetchDocument(job: URL) async throws -> Data {
        let (data, resp) = try await session.data(
            from: job.appendingPathComponent("NextDocument")
        )
        guard let http = resp as? HTTPURLResponse else {
            throw ScanError.scanFailed("no HTTP response for document")
        }
        guard http.statusCode == 200, !data.isEmpty else {
            throw ScanError.scanFailed("scanner returned HTTP \(http.statusCode) for the page")
        }
        return data
    }

    /// Drain the job with a final NextDocument (expected 404) so the scanner
    /// finishes it and frees itself for the next scan. Best-effort.
    private func closeJob(_ job: URL) async {
        _ = try? await session.data(from: job.appendingPathComponent("NextDocument"))
    }

    // MARK: - Helpers

    private func setCurrentJob(_ job: URL?) { withJobLock { currentJob = job } }
    private func withJobLock<T>(_ body: () -> T) -> T {
        jobLock.lock(); defer { jobLock.unlock() }; return body()
    }

    /// Device id is "escl:" + the eSCL base URL (e.g. "escl:https://…/eSCL").
    static func baseURL(from id: String) -> URL? {
        guard id.hasPrefix("escl:") else { return nil }
        return URL(string: String(id.dropFirst("escl:".count)))
    }

    private static func esclColorMode(_ mode: ScanMode) -> String {
        switch mode {
        case .blackAndWhite: "BlackAndWhite1"
        case .gray: "Grayscale8"
        case .color: "RGB24"
        }
    }

    private static func scanSettingsXML(
        dpi: Int, mode: ScanMode,
        width: Int, height: Int, xOffset: Int, yOffset: Int
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" \
        xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>2.63</pwg:Version>
          <scan:Intent>Document</scan:Intent>
          <pwg:ScanRegions>
            <pwg:ScanRegion>
              <pwg:Height>\(height)</pwg:Height>
              <pwg:Width>\(width)</pwg:Width>
              <pwg:XOffset>\(xOffset)</pwg:XOffset>
              <pwg:YOffset>\(yOffset)</pwg:YOffset>
              <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
            </pwg:ScanRegion>
          </pwg:ScanRegions>
          <pwg:InputSource>Platen</pwg:InputSource>
          <scan:ColorMode>\(esclColorMode(mode))</scan:ColorMode>
          <scan:XResolution>\(dpi)</scan:XResolution>
          <scan:YResolution>\(dpi)</scan:YResolution>
          <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
        </scan:ScanSettings>
        """
    }

    private static func firstInt(in xml: String, tag: String) -> Int? {
        allInts(in: xml, tag: tag).first
    }

    private static func allInts(in xml: String, tag: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)>(\\d+)</\(tag)>")
        else { return [] }
        let range = NSRange(xml.startIndex..., in: xml)
        return re.matches(in: xml, range: range).compactMap { m in
            Range(m.range(at: 1), in: xml).flatMap { Int(xml[$0]) }
        }
    }

    // MARK: URLSessionDelegate — trust the scanner's self-signed cert.

    public func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Bonjour discovery

/// A host worth probing for eSCL, merged from every service type that
/// mentioned it. `uscanPort`/`uscanTLS`/`rs` are filled when the host
/// actually advertised a scan service; otherwise only the printer half was
/// seen and we fall back to the standard http/https ports.
struct ESCLCandidate: Sendable {
    var name: String
    let host: String
    var uscanPort: Int?
    var uscanTLS = false
    var rs = "eSCL"

    /// Base URLs to try, best first: the advertised scan endpoint, then the
    /// conventional TLS and cleartext ports.
    func baseURLCandidates() -> [URL] {
        var out: [String] = []
        if let p = uscanPort {
            out.append("\(uscanTLS ? "https" : "http")://\(host):\(p)/\(rs)")
        }
        out.append("https://\(host)/\(rs)")
        out.append("http://\(host)/\(rs)")
        return out.compactMap(URL.init(string:))
    }
}

/// Browses eSCL scan services (_uscan/_uscans) *and* AirPrint printer
/// services (_ipp/_ipps), resolving each to a host. The printer types are
/// included because some scanners only advertise those even though they
/// serve eSCL. All state is confined to the main run loop (which
/// NetServiceBrowser/NetService require), so @unchecked Sendable is safe.
private final class ESCLDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate,
    @unchecked Sendable
{
    private let types = ["_uscans._tcp.", "_uscan._tcp.", "_ipps._tcp.", "_ipp._tcp."]
    private var browsers: [NetServiceBrowser] = []
    private var pending: [NetService] = []
    private var byHost: [String: ESCLCandidate] = [:]
    private var cont: CheckedContinuation<[ESCLCandidate], Never>?
    private var done = false

    func run(timeout: TimeInterval) async -> [ESCLCandidate] {
        await withCheckedContinuation { c in
            self.cont = c
            DispatchQueue.main.async {
                for type in self.types {
                    let b = NetServiceBrowser()
                    b.delegate = self
                    b.searchForServices(ofType: type, inDomain: "local.")
                    self.browsers.append(b)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { self.finish() }
            }
        }
    }

    func netServiceBrowser(
        _: NetServiceBrowser, didFind service: NetService, moreComing _: Bool
    ) {
        service.delegate = self
        pending.append(service)  // retain across the async resolve
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        defer { pending.removeAll { $0 === service } }
        guard let host = service.hostName else { return }
        let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let key = cleanHost.lowercased()
        let isScan = service.type.hasPrefix("_uscan")
        let isTLS = service.type.hasPrefix("_uscans") || service.type.hasPrefix("_ipps")

        var cand = byHost[key] ?? ESCLCandidate(name: service.name, host: cleanHost)
        if isScan {
            // Prefer the TLS scan endpoint when both are advertised.
            if cand.uscanPort == nil || (isTLS && !cand.uscanTLS) {
                cand.uscanPort = service.port
                cand.uscanTLS = isTLS
                let txt = service.txtRecordData()
                    .map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
                cand.rs = txt["rs"].flatMap { String(data: $0, encoding: .utf8) } ?? "eSCL"
            }
            cand.name = service.name
        }
        byHost[key] = cand
    }

    func netService(_ service: NetService, didNotResolve _: [String: NSNumber]) {
        pending.removeAll { $0 === service }
    }

    private func finish() {
        guard !done else { return }
        done = true
        browsers.forEach { $0.stop() }
        cont?.resume(returning: Array(byHost.values))
        cont = nil
    }
}
