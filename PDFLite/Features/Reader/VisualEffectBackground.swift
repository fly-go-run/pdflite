import AppKit
import SwiftUI

/// Thin NSViewRepresentable wrapper around `NSVisualEffectView`. SwiftUI's `.regularMaterial`
/// background flickers (one transparent frame) during the fullscreen ↔ windowed animation
/// because the material gets re-evaluated mid-resize. The AppKit view animates natively and
/// stays solid through the transition.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // Match AppKit's default sidebar (NSSplitViewItem.Behavior.sidebar): vibrancy follows
        // the window's active state and is not emphasized. `isEmphasized = true` saturates the
        // material more aggressively and made the right column tint visibly different from the
        // NavigationSplitView-managed left sidebar.
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
        if view.blendingMode != blendingMode { view.blendingMode = blendingMode }
    }
}

/// Fills the view with an `NSColor` via AppKit drawing. Using `Color(nsColor:)` in SwiftUI goes
/// through a color-space conversion that drops macOS Tahoe's subtle green tint on
/// `windowBackgroundColor`, so SwiftUI ends up rendering #1E1E1E while PDFView (which fills the
/// `NSColor` directly) renders #202220. This wrapper keeps the inspector matched to PDFView.
struct NSColorBackground: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> ColorFillView {
        let view = ColorFillView()
        view.fillColor = color
        return view
    }

    func updateNSView(_ view: ColorFillView, context: Context) {
        view.fillColor = color
    }

    final class ColorFillView: NSView {
        var fillColor: NSColor = .windowBackgroundColor {
            didSet { needsDisplay = true }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            // Resolve through the current appearance so the catalog color matches whatever
            // AppKit's NSColor.windowBackgroundColor reports in this draw pass — this is the same
            // path PDFView's `backgroundColor` setter uses internally.
            layer?.backgroundColor = fillColor.cgColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}
