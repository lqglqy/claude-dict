import AppKit
import SwiftUI

/// Panels never activate the app, so their first click must reach the button under it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Rounded, translucent chrome for borderless panels.
enum PanelChrome {
    static func wrap(_ content: NSView, radius: CGFloat) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: radius)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Borderless panel that floats above other apps without activating ClaudeDict.
final class FloatingPanel: NSPanel {
    private let allowsKey: Bool
    var onEscape: (() -> Void)?

    init(allowsKey: Bool, resizable: Bool, level: NSWindow.Level) {
        self.allowsKey = allowsKey
        var style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: style,
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        self.level = level
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = !allowsKey
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow
        // ClaudeDict stays inactive while its panels show, and AppKit hides an inactive
        // app's tooltips by default. The icon-only toolbar needs them to name its buttons.
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// The visible frame of the screen under `point`.
    static func visibleFrame(at point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

/// Lets an empty part of a SwiftUI view drag the borderless window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Bottom-right grip that resizes the borderless window, keeping its top edge in place.
struct ResizeGrip: NSViewRepresentable {
    final class GripView: NSView {
        private var startFrame = NSRect.zero
        private var startMouse = NSPoint.zero

        override func mouseDown(with event: NSEvent) {
            startFrame = window?.frame ?? .zero
            startMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let now = NSEvent.mouseLocation
            var frame = startFrame
            frame.size.width = max(window.minSize.width, startFrame.width + (now.x - startMouse.x))
            frame.size.height = max(window.minSize.height, startFrame.height - (now.y - startMouse.y))
            frame.origin.y = startFrame.maxY - frame.height
            window.setFrame(frame, display: true)
        }

        override func mouseUp(with event: NSEvent) {
            window?.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.tertiaryLabelColor.setStroke()
            for i in 0..<3 {
                let offset = CGFloat(i) * 4 + 3
                let path = NSBezierPath()
                path.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 1))
                path.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY + offset))
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HoverButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, selected: selected)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fill)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if selected { return Color.accentColor.opacity(configuration.isPressed ? 0.28 : 0.18) }
            if configuration.isPressed { return Color.primary.opacity(0.16) }
            return hovering && isEnabled ? Color.primary.opacity(0.08) : .clear
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
    }
}

struct TextButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
        }
        .buttonStyle(HoverButtonStyle())
    }
}

/// Renders the Markdown subset from `Markdown.parse`. Inline marks go through AttributedString.
struct MarkdownView: View {
    let text: String
    var streaming = false

    var body: some View {
        let blocks = Markdown.parse(text)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, tail: streaming && index == blocks.count - 1 ? " ▍" : "")
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, tail: String) -> some View {
        switch block {
        case .heading(_, let t):
            inline(t + tail)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 3)
        case .paragraph(let t):
            inline(t + tail)
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(t + tail).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 14))
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let marker, let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary)
                inline(t + tail).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 14))
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let t):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: 3)
                inline(t + tail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let t):
            Text(t + tail)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func inline(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return Text(attributed)
        }
        return Text(string)
    }
}
