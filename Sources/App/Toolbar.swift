import AppKit
import SwiftUI

enum ToolbarAction {
    case translate, polish, analyze, speak, copy

    var lookup: Action? {
        switch self {
        case .translate: return .translate
        case .polish: return .polish
        case .analyze: return .analyze
        case .speak, .copy: return nil
        }
    }
}

struct ToolbarView: View {
    @ObservedObject var speech: SpeechController
    let text: String
    let onAction: (ToolbarAction) -> Void
    let onHover: (Bool) -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 1) {
            item(Action.translate.title, Action.translate.symbol) { onAction(.translate) }
            item(Action.polish.title, Action.polish.symbol) { onAction(.polish) }
            item(Action.analyze.title, Action.analyze.symbol) { onAction(.analyze) }
            Divider().frame(height: 16).padding(.horizontal, 3)
            let reading = speech.isReading(text)
            item(reading ? "停止" : "朗读", reading ? "stop.fill" : "speaker.wave.2") { onAction(.speak) }
            item(copied ? "已复制" : "复制", copied ? "checkmark" : "doc.on.doc") {
                onAction(.copy)
                copied = true
            }
        }
        .padding(4)
        .onHover(perform: onHover)
        .fixedSize()
    }

    private func item(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12))
            }
        }
        .buttonStyle(HoverButtonStyle())
    }
}

/// The small action bar that appears next to a fresh selection.
@MainActor
final class ToolbarController {
    var onAction: ((ToolbarAction, CapturedSelection, NSPoint) -> Void)?
    var autoHideSeconds: Double = 6

    private let speech: SpeechController
    private let panel = FloatingPanel(allowsKey: false, resizable: false, level: .popUpMenu)
    private var selection: CapturedSelection?
    private var anchor = NSPoint.zero
    private var hovering = false
    private var hideWork: DispatchWorkItem?

    init(speech: SpeechController) {
        self.speech = speech
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ selection: CapturedSelection, at point: NSPoint) {
        self.selection = selection
        anchor = point
        hovering = false
        let view = ToolbarView(speech: speech, text: selection.text,
                               onAction: { [weak self] action in self?.trigger(action) },
                               onHover: { [weak self] inside in self?.hovering = inside })
        let hosting = FirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize
        panel.contentView = PanelChrome.wrap(hosting, radius: 9)
        panel.setFrame(Self.frame(for: size, near: point), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        scheduleHide(after: autoHideSeconds)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    /// Renders the toolbar into a PNG (used by --snapshot-toolbar to check the layout).
    func capture(to url: URL) throws {
        guard let view = panel.contentView else { return }
        try Snapshot.write(view, to: url)
    }

    private func trigger(_ action: ToolbarAction) {
        guard let selection else { return }
        switch action {
        case .speak:
            speech.toggle(selection.text)
            scheduleHide(after: autoHideSeconds)
        case .copy:
            SelectionReader.copyToClipboard(selection.text)
            scheduleHide(after: 0.8)
        case .translate, .polish, .analyze:
            let point = NSPoint(x: panel.frame.minX + 12, y: panel.frame.maxY)
            hide()
            onAction?(action, selection, point)
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hovering || self.speech.isSpeaking {
                    self.scheduleHide(after: 1.5)
                } else {
                    self.hide()
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Just below the pointer, centred on it, kept on screen.
    private static func frame(for size: NSSize, near point: NSPoint) -> NSRect {
        let visible = FloatingPanel.visibleFrame(at: point)
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - 14 - size.height)
        if origin.y < visible.minY + 4 { origin.y = point.y + 14 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSRect(origin: origin, size: size)
    }
}

enum Snapshot {
    /// Draws a view hierarchy into a PNG over an opaque background, no screen recording needed.
    @MainActor
    static func write(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw NSError(domain: "ClaudeDict", code: 1, userInfo: [NSLocalizedDescriptionKey: "no bitmap"])
        }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: 10, yRadius: 10).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClaudeDict", code: 2, userInfo: [NSLocalizedDescriptionKey: "png encoding failed"])
        }
        try png.write(to: url)
    }
}
