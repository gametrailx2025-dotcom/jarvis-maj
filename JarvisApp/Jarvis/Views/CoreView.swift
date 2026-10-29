import SwiftUI

/// Noyau animé central : halo, ondes de choc, balayage radar, graduations, particules en orbite,
/// barres « audio » quand JARVIS parle ou écoute. Vire au vert à l'écoute, accélère quand il réfléchit.
struct CoreView: View {
    let mode: CoreMode
    var size: CGFloat = 300
    @State private var shockStart: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(mode: CoreMode, size: CGFloat = 300) {
        self.mode = mode
        self.size = size
    }

    /// Taille du noyau selon l'état : il grossit quand il parle.
    private var modeScale: CGFloat {
        switch mode {
        case .speaking: return 1.15
        case .listening: return 1.06
        case .thinking: return 1.04
        case .idle: return 1
        }
    }

    var body: some View {
        coreBody
            .scaleEffect(modeScale)
            .brightness(mode == .speaking ? 0.06 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.55), value: mode)
            .zIndex(2)
            .onChange(of: mode) { old, new in
                if new == .speaking && old != .speaking { shockStart = Date.timeIntervalSinceReferenceDate }
            }
            .accessibilityLabel("Noyau JARVIS")
    }

    private var coreBody: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed: Double = mode == .thinking ? 3.5 : 1
            let active = mode == .speaking || mode == .listening
            let color = mode == .listening ? Theme.green : Theme.cyan
            let pulse: Double = mode == .speaking ? 0.85 + 0.25 * abs(sin(t * 9)) : 0.95 + 0.05 * sin(t * 1.6)

            ZStack {
                // Effets supplémentaires (derrière) : poussière, étincelles, arcs, onde de choc, anneau d'énergie
                CoreEffects(t: t, mode: mode, color: color, size: size, shockStart: shockStart)

                // Halo
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(active ? 0.35 : 0.22), .clear],
                                         center: .center, startRadius: size * 0.08, endRadius: size * 0.6))
                    .scaleEffect(1 + 0.05 * sin(t * 2))

                // Ondes de choc qui s'élargissent
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * (active ? 0.9 : 0.3) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(color.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                        .scaleEffect(0.3 + 0.7 * phase)
                }

                // Graduations extérieures
                ForEach(0..<72, id: \.self) { i in
                    Rectangle()
                        .fill(color.opacity(i % 6 == 0 ? 0.85 : 0.3))
                        .frame(width: i % 6 == 0 ? 2 : 1, height: i % 6 == 0 ? size * 0.045 : size * 0.022)
                        .offset(y: -size * 0.47)
                        .rotationEffect(.degrees(Double(i) * 5 + t * 3))
                }

                // Arcs extérieurs
                ring(color, from: 0, to: 0.28, width: 3, inset: size * 0.05, angle: t * 26 * speed)
                ring(color.opacity(0.5), from: 0.5, to: 0.78, width: 3, inset: size * 0.05, angle: t * 26 * speed)

                // Balayage radar
                Circle()
                    .fill(AngularGradient(colors: [color.opacity(0), color.opacity(0), color.opacity(0.32)],
                                          center: .center))
                    .padding(size * 0.1)
                    .rotationEffect(.degrees(t * 80 * speed))

                Circle()
                    .stroke(color.opacity(0.3), style: StrokeStyle(lineWidth: 7, dash: [3, 12]))
                    .padding(size * 0.1)
                    .rotationEffect(.degrees(t * 9))

                // Barres audio autour de l'hologramme quand il parle ou écoute
                if active {
                    ForEach(0..<56, id: \.self) { i in
                        let amp = 0.5 + 0.5 * sin(t * 13 + Double(i) * 0.7) * sin(t * 4.3 + Double(i) * 0.31)
                        Capsule()
                            .fill(color.opacity(0.85))
                            .frame(width: 2.5, height: size * (0.015 + 0.06 * amp))
                            .offset(y: -size * 0.385)
                            .rotationEffect(.degrees(Double(i) * 360 / 56))
                    }
                }

                // JARVIS holographique 3D au centre des anneaux
                HoloCore(mode: mode, size: size * 0.68)

                // Reflet en croix (lens flare)
                Flare(color: color, size: size, intensity: mode == .speaking ? 0.35 + 0.25 * abs(sin(t * 14)) * pulse : 0.12 + 0.05 * sin(t * speed))
            }
            .frame(width: size, height: size)
        }
    }

    private func ring(_ color: Color, from: CGFloat, to: CGFloat, width: CGFloat, inset: CGFloat,
                      angle: Double) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .padding(inset)
            .rotationEffect(.degrees(angle))
            .shadow(color: color, radius: 5)
    }
}

/// Générateur pseudo-aléatoire déterministe (mêmes valeurs pour une même graine).
private struct Rng {
    var state: UInt64
    init(_ seed: Int) { state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1_013_904_223) | 1 }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
}

private func frac(_ x: Double) -> Double { x - floor(x) }

/// Couche d'effets dessinée dans un Canvas (léger pour le GPU).
private struct CoreEffects: View {
    let t: Double
    let mode: CoreMode
    let color: Color
    let size: CGFloat
    let shockStart: Double

    var body: some View {
        Canvas { ctx, sz in
            draw(&ctx, cx: Double(sz.width) / 2, cy: Double(sz.height) / 2)
        }
        .frame(width: size * 1.7, height: size * 1.7)
        .allowsHitTesting(false)
    }

    private var energy: Double {
        switch mode {
        case .speaking: return 1
        case .listening: return 0.65
        case .thinking: return 0.5
        case .idle: return 0.15
        }
    }

    private func point(_ cx: Double, _ cy: Double, angle: Double, radius: Double) -> CGPoint {
        CGPoint(x: cx + cos(angle) * radius, y: cy + sin(angle) * radius)
    }

    private func dot(_ ctx: inout GraphicsContext, at p: CGPoint, diameter d: Double, opacity: Double) {
        let rect = CGRect(x: Double(p.x) - d / 2, y: Double(p.y) - d / 2, width: d, height: d)
        ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
    }

    private func draw(_ ctx: inout GraphicsContext, cx: Double, cy: Double) {
        let unit: Double = Double(size) / 2
        let e: Double = energy
        let speaking = mode == .speaking
        ctx.blendMode = .plusLighter

        // Poussière en orbite
        for i in 0..<70 {
            var r = Rng(i)
            let radius: Double = unit * (0.6 + 0.85 * r.next())
            let drift: Double = 0.05 + 0.2 * r.next()
            let a: Double = r.next() * 6.283 + t * drift * (1 + e * 3)
            let wob: Double = speaking ? sin(t * 11 + a * 5) * 6 : 0
            let d: Double = 1 + 2 * r.next()
            let o: Double = 0.15 + 0.5 * e * r.next()
            dot(&ctx, at: point(cx, cy, angle: a, radius: radius + wob), diameter: d, opacity: o)
        }

        // Étincelles projetées vers l'extérieur
        if speaking || mode == .listening {
            let count = speaking ? 48 : 18
            let reach: Double = speaking ? 0.95 : 0.5
            for i in 0..<count {
                var r = Rng(i &+ 500)
                let speed: Double = 0.6 + r.next() * 0.9
                let offset: Double = r.next()
                let phase: Double = frac(t * speed + offset)
                let burst = Int(t * speed + offset)
                var rb = Rng(burst &* 97 &+ i)
                let a: Double = rb.next() * 6.283
                let dist: Double = unit * (0.45 + phase * reach)
                let d: Double = (1.5 + 2.5 * rb.next()) * (1 - phase) + 0.5
                dot(&ctx, at: point(cx, cy, angle: a, radius: dist), diameter: d, opacity: 1 - phase)
            }
        }

        // Arcs électriques
        if speaking || mode == .thinking {
            let slot = Int(t * 9)
            let arcs = speaking ? 3 : 1
            let life: Double = 1 - frac(t * 9)
            for k in 0..<arcs {
                var r = Rng(slot &* 31 &+ k)
                if mode == .thinking && r.next() > 0.35 { continue }
                let a: Double = r.next() * 6.283
                let len: Double = unit * (0.75 + 0.6 * r.next())
                let start: Double = unit * 0.3
                var path = Path()
                for j in 0...9 {
                    let dist: Double = start + (len - start) * Double(j) / 9
                    var jit: Double = 0
                    if j > 0 && j < 9 { jit = (r.next() - 0.5) * 0.25 }
                    let pt = point(cx, cy, angle: a + jit, radius: dist)
                    if j == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(color.opacity(0.9 * life)), lineWidth: 1.6)
                ctx.stroke(path, with: .color(Color.white.opacity(0.5 * life)), lineWidth: 0.6)
            }
        }

        // Anneau d'énergie qui ondule avec la voix
        if e > 0.2 {
            var ring = Path()
            for i in 0...120 {
                let a: Double = Double(i) / 120 * 6.283
                let w1: Double = sin(a * 8 + t * 8) * 6
                let w2: Double = sin(a * 13 - t * 14) * 5
                let pt = point(cx, cy, angle: a, radius: unit * 1.05 + (w1 + w2) * e)
                if i == 0 { ring.move(to: pt) } else { ring.addLine(to: pt) }
            }
            ctx.stroke(ring, with: .color(color.opacity(0.2 + 0.5 * e)), lineWidth: 2)
        }

        // Anneau d'hexagones qui tourne (s'illumine quand il parle)
        let hexCount = 24
        let hexR: Double = unit * 0.9
        for i in 0..<hexCount {
            let a: Double = Double(i) / Double(hexCount) * 6.283 - t * (0.15 + e * 0.5)
            let center = point(cx, cy, angle: a, radius: hexR)
            let lit: Double = 0.5 + 0.5 * sin(t * 6 - Double(i) * 0.8)
            let side: Double = unit * 0.035
            var hex = Path()
            for k in 0...6 {
                let ka: Double = Double(k) / 6 * 6.283 + a
                let v = CGPoint(x: Double(center.x) + cos(ka) * side, y: Double(center.y) + sin(ka) * side)
                if k == 0 { hex.move(to: v) } else { hex.addLine(to: v) }
            }
            ctx.stroke(hex, with: .color(color.opacity(0.15 + 0.6 * lit * e)), lineWidth: 1)
            if speaking && lit > 0.85 { ctx.fill(hex, with: .color(color.opacity(0.35))) }
        }

        // Comètes en orbite avec traînée
        for i in 0..<4 {
            let orbit: Double = unit * (0.62 + 0.09 * Double(i))
            let spd: Double = (0.8 + 0.35 * Double(i)) * (1 + e * 1.5) * (i % 2 == 0 ? 1 : -1)
            for tail in 0..<14 {
                let a: Double = t * spd - Double(tail) * 0.045 * (spd > 0 ? 1 : -1) + Double(i) * 1.7
                let fade: Double = 1 - Double(tail) / 14
                dot(&ctx, at: point(cx, cy, angle: a, radius: orbit), diameter: 1 + 3.2 * fade, opacity: 0.85 * fade)
            }
        }

        // Points radar qui clignotent
        for i in 0..<6 {
            var r = Rng(i &+ 900 &+ Int(t / 3) &* 13)
            let a: Double = r.next() * 6.283
            let rad: Double = unit * (0.3 + 0.5 * r.next())
            let blink: Double = frac(t / 3 + Double(i) / 6)
            let p = point(cx, cy, angle: a, radius: rad)
            dot(&ctx, at: p, diameter: 3, opacity: 1 - blink)
            let ring: Double = 3 + 16 * blink
            let rr = CGRect(x: Double(p.x) - ring / 2, y: Double(p.y) - ring / 2, width: ring, height: ring)
            ctx.stroke(Path(ellipseIn: rr), with: .color(color.opacity(0.6 * (1 - blink))), lineWidth: 1)
        }

        // Balayage holographique vertical
        let scanY: Double = cy - unit + frac(t * 0.35) * unit * 2
        let half: Double = sqrt(max(0, unit * unit - (scanY - cy) * (scanY - cy)))
        if half > 1 {
            var scan = Path()
            scan.move(to: CGPoint(x: cx - half, y: scanY))
            scan.addLine(to: CGPoint(x: cx + half, y: scanY))
            ctx.stroke(scan, with: .color(color.opacity(0.25 + 0.3 * e)), lineWidth: 1.2)
        }

        // Battements lumineux concentriques quand il parle
        if speaking {
            for i in 0..<3 {
                let k: Double = frac(t * 1.6 + Double(i) / 3)
                let rad: Double = unit * (0.2 + 0.55 * k)
                let rect = CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.5 * (1 - k))), lineWidth: 2 * (1 - k) + 0.5)
            }
        }

        // Onde de choc au début de chaque réponse
        let age: Double = Date.timeIntervalSinceReferenceDate - shockStart
        if age >= 0 && age < 0.9 {
            let k: Double = age / 0.9
            let ease: Double = 1 - pow(1 - k, 3)
            let rad: Double = unit * (0.35 + 1.25 * ease)
            let rect = CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.95 * (1 - k))), lineWidth: 1 + 8 * (1 - k))
        }
    }
}

/// Reflet lumineux en croix au centre.
private struct Flare: View {
    let color: Color
    let size: CGFloat
    let intensity: Double

    var body: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [.clear, color, .white, color, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: size * 1.3, height: 2.5)
            Capsule()
                .fill(LinearGradient(colors: [.clear, color, .white, color, .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 2, height: size * 0.6)
        }
        .opacity(intensity)
        .blur(radius: 0.8)
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

struct CoreStatusText: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .tracking(7)
                .foregroundStyle(model.coreMode == .listening ? Theme.green : Theme.cyan)
                .shadow(color: Theme.cyan, radius: 8)
            if model.speech.isCapturing || (model.speech.isRunning && !model.speech.wakeMode) {
                Text(model.speech.transcript.isEmpty ? "…" : "« \(model.speech.transcript) »")
                    .font(.system(size: 15).italic())
                    .foregroundStyle(Theme.cyanSoft)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var label: String {
        switch model.coreMode {
        case .listening: return "J'ÉCOUTE"
        case .speaking: return "TRANSMISSION"
        case .thinking: return "ANALYSE"
        case .idle:
            if model.speech.wakeMode && model.speech.isRunning { return "DITES « JARVIS »" }
            return model.isConnected ? "EN LIGNE · PC" : "EN LIGNE"
        }
    }
}
