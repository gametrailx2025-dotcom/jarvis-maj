import SwiftUI

/// JARVIS holographique en 3D (inspiré du hologramme d'Iron Man) : sphère en fil de fer qui tourne,
/// parallèles et méridiens brisés, segments de données, sphère intérieure, particules et rayons.
/// Accélère quand il réfléchit, pulse et projette des rayons quand il parle.
struct HoloCore: View {
    let mode: CoreMode
    var size: CGFloat = 240

    init(mode: CoreMode, size: CGFloat = 240) {
        self.mode = mode
        self.size = size
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
            let color = mode == .listening ? Theme.green : Theme.cyan
            Canvas { ctx, sz in
                HoloRenderer.draw(&ctx, size: sz, t: t, mode: mode, color: color)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityLabel("JARVIS")
    }
}

private struct Vec3 {
    var x: Double
    var y: Double
    var z: Double
}

private struct HoloLine {
    let pts: [Vec3]
    let glow: Double
    let width: Double
    let flick: Double
}

private struct HoloRay {
    let lat: Double
    let lon: Double
    let length: Double
    let phase: Double
}

private struct HoloDot {
    let p: Vec3
    let bright: Double
}

/// Géométrie calculée une seule fois (graine fixe : même dessin à chaque lancement).
private final class HoloGeometry {
    static let shared = HoloGeometry()

    private(set) var lines: [HoloLine] = []
    private(set) var inner: [[Vec3]] = []
    private(set) var dots: [HoloDot] = []
    private(set) var rays: [HoloRay] = []
    private var seed: UInt64 = 7

    static func sph(_ lat: Double, _ lon: Double, _ r: Double = 1) -> Vec3 {
        Vec3(x: r * cos(lat) * cos(lon), y: r * sin(lat), z: r * cos(lat) * sin(lon))
    }

    private func rnd() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }

    private func arc(_ steps: Int, _ a0: Double, _ a1: Double, glow: Double, width: Double, _ f: (Double) -> Vec3) {
        var pts: [Vec3] = []
        for i in 0...steps {
            pts.append(f(a0 + (a1 - a0) * Double(i) / Double(steps)))
        }
        lines.append(HoloLine(pts: pts, glow: glow, width: width, flick: rnd() * 6.28))
    }

    private init() {
        // Parallèles (avec trous)
        for k in -3...3 {
            let lat = Double(k) * 0.38
            let start = rnd() * 6.28
            let span = 3.5 + rnd() * 2.5
            let glow = 0.5 + rnd() * 0.5
            arc(48, start, start + span, glow: glow, width: 1.2) { HoloGeometry.sph(lat, $0) }
        }
        // Méridiens partiels
        for m in 0..<14 {
            let lon = Double(m) * Double.pi / 7 + rnd() * 0.1
            let a = -1.2 + rnd() * 0.6
            let span = 1.4 + rnd() * 1.2
            let glow = 0.35 + rnd() * 0.5
            arc(40, a, a + span, glow: glow, width: 1) { HoloGeometry.sph($0, lon) }
        }
        // Segments de « données » à la surface
        for _ in 0..<380 {
            let lat = (rnd() - 0.5) * 3.0
            let lon = rnd() * 6.28
            let len = 0.05 + rnd() * 0.35
            let r = 1 + (rnd() - 0.5) * 0.08
            let glow = rnd()
            let width = rnd() < 0.15 ? 2.2 : 1.0
            if rnd() < 0.5 {
                arc(6, lon, lon + len, glow: glow, width: width) { HoloGeometry.sph(lat, $0, r) }
            } else {
                arc(6, lat, lat + len * 0.7, glow: glow, width: width) { HoloGeometry.sph($0, lon, r) }
            }
        }
        // Sphère intérieure : anneaux inclinés
        for _ in 0..<7 {
            let tilt = rnd() * 3.14
            var pts: [Vec3] = []
            for i in 0...50 {
                let a = Double(i) / 50 * 6.283
                let x = cos(a) * 0.55
                let y = sin(a) * 0.55
                pts.append(Vec3(x: x, y: y * cos(tilt), z: y * sin(tilt)))
            }
            inner.append(pts)
        }
        // Particules
        for _ in 0..<380 {
            let lat = (rnd() - 0.5) * 3.1
            let lon = rnd() * 6.28
            let r = 0.92 + rnd() * 0.3
            dots.append(HoloDot(p: HoloGeometry.sph(lat, lon, r), bright: rnd()))
        }
        // Rayons
        for _ in 0..<46 {
            let lat = (rnd() - 0.5) * 2.6
            let lon = rnd() * 6.28
            let length = 0.1 + rnd() * 0.35
            rays.append(HoloRay(lat: lat, lon: lon, length: length, phase: rnd() * 6.28))
        }
    }
}

private struct HoloProjector {
    let w: Double
    let h: Double
    let radius: Double
    let cy: Double
    let sy: Double
    let ct: Double
    let st: Double

    func project(_ p: Vec3, spin: Double = 0) -> (CGPoint, Double) {
        var x = p.x
        var z = p.z
        if spin != 0 {
            let c = cos(spin)
            let s = sin(spin)
            let nx = x * c - z * s
            z = x * s + z * c
            x = nx
        }
        let rx = x * cy - z * sy
        let rz = x * sy + z * cy
        let ry = p.y * ct - rz * st
        let fz = p.y * st + rz * ct
        let k = 3 / (3 + fz)
        return (CGPoint(x: w / 2 + rx * radius * k, y: h / 2 + ry * radius * k), fz)
    }
}

private enum HoloRenderer {
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, mode: CoreMode, color: Color) {
        let geo = HoloGeometry.shared
        let w = Double(size.width)
        let h = Double(size.height)
        let energy: Double
        switch mode {
        case .speaking: energy = 1
        case .listening: energy = 0.65
        case .thinking: energy = 0.5
        case .idle: energy = 0.15
        }
        let speedBoost: Double = mode == .thinking ? 2.5 : 1
        let rotY = t * (0.25 + energy * 0.9) * speedBoost
        let rotIn = -t * (0.6 + energy * 1.4)
        let tilt = 0.35 + sin(t * 0.3) * 0.08
        var pulse = 1 + 0.012 * sin(t * 1.5)
        if mode == .speaking { pulse = 1 + 0.05 * sin(t * 18) + 0.03 * sin(t * 7.3) }
        let radius = min(w, h) * 0.40 * pulse
        let pr = HoloProjector(w: w, h: h, radius: radius, cy: cos(rotY), sy: sin(rotY), ct: cos(tilt), st: sin(tilt))

        ctx.blendMode = .plusLighter

        // Lignes de la sphère : l'arrière est plus sombre. Regroupées par épaisseur et intensité.
        var buckets: [Int: Path] = [:]
        for line in geo.lines {
            let flick: Double = mode == .speaking ? 0.6 + 0.4 * sin(t * 22 + line.flick)
                                                  : 0.85 + 0.15 * sin(t * 2 + line.flick)
            let widthCode = line.width > 2 ? 2 : (line.width > 1.1 ? 1 : 0)
            var prev: (CGPoint, Double)? = nil
            for p in line.pts {
                let q = pr.project(p)
                if let a = prev {
                    let depth = 0.5 - (q.1 + a.1) / 4
                    let alpha = max(0.05, (0.16 + 0.84 * depth) * (0.4 + 0.6 * line.glow) * flick * (0.7 + energy * 0.5))
                    let level = min(9, Int(alpha * 10))
                    let key = widthCode * 16 + level
                    var path = buckets[key] ?? Path()
                    path.move(to: a.0)
                    path.addLine(to: q.0)
                    buckets[key] = path
                }
                prev = q
            }
        }
        for (key, path) in buckets {
            let widthCode = key / 16
            let level = key % 16
            let lw: CGFloat = widthCode == 2 ? 2.2 : (widthCode == 1 ? 1.2 : 1.0)
            ctx.stroke(path, with: .color(color.opacity((Double(level) + 0.5) / 10)), lineWidth: lw)
        }

        // Sphère intérieure (tourne en sens inverse)
        var innerPath = Path()
        for ring in geo.inner {
            for (i, p) in ring.enumerated() {
                let q = pr.project(p, spin: rotIn * 2).0
                if i == 0 { innerPath.move(to: q) } else { innerPath.addLine(to: q) }
            }
        }
        ctx.stroke(innerPath, with: .color(color.opacity(0.25 + 0.4 * energy)), lineWidth: 1.4)

        // Particules (regroupées par intensité)
        var dotBuckets: [Int: Path] = [:]
        for d in geo.dots {
            let q = pr.project(d.p, spin: rotIn * 0.3)
            let depth = 0.5 - q.1 / 2
            let s = 0.8 + 1.6 * d.bright * depth
            let rect = CGRect(x: Double(q.0.x) - s / 2, y: Double(q.0.y) - s / 2, width: s, height: s)
            let level = min(9, max(0, Int((0.15 + 0.7 * depth) * (0.4 + 0.6 * d.bright) * 10)))
            var path = dotBuckets[level] ?? Path()
            path.addRect(rect)
            dotBuckets[level] = path
        }
        for (level, path) in dotBuckets {
            ctx.fill(path, with: .color(color.opacity((Double(level) + 0.5) / 10)))
        }

        // Rayons qui jaillissent quand il parle / écoute
        if energy > 0.3 {
            var rayPath = Path()
            for ray in geo.rays {
                let grow = (0.5 + 0.5 * sin(t * 6 + ray.phase)) * energy
                let a = pr.project(HoloGeometry.sph(ray.lat, ray.lon, 1.02))
                let b = pr.project(HoloGeometry.sph(ray.lat, ray.lon, 1.02 + ray.length * grow))
                if a.1 < 0.3 {
                    rayPath.move(to: a.0)
                    rayPath.addLine(to: b.0)
                }
            }
            ctx.stroke(rayPath, with: .color(color.opacity(0.55 * energy)), lineWidth: 1.2)
        }

        // Cœur lumineux
        let coreR = radius * 0.45
        let rect = CGRect(x: w / 2 - coreR, y: h / 2 - coreR, width: coreR * 2, height: coreR * 2)
        ctx.opacity = 0.35 + 0.45 * energy
        ctx.fill(Path(ellipseIn: rect),
                 with: .radialGradient(Gradient(colors: [Color.white.opacity(0.55), color, color.opacity(0)]),
                                       center: CGPoint(x: w / 2, y: h / 2), startRadius: 0, endRadius: coreR))
        ctx.opacity = 1
    }
}
