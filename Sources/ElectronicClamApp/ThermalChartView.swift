import AppKit

/// 60-second mini chart for Safety pane. Renders CPU / GPU / battery °C as
/// thin colored polylines on a domain of [now-60s … now], scaled to a fixed
/// 30°C–100°C y-axis. If SMC is unavailable (`cpuC == nil`) we instead render
/// a 4-step horizontal severity bar from `publicLevel`.
///
/// One sample per ~5s; up to ~12 samples in flight. Points are smoothed with a
/// Catmull-Rom spline and positioned by age against the wall clock, so the
/// controller repaints at 1 Hz (`refreshDynamic`) to scroll the line
/// continuously rather than jumping when each 5s sample arrives.
final class ThermalChartView: NSView {
    var samples: [StateStore.ThermalSample] = [] { didSet { needsDisplay = true } }

    private let yMin: Double = 30   // °C — empty Mac idle is ~30°C
    private let yMax: Double = 100  // °C — alarm well before thermal throttle

    override var isFlipped: Bool { false }

    override func draw(_ dirty: NSRect) {
        let bg = NSColor.textBackgroundColor.withAlphaComponent(0.4)
        bg.setFill()
        bounds.fill()

        // Border
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        guard let last = samples.last else {
            drawEmpty("Waiting for samples…")
            return
        }

        // If we have any SMC temp readings, draw the line chart. Otherwise
        // fall back to the 4-step bar.
        let anyTemp = samples.contains { $0.cpuC != nil || $0.gpuC != nil || $0.batteryC != nil }
        if anyTemp {
            // Continuous left-scroll: place samples by age relative to the wall
            // clock (`Date()`), not the newest sample's timestamp. With the
            // Safety pane repainting at 1 Hz this glides the line ~7px/s instead
            // of jumping ~35px when a new 5s sample lands (user feedback
            // 2026-06-12: "차트가 뚝뚝 끊겨").
            drawLines(now: Date())
        } else {
            drawSeverityBar(level: last.publicLevel, pressure: last.pressureLevel)
        }
    }

    private func drawLines(now: Date) {
        // Y guides @ 50/70/90°C.
        let guideAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for c in [50.0, 70.0, 90.0] {
            let y = ny(c)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 30, y: y))
            path.line(to: NSPoint(x: bounds.maxX - 4, y: y))
            NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            ("\(Int(c))°" as NSString).draw(at: NSPoint(x: 2, y: y - 6), withAttributes: guideAttrs)
        }

        // Clip the series to the plot area so a sample that has scrolled past
        // the left axis doesn't paint over the °C gutter labels.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 30, y: 0, width: max(0, bounds.maxX - 4 - 30), height: bounds.height)).addClip()
        plot(samples: samples, picker: { $0.cpuC },
             color: NSColor.systemRed.withAlphaComponent(0.9), now: now)
        plot(samples: samples, picker: { $0.gpuC },
             color: NSColor.systemOrange.withAlphaComponent(0.9), now: now)
        plot(samples: samples, picker: { $0.batteryC },
             color: NSColor.systemBlue.withAlphaComponent(0.9), now: now)
        NSGraphicsContext.restoreGraphicsState()

        // Legend bottom-left — only series that actually have samples.
        // (e.g. Apple Silicon often has no battery °C; a chip with no line
        // just confuses people.)
        var legend: [(String, NSColor)] = []
        if samples.contains(where: { $0.cpuC != nil }) {
            legend.append(("CPU °C", NSColor.systemRed))
        }
        if samples.contains(where: { $0.gpuC != nil }) {
            legend.append(("GPU °C", NSColor.systemOrange))
        }
        if samples.contains(where: { $0.batteryC != nil }) {
            legend.append(("Batt °C", NSColor.systemBlue))
        }
        var lx: CGFloat = 30
        let ly: CGFloat = 4
        for (name, color) in legend {
            let chip = NSBezierPath(rect: NSRect(x: lx, y: ly + 3, width: 8, height: 2))
            color.setFill(); chip.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            (name as NSString).draw(at: NSPoint(x: lx + 12, y: ly), withAttributes: attrs)
            lx += 60
        }
    }

    /// Draws a single series as a smoothed curve. We resolve x by sample
    /// timestamp so gaps don't stretch unevenly, then run the points through a
    /// Catmull-Rom spline so the line reads as a continuous flow rather than a
    /// jagged dot-to-dot polyline.
    private func plot(samples: [StateStore.ThermalSample],
                      picker: (StateStore.ThermalSample) -> Double?,
                      color: NSColor, now: Date) {
        var pts: [NSPoint] = []
        for s in samples {
            guard let v = picker(s) else { continue }
            pts.append(NSPoint(x: nx(s.at, now: now), y: ny(v)))
        }
        guard let firstPt = pts.first else { return }
        let path: NSBezierPath
        if pts.count == 1 {
            path = NSBezierPath()
            path.move(to: firstPt)
        } else {
            path = Self.smoothPath(pts)
        }
        // Hold the most recent reading flat out to the right ("now") edge so the
        // line always reaches the edge as the samples scroll left.
        let rightEdge = bounds.maxX - 4
        if let lastPt = pts.last, lastPt.x < rightEdge {
            path.line(to: NSPoint(x: rightEdge, y: lastPt.y))
        }
        guard !path.isEmpty else { return }
        color.setStroke(); path.lineWidth = 1.5; path.stroke()
    }

    /// Catmull-Rom interpolation through `pts`, expressed as cubic bezier
    /// segments. Endpoints are duplicated so the curve passes through the first
    /// and last points without overshooting.
    private static func smoothPath(_ pts: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else {
            if pts.count == 2 { path.line(to: pts[1]) }
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let cp1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                              y: p1.y + (p2.y - p0.y) / 6.0)
            let cp2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                              y: p2.y - (p3.y - p1.y) / 6.0)
            path.curve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
        }
        return path
    }

    private func drawSeverityBar(level: Int, pressure: Int?) {
        // 4-step row of cells; the current level fills its cell, the rest are dim.
        let cells = 4
        let labels = ["nominal", "fair", "serious", "critical"]
        let colors: [NSColor] = [.systemGreen, .systemYellow, .systemOrange, .systemRed]
        let inset: CGFloat = 8
        let cellW = (bounds.width - inset * 2) / CGFloat(cells)
        let y: CGFloat = bounds.height / 2 - 8
        let h: CGFloat = 16
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for i in 0..<cells {
            let r = NSRect(x: inset + CGFloat(i) * cellW + 2, y: y, width: cellW - 4, height: h)
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            let c = colors[i].withAlphaComponent(i == level ? 0.85 : 0.18)
            c.setFill(); path.fill()
            (labels[i] as NSString).draw(at: NSPoint(x: r.midX - 22, y: r.maxY + 2), withAttributes: attrs)
        }
        if let p = pressure {
            ("5-step pressure: \(p)" as NSString).draw(
                at: NSPoint(x: inset, y: 2),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9),
                                 .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    private func drawEmpty(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                           y: (bounds.height - size.height) / 2),
               withAttributes: attrs)
    }

    private func nx(_ at: Date, now: Date) -> CGFloat {
        let leftPad: CGFloat = 30, rightPad: CGFloat = 4
        let plotW = bounds.width - leftPad - rightPad
        let dt = now.timeIntervalSince(at)  // 0 for newest, 60 for oldest
        return bounds.maxX - rightPad - CGFloat(dt / 60.0) * plotW
    }
    private func ny(_ c: Double) -> CGFloat {
        let t = max(0.0, min(1.0, (c - yMin) / (yMax - yMin)))
        let topPad: CGFloat = 16, bottomPad: CGFloat = 16
        let plotH = bounds.height - topPad - bottomPad
        return bottomPad + CGFloat(t) * plotH
    }
}
