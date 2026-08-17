import ScanKit
import SwiftUI

/// Gentle hover feedback — macOS button styles give little or none.
/// Inert while the control is disabled.
struct HoverHighlight: ViewModifier {
    var scale: CGFloat = 1.02
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let active = hovering && isEnabled
        content
            .brightness(active ? 0.07 : 0)
            .scaleEffect(active ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: active)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(scale: CGFloat = 1.02) -> some View {
        modifier(HoverHighlight(scale: scale))
    }
}

/// UI presentation for the scan-source options — kept in the app layer so
/// ScanKit stays free of view concerns.
extension ScanSource {
    var label: String {
        switch self {
        case .auto: String(localized: "Automatic")
        case .flatbed: String(localized: "Flatbed")
        case .feeder: String(localized: "Feeder")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// 0 = General settings, 1 = Advanced (image adjustments).
    @State private var settingsTab = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    // A fixed-height top bar, always present so toggling
                    // Recto-verso never shifts the layout. It carries the
                    // duplex guidance when active, and is empty otherwise.
                    topBar
                    Divider()
                    if !model.pages.isEmpty {
                        pageGrid
                    } else if model.hasPreview || model.previewing {
                        previewView
                    } else {
                        emptyState
                    }
                }
                // Match the panel's top inset so the title-bar strip stays
                // clear at the very top of the window.
                .padding(.top, 40)
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 480)
        .onAppear { model.discoverScanners() }
    }

    // MARK: Sidebar — scan settings panel

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scan Settings")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.bottom, 2)
            Form {
                // Device stays visible above the tab switch.
                Section {
                    Picker("Scanner", selection: $model.selectedScannerID) {
                        if model.scanners.isEmpty {
                            (model.discovering ? Text("Searching…") : Text("No scanners"))
                                .tag(String?.none)
                        }
                        ForEach(model.scanners) { s in
                            Text(s.name).tag(String?.some(s.id))
                        }
                    }
                    Button {
                        model.discoverScanners()
                    } label: {
                        Label("Search Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.discovering)
                }

                Picker("", selection: $settingsTab) {
                    Text("General").tag(0)
                    Text("Advanced").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if settingsTab == 0 {
                    generalTab
                } else {
                    advancedTab
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    model.discardAll()
                } label: {
                    Text("Discard").frame(maxWidth: .infinity)
                }
                .disabled(model.busy || model.pages.isEmpty)
                Button {
                    model.savePDF()
                } label: {
                    Label("Save PDF", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
            }
            .padding(12)
        }
        // Clear the floating toolbar / window controls at the top.
        .padding(.top, 40)
        .frame(width: 260)
    }

    // MARK: General settings tab

    @ViewBuilder
    private var generalTab: some View {
        Picker("Source", selection: $model.scanSource) {
            ForEach(ScanSource.allCases, id: \.self) { src in
                Text(src.label).tag(src)
            }
        }
        Toggle(
            "Two-sided (recto/verso)",
            isOn: Binding(
                get: { model.duplex },
                set: { on in
                    model.duplex = on
                    if !on { model.resetDuplexStaging() }
                }
            ))
        Picker("Mode", selection: $model.outputMode) {
            Text("Document").tag(OutputMode.document)
            Text("Grayscale").tag(OutputMode.grayscale)
            Text("Color").tag(OutputMode.color)
        }
        Picker("Resolution", selection: $model.dpi) {
            ForEach(model.availableDPIs, id: \.self) { d in
                Text("\(d) dpi").tag(d)
            }
        }
        Picker("Paper", selection: $model.paperChoice) {
            Text("Auto size").tag("auto")
            ForEach(AppModel.fixedPapers, id: \.key) { paper in
                Text(paper.label).tag(paper.key)
            }
        }
        // Snapping only refines an auto-detected size; with a forced paper
        // size it has no effect, so hide it entirely then.
        if model.paperChoice == "auto" {
            Toggle("Snap to standard sizes", isOn: $model.paperSnap)
        }
        // Orientation only bites alongside a forced paper size; auto-detect
        // derives it from the page it found.
        Picker("Orientation", selection: $model.paperLandscape) {
            Text("Portrait").tag(false)
            Text("Landscape").tag(true)
        }
        .disabled(model.fixedPaperMM == nil)

        Section {
            LabeledContent("Format") { Text("PDF") }
            TextField("Document name", text: $model.docName)
                .onSubmit { model.savePDF() }
            LabeledContent("Folder") {
                HStack(spacing: 6) {
                    Text(URL(fileURLWithPath: model.archivePath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Toggle("OCR", isOn: $model.ocrEnabled)
                .help("Add an invisible, searchable text layer")
            Toggle("Uniform pages", isOn: $model.uniformPages)
        }
    }

    // MARK: Advanced settings tab (image adjustments)

    @ViewBuilder
    private var advancedTab: some View {
        Section {
            // Brightness/contrast as percentages (neutral = 0 % / 100 %);
            // gamma reads more naturally as a plain factor. Each edit also
            // refreshes the live preview when one is loaded.
            adjustmentRow("Brightness", value: toneBinding(\.brightness), in: -0.5...0.5) {
                String(format: "%+.0f %%", $0 * 100)
            }
            adjustmentRow("Contrast", value: toneBinding(\.contrast), in: 0.5...2.0) {
                String(format: "%.0f %%", $0 * 100)
            }
            adjustmentRow("Gamma", value: toneBinding(\.gamma), in: 0.4...2.5) {
                String(format: "%.2f", $0)
            }
        }
        Section {
            Button("Reset") {
                model.resetImageAdjustments()
                model.refreshPreview()
            }
            .disabled(!model.hasImageAdjustments)
        }
    }

    /// Slider binding that persists the value and refreshes the live preview.
    private func toneBinding(_ path: ReferenceWritableKeyPath<AppModel, Double>) -> Binding<Double> {
        Binding(
            get: { model[keyPath: path] },
            set: {
                model[keyPath: path] = $0
                model.refreshPreview()
            }
        )
    }

    private func adjustmentRow(
        _ title: LocalizedStringKey, value: Binding<Double>,
        in range: ClosedRange<Double>, display: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: Top bar (fixed height; duplex guidance when active)

    private static let topBarHeight: CGFloat = 38

    @ViewBuilder
    private var topBar: some View {
        let duplex = model.duplex && !model.duplexMerged
        let fronts = model.duplexStage == .fronts
        HStack(spacing: 9) {
            if duplex {
                Image(systemName: fronts ? "1.circle.fill" : "2.circle.fill")
                    .foregroundStyle(.tint)
                Text(fronts ? "Scan the fronts" : "Now scan the backs")
                    .fontWeight(.medium)
                Text(verbatim: "·").foregroundStyle(.secondary)
                Text(
                    fronts
                        ? "Load the stack in the feeder."
                        : "Flip the stack, scan, then Save PDF."
                )
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.topBarHeight)
        .frame(maxWidth: .infinity)
        .background {
            if duplex { Color.accentColor.opacity(0.10) }
        }
    }

    /// Pick the archive folder that saved PDFs land in.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.archivePath)
        if panel.runModal() == .OK, let url = panel.url {
            model.archivePath = url.path
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            if model.discovering {
                ProgressView()
                Text("Looking for scanners…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else if model.scanners.isEmpty {
                noScannerState
            } else {
                readyToScanState
            }
            Spacer()
            // Two spacers below, one above: every state sits slightly above
            // centre, so finishing a search doesn't jump the content.
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noScannerState: some View {
        VStack(spacing: 0) {
            Image(systemName: "scanner")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No scanner found")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 18)
            Text("Check it's connected and powered on")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.top, 6)
            Button {
                model.discoverScanners()
            } label: {
                Label("Search Again", systemImage: "arrow.clockwise")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .hoverHighlight()
            .padding(.top, 24)
        }
    }

    private var readyToScanState: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Place a document on the scanner")
                .font(.title3)
                .foregroundStyle(.secondary)
            if model.scanning {
                ProgressView()
                cancelScanButton("Cancel Scan", large: true)
            } else if model.previewing {
                ProgressView()
                Text("Previewing…").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Button {
                        model.acquirePreview()
                    } label: {
                        Label("Preview", systemImage: "eye")
                            .font(.title3)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .controlSize(.large)
                    .hoverHighlight()
                    .disabled(model.busy || model.selectedScanner == nil)

                    Button(action: model.scanPage) {
                        Label("Scan First Page", systemImage: "scanner")
                            .font(.title3)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .hoverHighlight()
                    .disabled(model.busy || model.selectedScanner == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
            if model.selectedScanner == nil {
                Text("Choose a scanner in the panel")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Adjustable preview

    private var previewView: some View {
        VStack(spacing: 0) {
            if let img = model.previewImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
                HStack(spacing: 12) {
                    Button {
                        model.acquirePreview()
                    } label: {
                        Label("Preview again", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.busy)
                    .hoverHighlight()
                    Button(action: model.scanPage) {
                        Label("Scan First Page", systemImage: "scanner")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.selectedScanner == nil)
                    .keyboardShortcut(.defaultAction)
                    .hoverHighlight()
                    Button("Close") { model.clearPreview() }
                        .disabled(model.busy)
                        .hoverHighlight()
                }
                .padding(.bottom, 16)
            } else {
                Spacer()
                ProgressView()
                Text("Previewing…").foregroundStyle(.secondary).padding(.top, 8)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Page grid

    private let columns = [
        GridItem(
            .adaptive(minimum: 150, maximum: 190),
            spacing: 16
        )
    ]

    @State private var draggingID: UUID?

    private var pageGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { idx, page in
                    PageCell(page: page, number: idx + 1, kindLabel: model.duplexTag(for: idx)) {
                        model.deletePage(page.id)
                    }
                    .opacity(draggingID == page.id ? 0.4 : 1)
                    .onDrag {
                        draggingID = page.id
                        return NSItemProvider(object: page.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: PageReorderDelegate(
                            targetID: page.id,
                            draggingID: $draggingID,
                            model: model
                        )
                    )
                }
                scanNextCell
            }
            .padding(16)
        }
    }

    private var scanNextCell: some View {
        Button(action: model.scanPage) {
            VStack(spacing: 10) {
                if model.scanning {
                    ProgressView()
                    Text("Scanning…").font(.callout)
                    cancelScanButton("Cancel", large: false)
                } else {
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 34, weight: .thin))
                    Text("Scan Next Page").font(.callout)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(.tertiary)
            )
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.01)
        .disabled(model.busy)
        .keyboardShortcut(.defaultAction)
    }

    private func cancelScanButton(_ title: LocalizedStringKey, large: Bool) -> some View {
        Button(role: .destructive) {
            model.cancelScan()
        } label: {
            Label(title, systemImage: "stop.circle")
                .padding(.horizontal, large ? 10 : 0)
                .padding(.vertical, large ? 4 : 0)
        }
        .buttonStyle(.bordered)
        .controlSize(large ? .large : .regular)
        .hoverHighlight()
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.scanning || model.saving {
                ProgressView().controlSize(.small)
            }
            if let err = model.errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(err)
            } else {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !model.pages.isEmpty {
                (model.pages.count == 1
                    ? Text("1 page") : Text("\(model.pages.count) pages"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(.bar)
    }

}

// MARK: - Drag reorder

struct PageReorderDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggingID: UUID?
    let model: AppModel

    func dropEntered(info _: DropInfo) {
        if let dragging = draggingID {
            model.movePage(id: dragging, before: targetID)
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

// MARK: - Page cell

struct PageCell: View {
    let page: PageItem
    let number: Int
    /// Recto/Verso caption during a duplex capture; nil = the usual "Page N".
    var kindLabel: String? = nil
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb = page.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "doc")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 200)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Remove this page")
                    .hoverHighlight(scale: 1.15)
                }
            }
            Group {
                if let kindLabel {
                    Text(verbatim: "\(kindLabel) · \(page.mmSize) · \(page.sizeLabel)")
                        .fontWeight(.medium)
                } else {
                    Text("Page \(number) · \(page.mmSize) · \(page.sizeLabel)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove Page", role: .destructive, action: onDelete)
        }
    }
}
