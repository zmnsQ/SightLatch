import SwiftUI

enum PilotSettingsArtworkKind {
    case device, intelligence, privacy, calibration, data, models, gateway
}

/// Page artwork explains the category; real connection and permission state stays in the controls.
struct PilotSettingsHero: View {
    let kind: PilotSettingsArtworkKind
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            artwork.frame(height: 164).frame(maxWidth: .infinity)
                .accessibilityHidden(true).allowsHitTesting(false)
            Text(title).font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
            .padding(.top, 8).padding(.bottom, 20)
    }

    @ViewBuilder private var artwork: some View {
        switch kind {
        case .device: PilotConnectionIllustration()
        case .intelligence: PilotPresenceMark(size: 164)
        case .privacy, .calibration:
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(PilotPalette.accent.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(PilotPalette.accent.opacity(0.24), lineWidth: 1))
                    .frame(width: 87, height: 148).rotationEffect(.degrees(10)).offset(x: 28)
                ForEach(0..<3) { ring in
                    Circle().stroke(PilotPalette.accent.opacity(0.30 - Double(ring) * 0.07), lineWidth: 1)
                        .frame(width: CGFloat(52 + ring * 32), height: CGFloat(52 + ring * 32))
                }
                Image(systemName: kind == .privacy ? "hand.raised.fill" : "scope")
                    .font(.system(size: 35, weight: .light)).foregroundStyle(PilotPalette.accent.gradient)
            }
        case .data, .models, .gateway:
            ZStack {
                Ellipse().stroke(PilotPalette.accent.opacity(0.14), lineWidth: 1)
                    .frame(width: 206, height: 76).rotationEffect(.degrees(-16))
                ForEach(0..<3) { layer in
                    RoundedRectangle(cornerRadius: 18)
                        .fill(PilotPalette.canvas)
                        .overlay(RoundedRectangle(cornerRadius: 18)
                            .fill(PilotPalette.accent.opacity(0.05 + Double(layer) * 0.025)))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(PilotPalette.accent.opacity(0.16), lineWidth: 1))
                        .frame(width: 100, height: 110)
                        .rotationEffect(.degrees(Double(layer - 1) * 12))
                        .offset(x: CGFloat(layer - 1) * 22, y: CGFloat(2 - layer) * 7)
                }
                Image(systemName: kind == .data ? "archivebox" : kind == .models ? "square.stack.3d.up" : "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 37, weight: .light)).foregroundStyle(PilotPalette.accent)
                    .offset(x: 22)
            }
        }
    }
}

struct PilotSettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(PilotPalette.group, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct PilotSettingsRowLabel: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21, weight: .regular))
                .foregroundStyle(PilotPalette.accent).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body).foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(minHeight: 44, alignment: .leading)
    }
}

/// A decorative waveform animates only during an actual voice preview.
struct PilotVoiceWaveform: View {
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let heights: [CGFloat] = [3, 5, 9, 18, 28, 42, 31, 24, 43, 65, 48, 29, 22, 38, 75, 96, 69, 45, 30, 40, 53, 36, 25, 31, 42, 33, 22, 13, 8, 5, 3]
    var body: some View {
        Group {
            if active && !reduceMotion && scenePhase == .active {
                PhaseAnimator([false, true]) { phase in wave(phase: phase) }
                    animation: { _ in .easeInOut(duration: 0.48) }
            } else { wave(phase: false) }
        }.frame(maxWidth: .infinity).frame(height: 164)
            .accessibilityHidden(true).allowsHitTesting(false)
    }
    private func wave(phase: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule().fill(PilotPalette.accent.opacity(index % 3 == 0 ? 0.42 : 0.9).gradient)
                    .frame(width: 3, height: heights[index] * (phase ? (index % 2 == 0 ? 0.58 : 1.1) : 1))
            }
        }.frame(maxWidth: .infinity)
    }
}

/// A decorative brand presence, not a progress meter or a connection indicator.
struct PilotPresenceMark: View {
    var size: CGFloat = 112
    var active: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var animates: Bool { active && !reduceMotion && scenePhase == .active }

    var body: some View {
        Group {
            if animates {
                PhaseAnimator([false, true]) { expanded in
                    mark(breath: expanded ? 1 : 0)
                } animation: { _ in
                    .easeInOut(duration: 3.2)
                }
            } else {
                mark(breath: 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func mark(breath: Double) -> some View {
        let accent = PilotPalette.accent
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.10 + breath * 0.025), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.49))
            Circle()
                .strokeBorder(accent.opacity(0.13), lineWidth: 0.75)
                .frame(width: size * 0.89, height: size * 0.89)
            Ellipse()
                .strokeBorder(accent.opacity(0.09), lineWidth: 0.65)
                .frame(width: size * 0.97, height: size * 0.63)
                .rotationEffect(.degrees(-27))
            Circle()
                .trim(from: 0.02, to: 0.24)
                .stroke(AngularGradient(colors: [accent.opacity(0.05), accent.opacity(0.8), accent.opacity(0.22)],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(95)),
                        style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                .frame(width: size * 0.89, height: size * 0.89)
                .rotationEffect(.degrees(-83 + breath * 14))
                .opacity(0.7 + breath * 0.3)
            Circle()
                .trim(from: 0.56, to: 0.68)
                .stroke(accent.opacity(0.30), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                .frame(width: size * 0.89, height: size * 0.89)
                .rotationEffect(.degrees(-breath * 9))
            orbitNode(angle: -44 + breath * 9, radius: size * 0.445, diameter: max(2, size * 0.025), opacity: 0.8)
            orbitNode(angle: 131, radius: size * 0.445, diameter: max(1.8, size * 0.018), opacity: 0.4)
            orbitNode(angle: 222, radius: size * 0.445, diameter: max(1.5, size * 0.014), opacity: 0.25)
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.61, height: size * 0.61)
                .scaleEffect(1 + breath * 0.018)
        }
    }

    private func orbitNode(angle: Double, radius: CGFloat, diameter: CGFloat, opacity: Double) -> some View {
        let radians = angle * .pi / 180
        return Circle()
            .fill(PilotPalette.accent.opacity(opacity))
            .frame(width: diameter, height: diameter)
            .offset(x: cos(radians) * radius, y: sin(radians) * radius)
    }
}

/// Show only for a real in-flight phase. `active` can freeze it without changing layout.
struct PilotThinkingIndicator: View {
    let title: String
    var active: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var animates: Bool { active && !reduceMotion && scenePhase == .active }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if animates {
                    PhaseAnimator([0, 1, 2, 3]) { phase in
                        dots(highlighted: phase - 1)
                    } animation: { _ in
                        .easeInOut(duration: 0.42)
                    }
                } else {
                    dots(highlighted: -1)
                }
            }
            .frame(width: 27, height: 16)
            .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] - 3 }
            .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func dots(highlighted: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(PilotPalette.accent.opacity(index == highlighted ? 0.95 : 0.32))
                    .frame(width: 5, height: 5)
                    .scaleEffect(index == highlighted ? 1.08 : 0.92)
                    .offset(y: index == highlighted ? -1.5 : 0)
            }
        }
    }
}

/// The neighboring status text carries semantics; this small glyph stays decorative.
struct PilotStatusGlyph: View {
    let symbol: String
    var tint: Color = PilotPalette.accent
    var active: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var animates: Bool { active && !reduceMotion && scenePhase == .active }

    var body: some View {
        Group {
            if animates {
                PhaseAnimator([false, true]) { expanded in
                    glyph(breath: expanded ? 1 : 0)
                } animation: { _ in
                    .easeInOut(duration: 2.4)
                }
            } else {
                glyph(breath: 0)
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func glyph(breath: Double) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(colorScheme == .dark ? 0.13 : 0.075))
                .overlay(Circle().strokeBorder(tint.opacity(0.12), lineWidth: 0.75))
            Circle()
                .trim(from: 0.02, to: 0.18)
                .stroke(tint.opacity(0.25 + breath * 0.18), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .rotationEffect(.degrees(-85 + breath * 12))
                .padding(1)
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .foregroundStyle(tint)
                .scaleEffect(1 + breath * 0.025)
        }
    }
}
