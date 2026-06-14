import AppKit

/// v0.5.1 — custom-view menu header.
///
/// The old header block was 4 *disabled* `NSMenuItem`s (headline + guard
/// lines). macOS renders disabled rows at reduced opacity — even with an
/// `attributedTitle` color — so the most important readout in the whole menu
/// was also the least legible, and looked like an inactive control
/// (사용자 피드백 2026-06-11). A view-backed item is exempt from that
/// dimming: same strings, full opacity, plus a colored status dot that
/// telegraphs the state before reading a word.
///
/// The view is rebuilt on every `rebuildMenu()` pass (menu opens / store
/// changes), so dynamic colors re-resolve per appearance automatically.
final class MenuStatusHeaderView: NSView {

    /// Filled status dot. Drawn (not layer-backed) so dynamic `NSColor`s
    /// resolve against the menu's effective appearance at draw time.
    final class StatusDotView: NSView {
        var color: NSColor = .systemGray { didSet { needsDisplay = true } }
        override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
    }

    /// - Parameters:
    ///   - headline: the ADR-0005 §2 header string (already localized).
    ///   - dotColor: state color — green (holding awake), gray (idle),
    ///     orange (safety release / helper needs attention).
    ///   - guardLines: pre-symbolized ADR-0017 guard-status lines
    ///     (`MenuBarController.symbolize` output); empty when helper not enabled.
    init(headline: String, dotColor: NSColor, guardLines: [NSAttributedString]) {
        super.init(frame: .zero)

        let dot = StatusDotView()
        dot.color = dotColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])

        let title = NSTextField(labelWithString: headline)
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        // Single-line: without this, the zero-frame first layout pass pins
        // `preferredMaxLayoutWidth` tiny and the label wraps forever.
        title.usesSingleLineMode = true

        let titleRow = NSStackView(views: [dot, title])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(titleRow)

        for line in guardLines {
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = line
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true  // see `title` note above
            // Indent so guard lines align with the headline text
            // (dot 10pt + titleRow spacing 6pt).
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let row = NSStackView(views: [spacer, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 0
            column.addArrangedSubview(row)
        }

        addSubview(column)
        // 14pt leading ≈ NSMenu's text indent with the state column closed,
        // so the headline lines up with Settings…/Quit below (ADR-0005 §2).
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        // NSMenu sizes a view-backed item from the view's frame, then keeps
        // the width in sync via autoresizing.
        let fit = fittingSize
        frame = NSRect(x: 0, y: 0, width: max(fit.width, 230), height: fit.height)
        autoresizingMask = [.width]

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let spoken = ([headline] + guardLines.map(\.string)).joined(separator: ", ")
        setAccessibilityLabel(spoken)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
