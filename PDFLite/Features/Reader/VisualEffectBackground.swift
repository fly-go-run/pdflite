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
