import AppKit
import SwiftUI

/// NSPanel that floats next to a clicked `[N]` reference and shows the matching bibliography
/// entry. Same shape as `SelectionPanelController`: SwiftUI layer drives present/dismiss in
/// response to session state, the controller owns the panel's lifecycle.
@MainActor
final class ReferencePreviewPanelController {
    private var panel: NSPanel?
    private var host: NSHostingController<ReferencePreviewView>?
    private weak var parentWindow: NSWindow?

    var onJump: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    func present(near screenRect: NSRect, entry: ReferenceEntry, ownerWindow: NSWindow?) {
        let view = makeView(entry: entry)
        if panel == nil {
            buildPanel(initialView: view)
        } else {
            host?.rootView = view
        }

        guard let panel else { return }
        attach(panel, to: ownerWindow)
        let size = NSSize(width: 380, height: 230)
        let origin = clampedOrigin(for: size, near: screenRect)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        if let panel {
            parentWindow?.removeChildWindow(panel)
            parentWindow = nil
        }
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func makeView(entry: ReferenceEntry) -> ReferencePreviewView {
        ReferencePreviewView(
            entry: entry,
            onJump: { [weak self] in self?.onJump?() },
            onCopy: { [weak self] in self?.onCopy?() },
            onClose: { [weak self] in self?.onClose?() }
        )
    }

    private func buildPanel(initialView: ReferencePreviewView) {
        let host = NSHostingController(rootView: initialView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 230),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        self.host = host
        self.panel = panel
    }

    private func attach(_ panel: NSPanel, to ownerWindow: NSWindow?) {
        guard parentWindow !== ownerWindow else { return }
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil

        guard let ownerWindow else { return }
        ownerWindow.addChildWindow(panel, ordered: .above)
        parentWindow = ownerWindow
    }

    private func clampedOrigin(for panelSize: NSSize, near rect: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screenFrame = screen?.visibleFrame else {
            return NSPoint(x: rect.midX - panelSize.width / 2, y: rect.minY - panelSize.height - 8)
        }
        let preferredX = rect.midX - panelSize.width / 2
        let preferredYBelow = rect.minY - panelSize.height - 8
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

struct ReferencePreviewView: View {
    let entry: ReferenceEntry
    let onJump: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("[\(entry.number)]")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("p.\(entry.pageIndex + 1)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                Text(entry.text)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            HStack(spacing: 4) {
                actionButton(systemName: "arrow.right.circle", title: "跳转到引用页", action: onJump)
                actionButton(systemName: "doc.on.doc", title: "复制", action: onCopy)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.18)))
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 420)
    }

    private func actionButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
