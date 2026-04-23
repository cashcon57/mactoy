import SwiftUI

/// Cross-version wrapper for Tahoe's Liquid Glass APIs.
///
/// On macOS 26+ it applies `.glassEffect(...)` directly. On macOS 13–15
/// it falls back to a translucent `.regularMaterial` card with an
/// optional tint overlay and a subtle inner stroke — close enough in
/// feel that the layout doesn't read as broken without glass, and
/// everything still uses system materials so dark mode, Reduce
/// Transparency, and High Contrast work without extra code paths.
extension View {
    /// Apply a Liquid Glass surface (or material fallback) to the view.
    ///
    /// - Parameters:
    ///   - cornerRadius: Rounded-rectangle radius. Pass `nil` to use the
    ///     default shape (large radius / capsule-like) the way
    ///     `.glassEffect()` without `in:` does on macOS 26.
    ///   - tint: Optional tint color (used as `.regular.tint(...)` on
    ///     26, or an overlay on older macOS).
    ///   - interactive: Adds the `.interactive()` glass variant on 26.
    ///     Ignored on the fallback path — plain `.regularMaterial`
    ///     looks the same pressed-or-not on Ventura.
    @ViewBuilder
    func mactoyGlass(
        cornerRadius: CGFloat? = nil,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.modifier(MactoyGlassNative(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive
            ))
        } else {
            self.modifier(MactoyGlassFallback(
                cornerRadius: cornerRadius,
                tint: tint
            ))
        }
    }
}

@available(macOS 26.0, *)
private struct MactoyGlassNative: ViewModifier {
    let cornerRadius: CGFloat?
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch (cornerRadius, tint, interactive) {
        case let (r?, t?, true):
            content.glassEffect(.regular.tint(t).interactive(), in: .rect(cornerRadius: r))
        case let (r?, t?, false):
            content.glassEffect(.regular.tint(t), in: .rect(cornerRadius: r))
        case let (r?, nil, true):
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: r))
        case let (r?, nil, false):
            content.glassEffect(.regular, in: .rect(cornerRadius: r))
        case let (nil, t?, true):
            content.glassEffect(.regular.tint(t).interactive())
        case let (nil, t?, false):
            content.glassEffect(.regular.tint(t))
        case (nil, nil, true):
            content.glassEffect(.regular.interactive())
        case (nil, nil, false):
            content.glassEffect(.regular)
        }
    }
}

private struct MactoyGlassFallback: ViewModifier {
    let cornerRadius: CGFloat?
    let tint: Color?

    // When no explicit radius is requested we want the true "pill /
    // capsule" silhouette that `.glassEffect()` gives on 26. A huge
    // RoundedRectangle radius does NOT collapse to a capsule on wider
    // chips (SwiftUI clamps to min(w,h)/2 but `.continuous` produces
    // flatter sides than `Capsule()`), so branch on the shape instead.
    @ViewBuilder
    func body(content: Content) -> some View {
        if let cornerRadius {
            content.background {
                glassStack(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content.background {
                glassStack(Capsule(style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func glassStack<S: InsettableShape>(_ shape: S) -> some View {
        ZStack {
            shape.fill(.regularMaterial)
            if let tint {
                shape.fill(tint.opacity(0.22))
            }
            shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

/// Cross-version replacement for `GlassEffectContainer`. On macOS 26+
/// it unifies adjacent glass siblings the way the native container
/// does. On older macOS it's a transparent passthrough — each child's
/// `.mactoyGlass(...)` fallback renders its own material card, which
/// visually reads as a stack of panels instead of a merged glass sheet
/// but keeps the layout and hit-testing identical.
struct MactoyGlassContainer<Content: View>: View {
    let spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            if let spacing {
                GlassEffectContainer(spacing: spacing) { content() }
            } else {
                GlassEffectContainer { content() }
            }
        } else {
            content()
        }
    }
}
