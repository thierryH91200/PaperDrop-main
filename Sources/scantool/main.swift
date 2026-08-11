import Foundation
import ScanKit

// scantool — headless test harness for ScanKit backends.
//   scantool list
//   scantool caps
//   scantool scan <out-dir> [dpi] [bw|gray|color]
//   scantool process <in.tiff> <out.pdf> [dpi] [padWxH] [fixed:WxH]
//     padWxH   pad the page to WxH mm (e.g. 210x297)
//     fixed:WxH  force the paper size instead of auto-detecting
//   scantool usbreset [name tokens…]

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "list"
let backend = ICCBackend()

func firstScanner() async -> ScannerInfo? {
    let devices = await backend.discover(timeout: 8)
    for d in devices {
        print("device: \(d.name) [\(d.id)]")
    }
    return devices.first
}

Task {
    defer { exit(0) }
    switch command {
    case "list":
        _ = await firstScanner()
    case "caps":
        guard let s = await firstScanner() else {
            print("no scanner")
            return
        }
        do {
            let caps = try await backend.capabilities(of: s)
            print("resolutions: \(caps.resolutions)")
            print("bed: \(Int(caps.bedSizeMM.width)) x \(Int(caps.bedSizeMM.height)) mm")
        } catch { print("error: \(error.localizedDescription)") }
    case "scan":
        guard let s = await firstScanner() else {
            print("no scanner")
            return
        }
        let dir = URL(fileURLWithPath: args.count > 2 ? args[2] : ".")
        let dpi = args.count > 3 ? Int(args[3]) ?? 300 : 300
        let mode = args.count > 4 ? ScanMode(rawValue: args[4]) ?? .gray : .gray
        do {
            let t0 = Date()
            let url = try await backend.scan(
                with: s, config: ScanConfig(dpi: dpi, mode: mode), to: dir
            )
            print("scanned to \(url.path) in \(Int(-t0.timeIntervalSinceNow))s")
        } catch { print("error: \(error.localizedDescription)") }
    case "process":
        // scantool process <in-gray.tiff> <out.pdf> [dpi]
        guard args.count > 3 else {
            print("process <in.tiff> <out.pdf> [dpi]")
            return
        }
        let dpi = args.count > 4 ? Int(args[4]) ?? 300 : 300
        do {
            let t0 = Date()
            let gray = try Pipeline.loadGray(URL(fileURLWithPath: args[2]))
            // Optional 6th arg: force a paper size, e.g. "fixed:148x210"
            var fixed: (w: Double, h: Double)? = nil
            if args.count > 6, args[6].hasPrefix("fixed:") {
                let parts = args[6].dropFirst(6).split(separator: "x")
                    .compactMap { Double($0) }
                if parts.count == 2 {
                    fixed = (parts[0], parts[1])
                }
            }
            let page = Pipeline.processDocument(gray, dpi: dpi, fixedMM: fixed)
            let tiff = try G4.tiff(from: page)
            let stream = try G4.extractStream(fromTIFF: tiff)
            let words = (try? OCR.recognize(page)) ?? []
            print("ocr: \(words.count) text segments")
            // Optional 5th arg: pad to a page size, e.g. "210x297"
            var pageSize: (Double, Double)? = nil
            if args.count > 5 {
                let parts = args[5].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 {
                    pageSize = (parts[0] / 25.4 * 72, parts[1] / 25.4 * 72)
                }
            }
            let pdf = PDFWriter.build(pages: [
                .init(
                    content: .g4(stream), dpi: dpi,
                    ocrWords: words,
                    pageSizePt: pageSize,
                    bedOriginPt: page.bedOriginPt
                )
            ])
            try pdf.write(to: URL(fileURLWithPath: args[3]))
            let mmW = Double(page.width) / Double(dpi) * 25.4
            let mmH = Double(page.height) / Double(dpi) * 25.4
            print(
                "page \(Int(mmW)) x \(Int(mmH)) mm, pdf \(pdf.count / 1024) KB, "
                    + "\(String(format: "%.2f", -t0.timeIntervalSinceNow))s"
            )
        } catch { print("error: \(error.localizedDescription)") }
    case "usbreset":
        let tokens = args.count > 2 ? Array(args[2...]) : ["canoscan", "lide"]
        print("reset:", USBReset.resetDevice(nameTokens: tokens))
    default:
        print(
            "usage: scantool list|caps|scan [dir] [dpi] [mode] | "
                + "process <in> <out> [dpi] [padWxH] [fixed:WxH] | usbreset [tokens]"
        )
    }
}

// ImageCaptureCore delivers delegate callbacks via the main run loop —
// blocking the main thread (semaphore) would deadlock discovery.
RunLoop.main.run()
