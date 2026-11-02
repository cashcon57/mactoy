import SwiftUI

/// Ko-fi's mug-with-a-heart mark, drawn as vector shapes in a glassy style:
/// a white mug with a soft highlight and a glossy orange heart. Drawn rather
/// than bundled so it stays sharp at any size and in both appearances.
struct KofiMug: View {
    /// Ko-fi's heart orange.
    static let orange = Color(red: 1.0, green: 0.443, blue: 0.098)

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let outline = h * 0.075
            let handleWidth = h * 0.085
            ZStack {
                // Dark outline behind everything, like the original mark.
                MugHandle().stroke(Color.black.opacity(0.85), lineWidth: handleWidth + outline * 2)
                MugBody().stroke(Color.black.opacity(0.85), lineWidth: outline * 2)

                // The mug: white glass, brighter at the top.
                MugHandle().stroke(Color.white, lineWidth: handleWidth)
                MugBody().fill(
                    LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .top, endPoint: .bottom)
                )
                // Soft reflection along the upper left.
                MugBody()
                    .fill(
                        LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0)],
                                       startPoint: .topLeading, endPoint: .center)
                    )
                    .blendMode(.screen)

                // The heart, glossy.
                MugHeart()
                    .fill(
                        LinearGradient(colors: [Self.orange.opacity(0.85), Self.orange],
                                       startPoint: .top, endPoint: .bottom)
                    )
                MugHeart()
                    .fill(
                        RadialGradient(colors: [.white.opacity(0.7), .white.opacity(0)],
                                       center: UnitPoint(x: 0.36, y: 0.38),
                                       startRadius: 0, endRadius: h * 0.16)
                    )
            }
        }
        .aspectRatio(1.3, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Mug body: flat top with small corners, big rounded bottom.
private struct MugBody: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let left = r.minX + 0.06 * w, right = r.minX + 0.74 * w
        let top = r.minY + 0.10 * h, bottom = r.minY + 0.92 * h
        let topRadius = 0.08 * w, bottomRadius = 0.26 * w
        var p = Path()
        p.move(to: CGPoint(x: left + topRadius, y: top))
        p.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: bottom), radius: topRadius)
        p.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: left, y: bottom), radius: bottomRadius)
        p.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: top), radius: bottomRadius)
        p.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: right, y: top), radius: topRadius)
        p.closeSubpath()
        return p
    }
}

/// Mug handle: a rounded loop on the right side, stroked.
private struct MugHandle: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let rect = CGRect(x: r.minX + 0.60 * w, y: r.minY + 0.26 * h, width: 0.33 * w, height: 0.38 * h)
        return Path(roundedRect: rect, cornerRadius: rect.height * 0.5, style: .continuous)
    }
}

/// The heart, centered on the mug body.
private struct MugHeart: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let size = 0.42 * h
        let cx = r.minX + 0.40 * w, cy = r.minY + 0.50 * h
        let box = CGRect(x: cx - size * 0.55, y: cy - size * 0.48, width: size * 1.1, height: size)
        var p = Path()
        let bottom = CGPoint(x: box.midX, y: box.maxY)
        p.move(to: bottom)
        p.addCurve(to: CGPoint(x: box.minX, y: box.minY + box.height * 0.32),
                   control1: CGPoint(x: box.midX - box.width * 0.20, y: box.maxY - box.height * 0.18),
                   control2: CGPoint(x: box.minX, y: box.minY + box.height * 0.62))
        p.addArc(center: CGPoint(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.30),
                 radius: box.width * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: box.minX + box.width * 0.75, y: box.minY + box.height * 0.30),
                 radius: box.width * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: bottom,
                   control1: CGPoint(x: box.maxX, y: box.minY + box.height * 0.62),
                   control2: CGPoint(x: box.midX + box.width * 0.20, y: box.maxY - box.height * 0.18))
        p.closeSubpath()
        return p
    }
}
