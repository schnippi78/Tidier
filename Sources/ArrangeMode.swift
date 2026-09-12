import AppKit
import SwiftUI

/// A small floating guide shown during "Arrange" mode. macOS 26 blocks programmatic
/// reordering of menu bar items, so Tidier reveals everything, marks its separator,
/// and this HUD tells the user how to ⌘-drag their essentials into the visible zone.
final class ArrangeHUD {
    static let shared = ArrangeHUD()
    private var panel: NSPanel?
    var onDone: (() -> Void)?

    func show(near rect: NSRect) {
        let root = ArrangeView(onDone: { [weak self] in self?.onDone?() })
            .environment(\.layoutDirection, LanguageManager.shared.isRTL ? .rightToLeft : .leftToRight)
        let hosting = NSHostingView(rootView: root)
        hosting.layout()
        let size = hosting.fittingSize
        let width: CGFloat = 340
        let height = max(140, size.height)

        let p = panel ?? makePanel()
        panel = p
        p.contentView = hosting
        p.setContentSize(NSSize(width: width, height: height))

        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main {
            let x = min(max(screen.frame.minX + 12, rect.midX - width / 2), screen.frame.maxX - width - 12)
            let y = rect.minY - height - 8
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        p.makeKeyAndOrderFront(nil)   // key so the "Fertig" button receives clicks
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = ArrangePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }
}

private final class ArrangePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ArrangeVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct ArrangeView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.tint)
                Text("Menüleiste anordnen").font(.headline)
            }
            Text("Halte **⌘** und ziehe die Icons, die **immer sichtbar** bleiben sollen, **rechts** neben Tidiers Markierung. Alles **links** davon wird ausgeblendet.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label("links = versteckt", systemImage: "eye.slash")
                Spacer(minLength: 8)
                Label("rechts = sichtbar", systemImage: "eye")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Fertig", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(ArrangeVisualEffect().clipShape(RoundedRectangle(cornerRadius: 16)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
    }
}
