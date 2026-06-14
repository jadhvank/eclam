import AppKit

/// ⓘ click-help affordance (2026-06-11 사용자 피드백).
///
/// Hover tooltips are invisible until discovered — and the user read "tooltip"
/// as a visible ⓘ icon you can click. So the less-obvious controls get an
/// `info.circle` button that pops a short explanation in a transient popover.
/// The same string stays on the wrapped control's `toolTip` for hover users;
/// this button is the discoverable path to the identical text.
final class InfoButton: NSButton {
    private let text: String
    private var popover: NSPopover?

    /// Max text width inside the popover, in points.
    private static let popoverTextWidth: CGFloat = 300

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: "info.circle",
                        accessibilityDescription: NSL("a11y.info", "Help"))
        contentTintColor = .tertiaryLabelColor
        target = self
        action = #selector(toggle)
        toolTip = text
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
        setAccessibilityLabel(NSL("a11y.info", "Help"))
        setAccessibilityHelp(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Wraps `view` in a horizontal row with an ⓘ button to its right.
    /// Drop-in replacement for the bare view inside a vertical stack.
    static func wrap(_ view: NSView, _ text: String) -> NSStackView {
        let row = NSStackView(views: [view, InfoButton(text)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        return row
    }

    @objc private func toggle() {
        if let p = popover, p.isShown {
            p.close()
            popover = nil
            return
        }
        let font = NSFont.systemFont(ofSize: 12)
        // Measure up front: a wrapping label has no intrinsic width, so sizing
        // the popover from fittingSize alone can collapse to zero.
        let bound = (text as NSString).boundingRect(
            with: NSSize(width: Self.popoverTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let textSize = NSSize(width: ceil(bound.width), height: ceil(bound.height))

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.isSelectable = false
        label.preferredMaxLayoutWidth = Self.popoverTextWidth
        label.frame = NSRect(x: 12, y: 10, width: textSize.width, height: textSize.height)

        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: textSize.width + 24,
                                             height: textSize.height + 20))
        container.addSubview(label)

        let vc = NSViewController()
        vc.view = container
        let p = NSPopover()
        p.contentViewController = vc
        p.contentSize = container.frame.size
        p.behavior = .transient
        p.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = p
    }
}
