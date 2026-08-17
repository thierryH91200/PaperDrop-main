import ScanKit
import SwiftUI

struct PageItem: Identifiable {
    let id = UUID()
    let thumbnail: NSImage?
    let sizeLabel: String
    let mmSize: String
    /// Builds the PDF page; the flag controls whether OCR runs.
    let build: (_ ocr: Bool) throws -> PDFWriter.Page
}

@MainActor
final class AppModel: ObservableObject {
    @Published var scanners: [ScannerInfo] = []
    @Published var selectedScannerID: String?
    @Published var discovering = false

    @Published var pages: [PageItem] = []
    @Published var scanning = false
    @Published var saving = false
    @Published var statusText = ""
    @Published var errorText: String?
    @Published var docName = ""

    /// Scan resolution, persisted. Edited in the settings panel.
    @AppStorage("dpi") var dpi = 300

    @AppStorage("scanSource") var scanSource: ScanSource = .auto

    // MARK: Duplex — two passes on a simplex feeder, merged into one document.

    /// Two-sided mode: scan every front, flip the stack, scan every back,
    /// then interleave. Mirrors the standalone FusionRectoVerso tool.
    @AppStorage("duplex") var duplex = false
    @Published var duplexStage: DuplexStage = .fronts
    /// Page count captured at the fronts→backs boundary.
    @Published var rectoCount = 0
    /// True once the two passes are interleaved, so pages stop being labelled
    /// Recto/Verso and the guidance banner steps aside.
    @Published var duplexMerged = false

    @AppStorage("outputMode") var outputMode: OutputMode = .document
    @AppStorage("ocr") var ocrEnabled = true
    @AppStorage("paperSnap") var paperSnap = true
    @AppStorage("uniformPages") var uniformPages = true
    @AppStorage("paperChoice") var paperChoice = "auto"

    // Advanced image adjustments, applied to the pixels after scanning.
    @AppStorage("brightness") var brightness = 0.0  // −0.5 … 0.5
    @AppStorage("contrast") var contrast = 1.0  // 0.5 … 2.0
    @AppStorage("gamma") var gamma = 1.0  // 0.4 … 2.5

    var hasImageAdjustments: Bool {
        brightness != 0 || contrast != 1 || gamma != 1
    }

    func resetImageAdjustments() {
        brightness = 0
        contrast = 1
        gamma = 1
    }
    @AppStorage("paperLandscape") var paperLandscape = false

    /// Toolbar paper choices, derived from Pipeline's tables so paper
    /// dimensions have exactly one home. Keys are stable for the
    /// persisted "paperChoice" preference ("4×6″" → "4x6").
    static let fixedPapers: [(key: String, label: String, wMM: Double, hMM: Double)] = {
        let all = Pipeline.paperSizesMM + Pipeline.photoSizesMM
        let order = ["A4", "A5", "4×6″", "5×7″", "8×10″", "Letter"]
        return order.compactMap { name in
            all.first { $0.name == name }.map {
                (
                    key: name.lowercased()
                        .replacingOccurrences(of: "×", with: "x")
                        .replacingOccurrences(of: "″", with: ""),
                    label: name, wMM: $0.w, hMM: $0.h
                )
            }
        }
    }()

    /// The forced page size, or nil for auto-detect. Paper tables are
    /// portrait, so landscape is the same pair swapped.
    var fixedPaperMM: (w: Double, h: Double)? {
        Self.fixedPapers.first { $0.key == paperChoice }
            .map { paperLandscape ? ($0.hMM, $0.wMM) : ($0.wMM, $0.hMM) }
    }

    @AppStorage("archivePath") var archivePath =
        NSHomeDirectory() + "/Documents/Scans"

    let availableDPIs = [150, 200, 300, 400, 600]

    private let iccBackend = ICCBackend()
    private let saneBackend = SANECLIBackend()
    private let esclBackend = ESCLBackend()
    private let workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PaperDrop", isDirectory: true)

    var selectedScanner: ScannerInfo? {
        scanners.first { $0.id == selectedScannerID }
    }

    var busy: Bool {
        scanning || saving || previewing
    }

    private func backend(for scanner: ScannerInfo) -> ScannerBackend {
        if scanner.id.hasPrefix("escl:") { return esclBackend }
        return scanner.id.hasPrefix("sane:") ? saneBackend : iccBackend
    }

    // MARK: Adjustable preview

    /// A low-resolution flatbed scan kept in memory so brightness/contrast/
    /// gamma can be tuned live before committing to a full scan.
    @Published var previewing = false
    @Published var previewImage: NSImage?
    private var previewRaw: Pipeline.ColorImage?

    var hasPreview: Bool { previewImage != nil }

    /// Grab a quick low-res colour preview of the flatbed.
    func acquirePreview() {
        guard let scanner = selectedScanner, !busy else { return }
        previewing = true
        errorText = nil
        statusText = String(localized: "Previewing…")
        let backend = backend(for: scanner)
        // Follow the chosen source (a feeder preview consumes one sheet;
        // scan() returns a single page, never draining the stack).
        let config = ScanConfig(dpi: 100, mode: .color, source: scanSource)
        Task {
            do {
                try FileManager.default.createDirectory(
                    at: workDir, withIntermediateDirectories: true
                )
                let url = try await backend.scan(with: scanner, config: config, to: workDir)
                let raw = try Pipeline.loadColor(url)
                try? FileManager.default.removeItem(at: url)
                self.previewRaw = raw
                self.refreshPreview()
                self.statusText = ""
            } catch {
                self.errorText = error.localizedDescription
                self.statusText = ""
            }
            self.previewing = false
        }
    }

    /// Re-apply the current tone curve to the stored raw preview.
    func refreshPreview() {
        guard let raw = previewRaw else {
            previewImage = nil
            return
        }
        let lut = Pipeline.toneLUT(brightness: brightness, contrast: contrast, gamma: gamma)
        let shown = lut.map { raw.toneMapped($0) } ?? raw
        previewImage = shown.cgImage.map { NSImage(cgImage: $0, size: .zero) }
    }

    func clearPreview() {
        previewRaw = nil
        previewImage = nil
    }

    // MARK: Discovery

    func discoverScanners() {
        guard !discovering else { return }
        discovering = true
        // The empty state and toolbar picker already show discovery
        // progress; keep the status bar quiet.
        Task {
            // eSCL is the reliable driverless network path; it's the truth
            // for a network scanner that ImageCaptureCore can discover but
            // not open (e.g. Epson WF series).
            let esclFound = await esclBackend.discover(timeout: 6)
            // Sequential: an ICC browse launches legacy vendor drivers that
            // grab the USB device, which would break a concurrent SANE probe.
            let saneFound = await saneBackend.discover(timeout: 6)
            let iccFound = await iccBackend.discover(timeout: 6)

            // The same device often appears via several backends with
            // different name spellings ("Canon LiDE 110" vs "CanoScan
            // LiDE 110", or an Epson via both eSCL and ICC). Match on
            // normalized model suffix and keep the most capable twin:
            // eSCL > SANE > ICC (ICC cannot open devices whose vendor
            // driver is dead).
            func hasTwin(_ dev: ScannerInfo, in list: [ScannerInfo]) -> Bool {
                list.contains { ScannerInfo.sameModel($0.name, dev.name) }
            }
            let saneClean = saneFound.filter { !hasTwin($0, in: esclFound) }
            let iccClean = iccFound.filter {
                !hasTwin($0, in: esclFound) && !hasTwin($0, in: saneClean)
            }
            // Drop the "(SANE)" decoration once a device stands alone.
            let iccTwinRemoved = iccClean.count != iccFound.count
            let sane = saneClean.map { dev in
                ScannerInfo(id: dev.id, name: iccTwinRemoved ? dev.baseName : dev.name)
            }
            let found = esclFound + sane + iccClean
            self.scanners = found
            if self.selectedScanner == nil {
                self.selectedScannerID = found.first?.id
            }
            self.discovering = false
        }
    }

    // MARK: Scanning

    func cancelScan() {
        guard scanning, let scanner = selectedScanner else { return }
        statusText = String(localized: "Cancelling — resetting scanner…")
        Task {
            let reset = await backend(for: scanner)
                .cancelScan(scannerName: scanner.name)
            if !reset {
                self.errorText = String(
                    localized:
                        "Cancelled. If the next scan looks corrupted, unplug and replug the scanner."
                )
            }
        }
    }

    func scanPage() {
        guard let scanner = selectedScanner, !busy else { return }
        clearPreview()
        scanning = true
        errorText = nil
        statusText = String(localized: "Scanning page \(pages.count + 1)…")
        let backend = backend(for: scanner)
        let config = ScanConfig(
            dpi: dpi, mode: outputMode == .color ? .color : .gray, source: scanSource
        )

        let mode = outputMode
        let snap = paperSnap
        let fixed = fixedPaperMM
        let tone = Pipeline.toneLUT(brightness: brightness, contrast: contrast, gamma: gamma)
        Task {
            do {
                try FileManager.default.createDirectory(
                    at: workDir, withIntermediateDirectories: true
                )
                // A loaded feeder yields the whole stack, the flatbed one
                // page; each page is shown the moment it's scanned.
                _ = try await backend.scanBatch(
                    with: scanner, config: config, to: workDir, maxPages: .max
                ) { url in
                    try await self.appendScanned(
                        url: url, dpi: config.dpi, mode: mode, snap: snap,
                        fixed: fixed, tone: tone
                    )
                }
                // Duplex: once the fronts are captured, move straight to the
                // backs so a single scan button drives the whole flow (no
                // separate "Backs →" step).
                if duplex, duplexStage == .fronts, !pages.isEmpty {
                    duplexProceedToBacks()
                }
            } catch {
                if case ScanError.cancelled = error {
                    self.statusText = String(localized: "Scan cancelled")
                } else {
                    self.errorText = error.localizedDescription
                    self.statusText = ""
                }
            }
            self.scanning = false
        }
    }

    /// Process one just-scanned file and append it to the page list. Runs the
    /// heavy image work off the main actor, then hops back to update the UI.
    private func appendScanned(
        url: URL, dpi: Int, mode: OutputMode, snap: Bool,
        fixed: (w: Double, h: Double)?, tone: [UInt8]?
    ) async throws {
        // Let a failure propagate and stop the scan: silently dropping a page
        // would desync the recto/verso counts and corrupt a duplex merge.
        let item = try await Self.process(
            url: url, dpi: dpi, mode: mode, snap: snap, fixed: fixed, tone: tone
        )
        pages.append(item)
        statusText = String(
            localized: "Page \(pages.count): \(item.sizeLabel), \(item.mmSize)"
        )
    }

    nonisolated static func process(
        url: URL, dpi: Int, mode: OutputMode,
        snap: Bool,
        fixed: (w: Double, h: Double)? = nil,
        tone: [UInt8]? = nil
    )
        async throws -> PageItem
    {
        // Clean up the temp scan file on every exit, even if a load throws.
        defer { try? FileManager.default.removeItem(at: url) }

        // Colour keeps the RGB pixels; the crop analysis then works on a
        // luminance copy of them, so the file is decoded only once. Brightness/
        // contrast/gamma (tone) are applied here, before crop and encode.
        var color = mode == .color ? try Pipeline.loadColor(url) : nil
        if let tone { color = color?.toneMapped(tone) }
        var gray = try color?.grayscale() ?? Pipeline.loadGray(url)
        if let tone, color == nil { gray = gray.toneMapped(tone) }

        let slack = snap ? 25.0 : 0

        switch mode {
        case .document:
            let page = Pipeline.processDocument(
                gray, dpi: dpi, snapSlackMM: slack, fixedMM: fixed
            )
            let tiff = try G4.tiff(from: page)
            let stream = try G4.extractStream(fromTIFF: tiff)
            let thumb = page.cgImage.map { thumbnail($0) }
            let capturedPage = page
            return PageItem(
                thumbnail: thumb,
                sizeLabel: "\(stream.data.count / 1024) KB",
                mmSize: mmLabel(page.width, page.height, dpi),
                build: { ocr in
                    let words = ocr ? (try? OCR.recognize(capturedPage)) ?? [] : []
                    return .init(
                        content: .g4(stream), dpi: dpi, ocrWords: words,
                        bedOriginPt: capturedPage.bedOriginPt
                    )
                }
            )

        case .grayscale, .color:
            // Crop is detected on the gray copy; the chosen colour space is
            // then cropped and encoded to match.
            let crop = Pipeline.analyze(gray, dpi: dpi, snapSlackMM: slack, fixedMM: fixed).crop
            let cg: CGImage?
            if mode == .color {
                cg = color?.cropped(crop).cgImage
            } else {
                cg = gray.cropped(crop).cgImage
            }
            guard let cg, let jpeg = ImageEncode.jpeg(cg, dpi: dpi) else {
                throw ScanError.scanFailed(String(localized: "JPEG encode failed"))
            }
            let (w, h) = (crop.x1 - crop.x0, crop.y1 - crop.y0)
            let origin = (
                Double(crop.x0) / Double(dpi) * 72,
                Double(crop.y0) / Double(dpi) * 72
            )
            let content: PDFWriter.Content =
                mode == .color
                ? .jpegColor(jpeg, width: w, height: h)
                : .jpegGray(jpeg, width: w, height: h)
            return PageItem(
                thumbnail: thumbnail(cg),
                sizeLabel: "\(jpeg.count / 1024) KB",
                mmSize: mmLabel(w, h, dpi),
                build: { ocr in
                    // OCR the decoded JPEG on demand — same searchable text
                    // layer as Document mode, now for grayscale/colour too.
                    var words: [OCR.Word] = []
                    if ocr, let img = ImageDecode.cgImage(jpeg) {
                        words = (try? OCR.recognize(img)) ?? []
                    }
                    return .init(
                        content: content, dpi: dpi, ocrWords: words, bedOriginPt: origin
                    )
                }
            )
        }
    }

    /// Downscaled preview — full-resolution scans must not live in the view.
    nonisolated static func thumbnail(_ img: CGImage, maxSide: Int = 400) -> NSImage {
        let scale = Double(maxSide) / Double(max(img.width, img.height))
        // RGB context so colour scans keep their colour in the preview
        // (gray/1-bit sources still render fine here).
        guard scale < 1,
            let ctx = CGContext(
                data: nil,
                width: Int(Double(img.width) * scale),
                height: Int(Double(img.height) * scale),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return NSImage(cgImage: img, size: .zero) }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        guard let small = ctx.makeImage() else {
            return NSImage(cgImage: img, size: .zero)
        }
        return NSImage(cgImage: small, size: .zero)
    }

    nonisolated static func mmLabel(_ w: Int, _ h: Int, _ dpi: Int) -> String {
        let mmW = Double(w) / Double(dpi) * 25.4
        let mmH = Double(h) / Double(dpi) * 25.4
        return Pipeline.paperSizeName(widthMM: mmW, heightMM: mmH)
            ?? "\(Int(mmW))×\(Int(mmH)) mm"
    }

    // MARK: Saving

    /// A duplex capture whose backs have been scanned — Save will interleave.
    var duplexReadyToMerge: Bool {
        duplex && !duplexMerged && duplexStage == .backs && pages.count > rectoCount
    }

    /// Whether Save should be offered. During a duplex capture it waits until
    /// the backs have been scanned (then Save interleaves automatically).
    var canSave: Bool {
        guard !pages.isEmpty, !busy else { return false }
        if duplex, !duplexMerged { return duplexReadyToMerge }
        return true
    }

    func savePDF() {
        // Finish a duplex capture by interleaving the two passes first.
        if duplexReadyToMerge { duplexMerge() }
        guard !pages.isEmpty, !busy else { return }
        saving = true
        errorText = nil
        let ocr = ocrEnabled
        statusText =
            ocr
            ? String(localized: "Assembling PDF (OCR)…")
            : String(localized: "Assembling PDF…")
        let name = docName.trimmingCharacters(in: .whitespaces)
        let fileName =
            (name.isEmpty
                ? "Scan " + Date().formatted(date: .abbreviated, time: .shortened)
                : name) + ".pdf"
        let dir = URL(fileURLWithPath: archivePath)
        let builders = pages.map(\.build)

        let uniform = uniformPages
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                var pdfPages: [PDFWriter.Page] = []
                for build in builders {
                    try pdfPages.append(build(ocr))
                }
                if uniform, pdfPages.count > 1 {
                    let maxW = pdfPages.map(\.naturalSizePt.w).max()!
                    let maxH = pdfPages.map(\.naturalSizePt.h).max()!
                    for i in pdfPages.indices {
                        pdfPages[i].pageSizePt = (maxW, maxH)
                    }
                }
                let data = PDFWriter.build(pages: pdfPages)
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true
                )
                let dest = dir.appendingPathComponent(fileName)
                try data.write(to: dest)
                await MainActor.run {
                    self.pages = []
                    self.docName = ""
                    self.saving = false
                    self.resetDuplexStaging()
                    self.statusText = String(
                        localized: "Saved \(fileName) (\(data.count / 1024) KB)"
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                await MainActor.run {
                    self.saving = false
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func deletePage(_ id: UUID) {
        pages.removeAll { $0.id == id }
    }

    func movePage(id: UUID, before targetID: UUID) {
        guard id != targetID,
            let from = pages.firstIndex(where: { $0.id == id }),
            let to = pages.firstIndex(where: { $0.id == targetID })
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            pages.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to
            )
        }
    }

    func discardAll() {
        pages = []
        docName = ""
        statusText = ""
        errorText = nil
        resetDuplexStaging()
    }

    // MARK: Duplex staging

    /// Lock in the scanned fronts and switch to scanning the (flipped) backs.
    func duplexProceedToBacks() {
        guard !pages.isEmpty else { return }
        rectoCount = pages.count
        duplexStage = .backs
    }

    /// Interleave fronts with the reversed backs into a single document.
    /// The backs were scanned with the whole stack flipped, so they arrive
    /// last-sheet-first — hence `backs[count-1-i]`, as in FusionRectoVerso.
    func duplexMerge() {
        let fronts = Array(pages.prefix(rectoCount))
        let backs = Array(pages.dropFirst(rectoCount))
        guard !backs.isEmpty else { return }
        var merged: [PageItem] = []
        for i in 0..<max(fronts.count, backs.count) {
            if i < fronts.count { merged.append(fronts[i]) }
            if i < backs.count { merged.append(backs[backs.count - 1 - i]) }
        }
        pages = merged
        duplexStage = .fronts
        rectoCount = 0
        duplexMerged = true
    }

    func resetDuplexStaging() {
        duplexStage = .fronts
        rectoCount = 0
        duplexMerged = false
    }

    /// Recto/Verso caption for the page at `index` during the two capture
    /// passes, or nil once merged or when duplex is off.
    func duplexTag(for index: Int) -> String? {
        guard duplex, !duplexMerged else { return nil }
        if duplexStage == .backs, index >= rectoCount {
            return String(localized: "Verso \(index - rectoCount + 1)")
        }
        return String(localized: "Recto \(index + 1)")
    }
}

enum DuplexStage {
    case fronts
    case backs
}

/// How a scanned page is rendered into the PDF.
enum OutputMode: String, CaseIterable, Sendable {
    case document  // 1-bit CCITT G4 (compact text, OCR)
    case grayscale  // 8-bit grayscale JPEG
    case color  // 24-bit RGB JPEG
}
