import AppKit
import SwiftUI

/// Bordure arrondie en pointillés dessinée avec Core Animation (`CAShapeLayer`).
///
/// Quand `isActive` passe à `true`, les pointillés se mettent à défiler
/// (effet « marching ants ») grâce à une animation infinie de `lineDashPhase` —
/// un effet impossible à obtenir proprement avec les formes SwiftUI natives.
struct AnimatedDashedBorder: NSViewRepresentable {
    var isActive: Bool
    var cornerRadius: CGFloat = 12
    var lineWidth: CGFloat = 1.5
    var dash: [CGFloat] = [6, 4]

    func makeNSView(context: Context) -> DashedBorderView {
        DashedBorderView()
    }

    func updateNSView(_ nsView: DashedBorderView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.lineWidth = lineWidth
        nsView.dash = dash
        nsView.color =
            (isActive
            ? NSColor.controlAccentColor
            : NSColor.gray.withAlphaComponent(0.4)).cgColor
        nsView.setActive(isActive)
    }
}

/// NSView layer-backed qui héberge un `CAShapeLayer` pour le tracé de la bordure.
final class DashedBorderView: NSView {
    private let border = CAShapeLayer()

    var cornerRadius: CGFloat = 12 { didSet { needsLayout = true } }
    var lineWidth: CGFloat = 1.5 {
        didSet {
            border.lineWidth = lineWidth
            needsLayout = true
        }
    }
    var dash: [CGFloat] = [6, 4] {
        didSet { border.lineDashPattern = dash.map { NSNumber(value: $0) } }
    }
    var color: CGColor = NSColor.gray.cgColor { didSet { border.strokeColor = color } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true  // indispensable sur macOS pour avoir un layer
        layer?.addSublayer(border)
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = color
        border.lineWidth = lineWidth
        border.lineDashPattern = dash.map { NSNumber(value: $0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // La NSViewRepresentable ne reçoit pas les clics : elle sert uniquement de décor.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // Recalcule le tracé à chaque redimensionnement, sans animation implicite.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        border.contentsScale = window?.backingScaleFactor ?? 2
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        border.path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }

    /// Démarre / arrête le défilement des pointillés.
    func setActive(_ active: Bool) {
        let key = "marchingAnts"
        if active {
            guard border.animation(forKey: key) == nil else { return }
            let anim = CABasicAnimation(keyPath: "lineDashPhase")
            anim.fromValue = 0
            anim.toValue = dash.reduce(0, +)  // une période complète du motif
            anim.duration = 0.5
            anim.repeatCount = .infinity
            border.add(anim, forKey: key)
        } else {
            border.removeAnimation(forKey: key)
        }
    }
}
