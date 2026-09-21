import AppKit
import SwiftUI

struct CompanionMenu: View {
    let status: CompanionStatus
    let model: CompanionModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Driver: \(status.driverText)")
        Text("Tablet: \(status.tabletText)")

        if let detail = status.detail, !detail.isEmpty {
            Text(detail)
                .foregroundStyle(status.needsAttention ? .orange : .secondary)
        }

        if let layout = layoutSummary {
            Divider()
            Text("ExpressKeys: \(layout)")
                .lineLimit(2)
        }

        Divider()

        Button("Open Tablet Companion…") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "companion")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Refresh Status") {
            Task { await status.refresh() }
        }
        .disabled(status.refreshing || model.busy)

        Button("Settings…") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "companion")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit Tablet Companion") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var layoutSummary: String? {
        let tablet = model.snapshot?.tablets.first(where: \.connected) ?? model.snapshot?.tablets.first
        guard let keys = tablet?.keys.sorted(by: { $0.index < $1.index }), !keys.isEmpty else { return nil }
        return keys.map { $0.action?.title ?? "Unknown (\($0.summary))" }.joined(separator: " · ")
    }
}
