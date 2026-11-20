import AppKit
import QuartzCore

struct FluidContour {
    let body: CGRect
    let radius: CGFloat
    let edge: ScreenEdge
    var neck: CGFloat = 0
    var pressure: CGFloat = 0
    var anchor: CGFloat = 0.5
    var shear: CGFloat = 0

    var path: CGPath {
        let width = body.width
        let height = body.height
        let r = min(radius, width / 2, height / 2)
        let shoulder = min(11, max(0, (height - 2 * r) * 0.32))
        let c = min(height - r - shoulder, max(r + shoulder, height * (0.40 + 0.20 * anchor)))
        let waist = max(2, shoulder * 0.45 - neck * 0.075)
        let tension = min(1, neck / 8)
        let join = c - shear * 0.36
        let belly = pressure * 1.55 + tension * 1.45
        let tipBias = min(4, max(-4, shear)) * (pressure * 0.35 + tension * 0.65)
        let k = r * 0.5522847498
        let path = CGMutablePath()

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: edge == .left ? body.minX + x : body.maxX - x, y: body.minY + y)
        }
        func line(_ x: CGFloat, _ y: CGFloat) {
            path.addLine(to: point(x, y))
        }
        func curve(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat, _ d: CGFloat, _ e: CGFloat) {
            path.addCurve(to: point(x, y), control1: point(a, b), control2: point(d, e))
        }

        path.move(to: point(r, 0))
        line(width - r, 0)
        curve(width + belly, r, width - r + k, 0, width + belly, r - k)
        curve(width + belly, height - r, width + belly + tipBias * 0.36, r + (height - 2 * r) * 0.34,
              width + belly - tipBias * 0.36, height - r - (height - 2 * r) * 0.34)
        curve(width - r, height, width + belly, height - r + k, width - r + k, height)
        line(r, height)
        curve(0, height - r, r - k, height, 0, height - r + k)
        if neck > 0.001, shoulder > 0 {
            line(0, c + shoulder)
            curve(-neck, join + waist, 0, c + shoulder * 0.36,
                  -neck * 0.55, join + waist * 0.58)
            line(-neck, join - waist)
            curve(0, c - shoulder, -neck * 0.55, join - waist * 0.58, 0, c - shoulder * 0.36)
        }
        line(0, r)
        curve(r, 0, 0, r - k, r - k, 0)
        path.closeSubpath()
        return path
    }
}

/// A retained compositor surface. AppKit owns the desktop backdrop and Core Animation owns the contour.
@MainActor
final class FluidRenderer: NSView {
    private let backdrop = NSVisualEffectView()
    private let foreground = NSView()
    private let maskShape = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let highlight = CAGradientLayer()
    private let highlightMask = CAShapeLayer()
    private let content = CALayer()
    private let arrow = CAShapeLayer()
    private var dark = false
    private var glass = true
    private var pixelScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        backdrop.blendingMode = .behindWindow
        backdrop.material = .popover
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        backdrop.layer?.mask = maskShape
        addSubview(backdrop)
        foreground.layer = CALayer()
        foreground.wantsLayer = true
        foreground.autoresizingMask = [.width, .height]
        addSubview(foreground, positioned: .above, relativeTo: backdrop)
        for child in [fill, highlight, rim, arrow, content] { foreground.layer?.addSublayer(child) }
        highlight.type = .radial
        highlight.mask = highlightMask
        rim.fillColor = nil
        arrow.fillColor = nil
        arrow.lineWidth = 1.55
        arrow.lineCap = .round
        arrow.lineJoin = .round
        content.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        foreground.frame = bounds
        for layer in [maskShape, fill, rim, highlight, highlightMask, arrow] { layer.frame = bounds }
        CATransaction.commit()
    }

    func configure(values: PreferencesValues, appearance: NSAppearance, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        glass = values.glass && !values.opaque && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        pixelScale = scale
        backdrop.isHidden = !glass
        fill.fillColor = NSColor(white: dark ? 0.12 : 0.98, alpha: glass ? (dark ? 0.22 : 0.12) : 1).cgColor
        rim.strokeColor = NSColor.white.withAlphaComponent(dark ? 0.26 : 0.68).cgColor
        rim.lineWidth = 0.65
        arrow.strokeColor = NSColor(white: dark ? 0.86 : 0.31, alpha: 0.90).cgColor
        CATransaction.commit()
    }

    func setPreview(_ image: NSImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        content.contentsScale = pixelScale
        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskShape.path = nil
        fill.path = nil
        rim.path = nil
        highlightMask.path = nil
        arrow.path = nil
        content.opacity = 0
        CATransaction.commit()
    }

    func draw(contour: FluidContour, previewFrame: CGRect, snapshotOpacity: Double, arrowOpacity: Double,
              opticalMotion: CGFloat, simplified: Bool) {
        let path = contour.path
        let body = contour.body
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskShape.path = path
        fill.path = path
        rim.path = path
        highlightMask.path = path
        let highlightX = contour.edge == .left ? body.maxX : body.minX
        let highlightY = body.minY + body.height * contour.anchor + opticalMotion
        let space = CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
        highlight.startPoint = CGPoint(x: highlightX / space.width, y: highlightY / space.height)
        highlight.endPoint = CGPoint(x: (highlightX + max(22, body.width * 0.45)) / space.width,
                                     y: (highlightY + max(28, body.height * 0.42)) / space.height)
        let shine = simplified ? 0.11 : 0.17 + contour.pressure * 0.13 + min(0.10, contour.neck / 100)
        highlight.colors = [NSColor.white.withAlphaComponent(shine).cgColor, NSColor.clear.cgColor]
        let arrowPath = CGMutablePath()
        let direction: CGFloat = contour.edge == .left ? 1 : -1
        arrowPath.move(to: CGPoint(x: body.midX - direction * 2, y: body.midY + 4))
        arrowPath.addLine(to: CGPoint(x: body.midX + direction * 2, y: body.midY))
        arrowPath.addLine(to: CGPoint(x: body.midX - direction * 2, y: body.midY - 4))
        arrow.path = arrowPath
        arrow.opacity = Float(arrowOpacity)
        content.frame = previewFrame
        content.opacity = Float(snapshotOpacity)
        CATransaction.commit()
    }
}
