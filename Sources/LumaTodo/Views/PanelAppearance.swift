import SwiftUI

struct PanelAppearance: DynamicProperty {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var dark: Bool { scheme == .dark }
    var highContrast: Bool { contrast == .increased }
    var accent: Color {
        dark ? Color(red: 0.44, green: 0.84, blue: 0.86) : Color(red: 0.07, green: 0.43, blue: 0.49)
    }
    var secondary: Color { highContrast ? .primary : .secondary }
    var line: Color { .primary.opacity(highContrast ? 0.28 : (dark ? 0.12 : 0.10)) }

    func usesGlass(_ values: PreferencesValues) -> Bool {
        values.glass && !values.opaque && !reduceTransparency
    }

    func animation(_ values: PreferencesValues) -> Animation? {
        values.animations && !reduceMotion ? .spring(duration: 0.24, bounce: 0) : nil
    }
}

struct FrostedSurface: ViewModifier {
    let values: PreferencesValues
    let radius: CGFloat
    var editor: Bool
    private var appearance = PanelAppearance()

    init(values: PreferencesValues, radius: CGFloat, editor: Bool = false) {
        self.values = values
        self.radius = radius
        self.editor = editor
    }

    func body(content: Content) -> some View {
        let contour = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            if editor {
                // Keep the editor canvas stable. Its controls and input highlights retain native glass.
                contour.fill(Color(nsColor: .windowBackgroundColor))
                    .overlay {
                        if appearance.usesGlass(values) {
                            LinearGradient(colors: [appearance.accent.opacity(0.045), .clear],
                                           startPoint: .topTrailing, endPoint: .center)
                                .clipShape(contour)
                        }
                    }
            } else if appearance.usesGlass(values) {
                BehindWindowMaterial(radius: radius, dark: appearance.dark, highContrast: appearance.highContrast)
                    .overlay {
                        contour.fill(.clear)
                            .glassEffect(.clear.tint(tint), in: contour)
                    }
                    .allowsHitTesting(false)
            } else {
                contour.fill(appearance.dark ? Color(white: 0.15) : Color(white: 0.97))
            }
        }
        .overlay {
            contour.strokeBorder(
                LinearGradient(colors: [upperEdge, lowerEdge], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: appearance.highContrast ? 1.25 : 0.75
            )
            .allowsHitTesting(false)
        }
    }

    private var tint: Color {
        appearance.dark ? Color(red: 0.06, green: 0.11, blue: 0.15).opacity(0.22)
            : Color(red: 0.82, green: 0.93, blue: 0.97).opacity(0.17)
    }

    private var upperEdge: Color {
        if appearance.highContrast { return appearance.line }
        return .white.opacity(editor ? (appearance.dark ? 0.17 : 0.56) : (appearance.dark ? 0.26 : 0.72))
    }

    private var lowerEdge: Color {
        if appearance.highContrast { return appearance.line }
        return appearance.dark ? .white.opacity(0.09) : .black.opacity(editor ? 0.13 : 0.12)
    }
}

// This is the AppKit desktop backdrop. The optical perimeter above uses native Liquid Glass.
private struct BehindWindowMaterial: NSViewRepresentable {
    let radius: CGFloat
    let dark: Bool
    let highContrast: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .popover
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.alphaValue = highContrast ? 1 : (dark ? 0.88 : 0.84)
    }
}

struct GlassInputSurface: ViewModifier {
    let values: PreferencesValues
    var focused: Bool
    private var appearance = PanelAppearance()

    init(values: PreferencesValues, focused: Bool = false) {
        self.values = values
        self.focused = focused
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        content.background {
            if appearance.usesGlass(values) {
                shape.fill(.clear)
                    .glassEffect(.regular.tint(appearance.accent.opacity(focused ? 0.10 : 0.025)), in: shape)
            } else {
                shape.fill(.primary.opacity(appearance.dark ? 0.09 : 0.045))
            }
        }
        .overlay {
            shape.strokeBorder(focused ? appearance.accent.opacity(0.85) : appearance.line, lineWidth: focused ? 1.3 : 0.75)
                .allowsHitTesting(false)
        }
        .animation(appearance.animation(values), value: focused)
    }
}
