import Lottie
import SwiftUI

/// Disk usage as water in a glass orb: the fuller the disk, the higher the water.
struct DiskTank: View {
    /// The disk's used fraction, for accessibility; nil until the disk size is read.
    let fraction: Double?
    /// Where the water is drawn (0 empty, 1 full): the used fraction, or less while a scan fills it.
    let level: Double
    let palette: ThemePalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var water = Water()
    /// Off a few seconds after the water stops: the waves finish their cycle and rest, so an idle summary draws nothing.
    @State private var isWaving = true

    var body: some View {
        // "water filling Glass orb" by Aneesh Ravi, LottieFiles, Lottie Simple License (https://lottiefiles.com/page/license),
        // split in two files: the waves, and the glass drawn over them.
        ZStack {
            LottieView(animation: .named("DiskTank"))
                // The Core Animation engine ignores closure value providers, and the water's height is one.
                .configuration(LottieConfiguration(renderingEngine: .mainThread))
                // Drawn on the CPU every frame, so no more often than the asset's own 30 fps.
                .configure(\.respectAnimationFrameRate, to: true)
                // Frames 0…116 loop the waves seamlessly; the code, not the timeline, sets how high they are.
                // Resting ends on frame 116, the loop's seam, so waving again from frame 0 doesn't jump.
                .playbackMode(reduceMotion ? .paused(at: .frame(0))
                              : .playing(isWaving ? .fromFrame(0, toFrame: 116, loopMode: .loop) : .fromFrame(nil, toFrame: 116, loopMode: .playOnce)))
                // A paused animation never asks the closures again, so under Reduce Motion a new level arrives as a new provider.
                .valueProvider(reduceMotion ? PointValueProvider(TankMotion.frontWave.position(forLevel: level)) : water.front,
                               for: "Shape Layer 2.Transform.Position")
                .valueProvider(reduceMotion ? PointValueProvider(TankMotion.backWave.position(forLevel: level)) : water.back,
                               for: "Shape Layer 6.Transform.Position")
                .valueProvider(GradientValueProvider(palette.water.map { $0.lottie() }), for: "Shape Layer 2.Rectangle 1.Gradient Fill 1.Colors")
                .valueProvider(GradientValueProvider(palette.backWater.map { $0.lottie() }), for: "Shape Layer 6.Rectangle 1.Gradient Fill 1.Colors")
            // Static, and on the default engine: the main-thread one drops gradients with transparency, which is all the glass is.
            LottieView(animation: .named("DiskTankGlass"))
                // The asset's rim is near-black; the palette's is light, as if part of the window.
                .valueProvider(GradientValueProvider(palette.glass.map { $0.lottie() }, locations: ThemePalette.glassStops),
                               for: "Shape Layer 1.Ellipse 1.Gradient Fill 1.Colors")
        }
        // The canvas is 307×283 around a 250-point orb: drawn this large, the orb itself fills the ring's size,
        // and only the canvas's empty margins spill past it.
        .frame(width: Layout.ringSize * 307 / 250, height: Layout.ringSize * 283 / 250)
        .frame(width: Layout.ringSize, height: Layout.ringSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("디스크 사용률")
        .accessibilityValue(fraction.map { $0.formatted(.percent.precision(.fractionLength(0)).locale(.shown)) } ?? "")
        // A new view starts its water at the bottom.
        .onAppear { water.move = water.move.retargeted(to: level, at: .now) }
        .onChange(of: level) { _, new in water.move = water.move.retargeted(to: new, at: .now) }
        .task(id: level) {
            isWaving = true
            // The longest move, then a moment to settle.
            try? await Task.sleep(for: .seconds(TankMotion.fullRangeDuration + 2))
            if !Task.isCancelled { isWaving = false }
        }
    }
}

/// The water's current move, read by Lottie on every frame: the drawn water is wherever the move has it at that moment.
private final class Water {
    var move = TankMotion.Move(from: 0, to: 0, start: .distantPast, duration: 0)
    lazy var front = provider(for: TankMotion.frontWave)
    lazy var back = provider(for: TankMotion.backWave)

    private func provider(for wave: TankMotion.Wave) -> PointValueProvider {
        // Weak: the animation view can draw a last frame after this view's state is gone.
        PointValueProvider { [weak self] _ in wave.position(forLevel: self?.move.level(at: .now) ?? 0) }
    }
}

/// How `DiskTank` places and moves its water.
nonisolated enum TankMotion {
    /// Even a 1%p change takes this long, so the water is seen to move.
    static let minimumDuration: TimeInterval = 1
    /// Filling the orb from empty to full takes this long; a longer move takes its share of it.
    static let fullRangeDuration: TimeInterval = 2

    /// The water moving from one level to another, easing to a stop.
    struct Move: Equatable {
        var from: Double
        var to: Double
        var start: Date
        var duration: TimeInterval
        /// Level per second at `start`, carried over from the move this one replaced: scans landing a moment apart
        /// would otherwise stop the water dead each time, and it would fall far behind.
        var velocity: Double = 0

        /// Where the water is at `time`.
        func level(at time: Date) -> Double {
            let t = progress(at: time)
            guard t < 1 else { return to }
            // Cubic Hermite: leaves `from` at `velocity` and arrives at `to` at rest.
            return from + (to - from) * t * t * (3 - 2 * t) + velocity * duration * t * (1 - t) * (1 - t)
        }

        func velocity(at time: Date) -> Double {
            let t = progress(at: time)
            guard t < 1 else { return 0 }
            return 6 * (to - from) * t * (1 - t) / duration + velocity * (1 - t) * (1 - 3 * t)
        }

        /// A move to `level` from wherever the water is at `time`, at the speed it has there, so it never jumps or stops dead.
        func retargeted(to level: Double, at time: Date) -> Move {
            let here = self.level(at: time)
            let change = level - here
            let duration = max(TankMotion.minimumDuration, abs(change) * TankMotion.fullRangeDuration)
            // Only speed toward the new level carries over, and at most 3× the average: any faster and the water overshoots.
            let carried = change == 0 ? 0 : min(max(velocity(at: time) * duration / change, 0), 3)
            return Move(from: here, to: level, start: time, duration: duration, velocity: carried * change / duration)
        }

        private func progress(at time: Date) -> Double { duration > 0 ? min(max(time.timeIntervalSince(start) / duration, 0), 1) : 1 }
    }

    /// A wave layer's designed path: at `empty` on frame 0, at `full` on frame 122.
    struct Wave {
        let empty: CGPoint
        let full: CGPoint

        /// On its own path, so the two waves keep the designer's offset at every level.
        func position(forLevel level: Double) -> CGPoint {
            let t = TankMotion.pathFraction(forLevel: level)
            return CGPoint(x: empty.x + (full.x - empty.x) * t, y: empty.y + (full.y - empty.y) * t)
        }
    }

    static let frontWave = Wave(empty: CGPoint(x: 392, y: 351), full: CGPoint(x: -118, y: 71))
    static let backWave = Wave(empty: CGPoint(x: 222, y: 351), full: CGPoint(x: -128, y: 71))

    /// How far along its path a wave sits at `level` (0 empty, 1 full) of the orb. From the asset: the orb spans y 16…266,
    /// and a wave's mean surface sits 63 above its layer position, its rounded crests 16 higher still.
    /// Empty keeps the crests just below the orb; full puts the mean surface at its top.
    static func pathFraction(forLevel level: Double) -> Double {
        let empty = 266 + 63 + 16.0, full = 16 + 63.0
        let y = empty - (empty - full) * min(max(level, 0), 1)
        return (351 - y) / (351 - 71)
    }
}

private extension Color {
    /// Lottie takes its own color type. The palette's colors are fixed RGB, so a default environment resolves them.
    func lottie() -> LottieColor {
        let resolved = resolve(in: EnvironmentValues())
        return LottieColor(r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue), a: Double(resolved.opacity))
    }
}
