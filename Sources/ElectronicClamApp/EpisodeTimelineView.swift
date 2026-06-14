import AppKit

/// History pane — a compact Gantt-style timeline of awake episodes over a
/// rolling window (default 24h). Awake streaks never overlap (only one keep-
/// awake hold at a time), so episodes live on a single horizontal track: bars
/// are awake intervals, gaps are asleep. Bar color encodes the start cause.
///
/// Data is whatever `AwakeHistoryStore.displayRows()` hands us — no extra
/// sampling or storage. Episodes that fall entirely before the window are
/// skipped; ones straddling the left edge are clipped.
final class EpisodeTimelineView: NSView {
    var episodes: [AwakeEpisode] = [] { didSet { needsDisplay = true } }
    var windowHours: Double = 24 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private let hourFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH"; return f
    }()

    override func draw(_ dirty: NSRect) {
        NSColor.textBackgroundColor.withAlphaComponent(0.4).setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let now = Date()
        let windowSec = windowHours * 3600
        let start = now.addingTimeInterval(-windowSec)
        let leftPad: CGFloat = 6, rightPad: CGFloat = 6
        let topPad: CGFloat = 6, axisH: CGFloat = 14
        let plotW = bounds.width - leftPad - rightPad
        let trackTop = topPad
        let trackH = bounds.height - topPad - axisH - 4
        guard plotW > 0, trackH > 0 else { return }

        func x(for date: Date) -> CGFloat {
            let frac = CGFloat(date.timeIntervalSince(start) / windowSec)
            return leftPad + min(1, max(0, frac)) * plotW
        }

        // Hour gridlines + labels. Tick density scales with the window.
        let tickStep: Int = windowHours <= 6 ? 1 : (windowHours <= 12 ? 2 : (windowHours <= 30 ? 3 : 6))
        let cal = Calendar.current
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        var tick = cal.nextDate(after: start,
                                matching: DateComponents(minute: 0, second: 0),
                                matchingPolicy: .nextTime) ?? start
        while tick < now {
            if cal.component(.hour, from: tick) % tickStep == 0 {
                let gx = x(for: tick)
                let line = NSBezierPath()
                line.move(to: NSPoint(x: gx, y: trackTop))
                line.line(to: NSPoint(x: gx, y: trackTop + trackH))
                line.lineWidth = 0.5
                line.stroke()
                (hourFmt.string(from: tick) as NSString)
                    .draw(at: NSPoint(x: gx + 2, y: trackTop + trackH + 2), withAttributes: labelAttrs)
            }
            tick = tick.addingTimeInterval(3600)
        }

        // Episode bars.
        for ep in episodes {
            let s = Swift.max(ep.startedAt, start)
            let e = ep.endedAt ?? now
            guard e > start else { continue }      // entirely before the window
            let x0 = x(for: s)
            let x1 = x(for: e)
            let w = Swift.max(2, x1 - x0)           // floor at 2px so brief blips show
            let rect = NSRect(x: x0, y: trackTop, width: w, height: trackH)
            color(for: ep.startCause).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func color(for cause: AwakeStartCause) -> NSColor {
        switch cause {
        case .manual:  return NSColor.systemBlue.withAlphaComponent(0.85)
        case .agent:   return NSColor.systemGreen.withAlphaComponent(0.85)
        case .remote:  return NSColor.systemPurple.withAlphaComponent(0.85)
        case .unknown: return NSColor.systemGray.withAlphaComponent(0.7)
        }
    }
}
