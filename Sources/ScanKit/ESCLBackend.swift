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
                width: Double(caps.platen.w) / 300 * 25.4,
                height: Double(caps.platen.h) / 300 * 25.4
            )
        )
    }

    // MARK: Scan

    public func scan(
        with scanner: ScannerInfo, config: ScanConfig, to directory: URL
    ) async throws -> URL {
        // One page only — never drain a loaded feeder for a single scan.
        guard
            let first = try await scanBatch(
                with: scanner, config: config, to: directory, maxPages: 1, onPage: { _ in }
            ).first
        else { throw ScanError.scanFailed(String(localized: "scanner produced no page")) }
        return first
    }

    /// Scans the flatbed (one page) or, when the document feeder is loaded,
    /// the whole stack (many pages) — all from a single eSCL job by pulling
    /// NextDocument until the scanner reports no more pages. Each written page
    /// is handed to `onPage` immediately so the UI can show it right away.
    public func scanBatch(
        with scanner: ScannerInfo, config: ScanConfig, to directory: URL,
        maxPages: Int = .max,
        onPage: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> [URL] {
        guard let base = Self.baseURL(from: scanner.id) else { throw ScanError.noDevice }
        let caps = try await fetchCaps(base)
        // Nearest supported resolution at or above the request.
        let dpi =
            caps.resolutions.first(where: { $0 >= config.dpi })
            ?? caps.resolutions.last ?? config.dpi

        // Choose the source: explicit request wins; .auto prefers the feeder
        // only when it actually holds paper. A feeder is only possible when
        // the device advertises one.
        let feeder: Bool
        switch config.source {
        case .flatbed: feeder = false
        case .feeder: feeder = caps.adf != nil
        case .auto: feeder = caps.adf != nil ? await adfLoaded(base) : false
        }

        // Region (1/300"): honour an explicit crop, else the full area of the
        // chosen source. Always sent — some scanners reject a feeder job with
        // no ScanRegions.
        let bed = feeder ? (caps.adf ?? caps.platen) : caps.platen
        let region: (w: Int, h: Int, x: Int, y: Int)
        if let mm = config.areaMM {
            region = (
                Int(mm.width / 25.4 * 300), Int(mm.height / 25.4 * 300),
                Int(mm.minX / 25.4 * 300), Int(mm.minY / 25.4 * 300)
            )
        } else {
            region = (bed.w, bed.h, 0, 0)
        }

        let settings = Self.scanSettingsXML(
            dpi: dpi, mode: config.mode,
            source: feeder ? "Feeder" : "Platen", region: region
        )

        let job = try await postJob(base: base, settings: settings)
        setCurrentJob(job)
        defer { setCurrentJob(nil) }

        // Pull pages until the job is done. Each NextDocument yields a page
        // (200), asks us to wait for the next feeder sheet (503 Retry-After),
        // or reports the job finished (404/410) — which also releases the
        // scanner. Covers a single flatbed page and a multi-page feeder stack.
        var pages: [URL] = []
        let stamp = Int(Date().timeIntervalSince1970)
        var waited = 0.0
        var finished = false
        let cap = min(maxPages, 500)
        loop: while pages.count < cap {
            switch try await nextDocument(job) {
            case let .page(data):
                let out = directory.appendingPathComponent("escl-\(stamp)-\(pages.count).jpg")
                try data.write(to: out)
                pages.append(out)
                try await onPage(out)  // surface this page to the UI immediately
                waited = 0
            case let .retry(after):
                // Next feeder sheet not ready yet; wait and re-ask. Bound the
                // total wait so a wedged feeder can't hang forever.
                guard waited < 90 else { break loop }
                let wait = min(max(after, 0.5), 5)
                waited += wait
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            case .done:
                finished = true
                break loop
            }
        }
        // Stopped before the job drained (a preview's one-page limit, or the
        // safety cap): cancel it so the scanner doesn't hold the rest.
        if !finished { await cancelJob(job) }
        guard !pages.isEmpty else {
            throw ScanError.scanFailed(String(localized: "scanner produced no page"))
        }
        return pages
    }

    // MARK: Cancel

    public func cancelScan(scannerName _: String) async -> Bool {
        guard let job = withJobLock({ currentJob }) else { return true }
        await cancelJob(job)
        return true
    }

    /// DELETE a job so the scanner stops feeding and returns to Idle.
    private func cancelJob(_ job: URL) async {
        var req = URLRequest(url: job)
        req.httpMethod = "DELETE"
        _ = try? await session.data(for: req)
    }

    // MARK: - eSCL requests

    struct Caps {
        let resolutions: [Int]
        let platen: (w: Int, h: Int)
        /// Feeder max dimensions, when the scanner advertises an ADF.
        let adf: (w: Int, h: Int)?
    }

    /// GET <base>/ScannerCapabilities: discrete resolutions plus the max
    /// dimensions (1/300") of the platen and, if present, the feeder. The
    /// capabilities XML has a `<scan:Platen>` section followed by an optional
    /// `<scan:Adf>` one, each with its own MaxWidth/MaxHeight.
    private func fetchCaps(_ base: URL) async throws -> Caps {
        let (data, resp) = try await session.data(
            from: base.appendingPathComponent("ScannerCapabilities")
        )
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
            let xml = String(data: data, encoding: .utf8)
        else { throw ScanError.sessionFailed(String(localized: "scanner did not return capabilities")) }

        let resolutions = Array(Set(Self.allInts(in: xml, tag: "scan:XResolution"))).sorted()

        // Split platen vs feeder at the <scan:Adf> boundary.
        let adfStart = xml.range(of: "<scan:Adf")
        let platenXML = adfStart.map { String(xml[xml.startIndex..<$0.lowerBound]) } ?? xml
        let adfXML = adfStart.map { String(xml[$0.lowerBound...]) }

        let platen = (
            w: Self.firstInt(in: platenXML, tag: "scan:MaxWidth") ?? 2550,
            h: Self.firstInt(in: platenXML, tag: "scan:MaxHeight") ?? 3510
        )
        let adf = adfXML.map {
            (
                w: Self.firstInt(in: $0, tag: "scan:MaxWidth") ?? platen.w,
                h: Self.firstInt(in: $0, tag: "scan:MaxHeight") ?? platen.h
            )
        }
        return Caps(
            resolutions: resolutions.isEmpty ? [100, 200, 300, 600] : resolutions,
            platen: platen, adf: adf
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
                throw ScanError.scanFailed(String(localized: "no HTTP response from scanner"))
            }
            switch http.statusCode {
            case 201:
                guard let loc = http.value(forHTTPHeaderField: "Location"),
                    let job = URL(string: loc, relativeTo: base)?.absoluteURL
                else { throw ScanError.scanFailed(String(localized: "scanner returned no job location")) }
                return job
            case 503 where attempt < 2:
                // Busy — wait the advertised Retry-After (default a few s).
                let wait =
                    http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? 5
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            case 409:
                throw ScanError.scanFailed(String(localized: "scanner rejected the scan settings"))
            default:
                throw ScanError.scanFailed(String(localized: "scanner returned HTTP \(http.statusCode)"))
            }
        }
        throw ScanError.scanFailed(String(localized: "scanner busy"))
    }

    private enum NextPage {
        case page(Data)
        /// The next feeder sheet isn't ready yet — wait this long and re-ask.
        case retry(after: TimeInterval)
        /// No more pages; the job is finished.
        case done
    }

    /// GET <job>/NextDocument. 200 = a page; 503 = wait for the next feeder
    /// sheet (Retry-After); anything else (404/410) = the job is finished,
    /// which also releases the device back to Idle.
    private func nextDocument(_ job: URL) async throws -> NextPage {
        var req = URLRequest(url: job.appendingPathComponent("NextDocument"))
        // A feeder sheet can take a while to advance; don't time out early.
        req.timeoutInterval = 120
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return .done }
        switch http.statusCode {
        case 200 where !data.isEmpty:
            return .page(data)
        case 503:
            let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
            return .retry(after: after)
        default:
            return .done
        }
    }

    /// True when the document feeder is loaded (paper present) per the
    /// scanner's status, so the scan should pull from the feeder.
    private func adfLoaded(_ base: URL) async -> Bool {
        // A scanner that just woke (typical on the app's first launch) can
        // report a stale "empty" AdfState on the first query, which made
        // .auto wrongly fall back to the flatbed. Poll a few times and take
        // the first "loaded" answer; a genuinely empty feeder simply never
        // reports loaded and we fall through to false after ~1s.
        let url = base.appendingPathComponent("ScannerStatus")
        for attempt in 0..<3 {
            if let (data, resp) = try? await session.data(from: url),
                (resp as? HTTPURLResponse)?.statusCode == 200,
                let xml = String(data: data, encoding: .utf8),
                xml.contains("ScannerAdfLoaded")
            {
                return true
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        return false
    }

    // MARK: - Helpers

    private func setCurrentJob(_ job: URL?) { withJobLock { currentJob = job } }
    private func withJobLock<T>(_ body: () -> T) -> T {
        jobLock.lock()
        defer { jobLock.unlock() }
        return body()
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
        dpi: Int, mode: ScanMode, source: String,
        region: (w: Int, h: Int, x: Int, y: Int)?
    ) -> String {
        let regions =
            region.map { r in
                """
                  <pwg:ScanRegions>
                    <pwg:ScanRegion>
                      <pwg:Height>\(r.h)</pwg:Height>
                      <pwg:Width>\(r.w)</pwg:Width>
                      <pwg:XOffset>\(r.x)</pwg:XOffset>
                      <pwg:YOffset>\(r.y)</pwg:YOffset>
                      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
                    </pwg:ScanRegion>
                  </pwg:ScanRegions>
                """
            } ?? ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" \
            xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:Version>2.63</pwg:Version>
              <scan:Intent>Document</scan:Intent>
            \(regions)
              <pwg:InputSource>\(source)</pwg:InputSource>
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
                let txt =
                    service.txtRecordData()
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
