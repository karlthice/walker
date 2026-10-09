import MapKit
import UIKit

/// A piece of the raw path drawn in one style.
final class PathPolyline: MKPolyline {
    /// Age step: 0 for the last 24 hours, up to `PathAge.steps` for a week or older; nil for
    /// the uniform style.
    var step: Int?
}

/// Styles the raw path by age: the last 24 hours darkest and widest, fading to thinner and
/// lighter (but still clearly visible) at a week old. One hue throughout, light to dark.
enum PathAge {
    static let steps = 12

    private static let recent = (red: 0.84, green: 0.30, blue: 0.00, alpha: 1.0)
    private static let weekOld = (red: 0.97, green: 0.60, blue: 0.24, alpha: 0.9)
    private static let recentWidth: CGFloat = 5
    private static let weekOldWidth: CGFloat = 2

    static func step(age: TimeInterval) -> Int {
        let days = age / 86_400
        guard days > 1 else { return 0 }
        return min(steps, Int(((days - 1) / 6 * Double(steps)).rounded(.up)))
    }

    static func width(step: Int?) -> CGFloat {
        guard let step else { return 2.5 }
        let t = CGFloat(step) / CGFloat(steps)
        return recentWidth + (weekOldWidth - recentWidth) * t
    }

    static func color(step: Int?) -> UIColor {
        guard let step else { return .systemOrange }
        let t = Double(step) / Double(steps)
        func mix(_ a: Double, _ b: Double) -> CGFloat { CGFloat(a + (b - a) * t) }
        return UIColor(red: mix(recent.red, weekOld.red), green: mix(recent.green, weekOld.green),
                       blue: mix(recent.blue, weekOld.blue), alpha: mix(recent.alpha, weekOld.alpha))
    }

    /// Splits the path where the fog isn't joined either (long gaps, implausible jumps), and,
    /// when styling by age, wherever the age step changes. Oldest first, so newer lines draw on top.
    static func polylines(for points: [LocationPoint], byAge: Bool, now: Date = .now) -> [PathPolyline] {
        var result: [PathPolyline] = []
        var run: [LocationPoint] = []
        var runStep: Int?

        func finish() {
            if run.count > 1 {
                let polyline = PathPolyline(coordinates: run.map(\.coordinate), count: run.count)
                polyline.step = runStep
                result.append(polyline)
            }
            run = []
        }

        for point in points {
            guard let previous = run.last else {
                run = [point]
                continue
            }
            guard Revealer.shouldConnect(previous, point) else {
                finish()
                run = [point]
                continue
            }
            // A segment takes the style of its newer end.
            let step = byAge ? self.step(age: now.timeIntervalSince(point.timestamp)) : nil
            if run.count > 1 && step != runStep {
                finish()
                run = [previous]
            }
            runStep = step
            run.append(point)
        }
        finish()
        return result.sorted { ($0.step ?? 0) > ($1.step ?? 0) }
    }
}
