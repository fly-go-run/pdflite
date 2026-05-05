import AppKit
import SwiftUI

/// Owns the lifecycle of the NSPanel that floats next to the user's selection. One controller
/// per ReaderWindow. The controller does not subscribe to anything itself — the SwiftUI layer
/// calls `present(near:)`, `update(...)`, and `dismiss()` in response to session state changes.
@MainActor
final class SelectionPanelController {
    private var panel: NSPanel?
    private var host: NSHostingController<SelectionFloatingView>?

    var onTranslate: (() -> Void)?
    var onHighlight: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCancel: (() -> Void)?
    var onJumpToFigure: (() -> Void)?

    /// Show or move the panel so it sits just below `screenRect` (the screen-space bounds of the
    /// current selection). Translation state, if any, is rendered in the preview area;
    /// `figureReference` is non-nil when the selection looks like "Figure 3" / "Table 2" and
    /// adds a jump button to the action row.
    func present(
        near screenRect: NSRect,
        translation: TranslationOutput?,
        figureReference: FigureReference?,
        inspectorOpen: Bool,
        truncatedToFirstPage: Bool
    ) {
        let view = makeView(
            translation: translation,
            figureReference: figureReference,
            inspectorOpen: inspectorOpen,
            truncatedToFirstPage: truncatedToFirstPage
        )
        if panel == nil {
            buildPanel(initialView: view)
        } else {
            host?.rootView = view
        }

        guard let panel else { return }
        let size = panelSize(
            translation: translation,
            figureReference: figureReference,
            inspectorOpen: inspectorOpen,
            truncatedToFirstPage: truncatedToFirstPage
        )
        let origin = clampedOrigin(for: size, near: screenRect)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func update(
        translation: TranslationOutput?,
        figureReference: FigureReference?,
        inspectorOpen: Bool,
        truncatedToFirstPage: Bool
    ) {
        guard panel?.isVisible == true else { return }
        host?.rootView = makeView(
            translation: translation,
            figureReference: figureReference,
            inspectorOpen: inspectorOpen,
            truncatedToFirstPage: truncatedToFirstPage
        )
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Build

    private func makeView(
        translation: TranslationOutput?,
        figureReference: FigureReference?,
        inspectorOpen: Bool,
        truncatedToFirstPage: Bool
    ) -> SelectionFloatingView {
        SelectionFloatingView(
            translation: translation,
            figureReference: figureReference,
            inspectorOpen: inspectorOpen,
            truncatedToFirstPage: truncatedToFirstPage,
            onTranslate: { [weak self] in self?.onTranslate?() },
            onHighlight: { [weak self] in self?.onHighlight?() },
            onCopy: { [weak self] in self?.onCopy?() },
            onCancel: { [weak self] in self?.onCancel?() },
            onJumpToFigure: { [weak self] in self?.onJumpToFigure?() }
        )
    }

    private func buildPanel(initialView: SelectionFloatingView) {
        let host = NSHostingController(rootView: initialView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.host = host
        self.panel = panel
    }

    private func panelSize(
        translation: TranslationOutput?,
        figureReference: FigureReference?,
        inspectorOpen: Bool,
        truncatedToFirstPage: Bool
    ) -> NSSize {
        // The "跨页·仅首页" hint adds one short line above the buttons.
        let hintExtra: CGFloat = truncatedToFirstPage ? 16 : 0

        // Inspector-open compact mode: icon-only buttons, no preview row. Stay narrow so the
        // panel doesn't shadow the user's reading area.
        if inspectorOpen {
            let width: CGFloat = figureReference != nil ? 240 : 180
            return NSSize(width: width, height: 44 + hintExtra)
        }

        let hasPreview = translation.map { output in
            output.errorMessage != nil
                || output.isStreaming
        } ?? false

        let width: CGFloat
        if figureReference != nil {
            width = 350
        } else if translation?.isStreaming == true {
            width = 330
        } else {
            width = 300
        }

        if translation?.errorMessage != nil {
            return NSSize(width: width, height: 100 + hintExtra)
        }
        return NSSize(width: width, height: (hasPreview ? 72 : 44) + hintExtra)
    }

    /// Place the panel just below the selection rect, then clamp inside the screen the rect
    /// belongs to so it can't fall behind the menu bar / dock / off-display.
    private func clampedOrigin(for panelSize: NSSize, near rect: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screenFrame = screen?.visibleFrame else {
            return NSPoint(x: rect.midX - panelSize.width / 2, y: rect.minY - panelSize.height - 8)
        }

        let preferredX = rect.midX - panelSize.width / 2
        let preferredYBelow = rect.minY - panelSize.height - 8
        // If there's no room below, flip above.
        let yIfBelow = preferredYBelow >= screenFrame.minY ? preferredYBelow : rect.maxY + 8
        var origin = NSPoint(x: preferredX, y: yIfBelow)

        let minX = screenFrame.minX + 4
        let maxX = screenFrame.maxX - panelSize.width - 4
        let minY = screenFrame.minY + 4
        let maxY = screenFrame.maxY - panelSize.height - 4
        origin.x = min(max(origin.x, minX), maxX)
        origin.y = min(max(origin.y, minY), maxY)
        return origin
    }
}
