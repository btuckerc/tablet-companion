import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
@main
struct WacomCompanionApp: App {
    @State private var model = CompanionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("Tablet Companion") {
            CompanionView(model: model)
                .frame(minWidth: 560, minHeight: 520)
                .task { await model.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.refresh() }
                }
        }
        .defaultSize(width: 620, height: 600)
        .windowResizability(.contentSize)
    }
}

@MainActor
@Observable
final class CompanionModel {
    let driver = WacomDriver()
    var permissionCode: Int32?
    var snapshot: DriverSnapshot?
    var driverVersion = "Checking…"
    var driverURL: URL?
    var busy = false
    var error: String?
    var showApplyConfirmation = false
    var selectedTabletID: String?
    var selectedKeyIndex = 1

    var permissionGranted: Bool { permissionCode == 0 }
    var connectedTablets: [TabletSnapshot] { snapshot?.tablets.filter(\.connected) ?? [] }
    var selectedTablet: TabletSnapshot? {
        connectedTablets.first { $0.id == selectedTabletID } ?? connectedTablets.first
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        let found = Self.findDriver()
        driverURL = found.url
        driverVersion = found.version
        guard driverURL != nil else {
            permissionCode = nil
            snapshot = nil
            return
        }
        permissionCode = await driver.permissionStatus(request: false)
        do {
            snapshot = try await driver.snapshot()
            if !connectedTablets.contains(where: { $0.id == selectedTabletID }) { selectedTabletID = connectedTablets.first?.id }
        } catch { snapshot = nil; self.error = errorMessage(error) }
    }

    func requestAutomation() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        permissionCode = await driver.permissionStatus(request: true)
        if permissionCode != 0 {
            error = "Automation access is not granted yet. Approve Tablet Companion in System Settings, then choose Recheck."
        }
        if permissionGranted {
            do {
                snapshot = try await driver.snapshot()
                selectedTabletID = connectedTablets.first?.id
            }
            catch { snapshot = nil; self.error = errorMessage(error) }
        }
    }

    func apply() async {
        guard let tablet = selectedTablet else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await driver.applyDrawingShortcut(tabletID: tablet.id, keyIndex: selectedKeyIndex)
        } catch { self.error = errorMessage(error) }
    }

    func restore() async {
        busy = true; error = nil
        defer { busy = false }
        do { snapshot = try await driver.restoreDrawingShortcut() }
        catch { self.error = errorMessage(error) }
    }

    func disableCenterAutostart() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { snapshot = try await driver.setCenterAutostart(false) }
        catch { self.error = errorMessage(error) }
    }

    private func errorMessage(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }

    private static func findDriver() -> (url: URL?, version: String) {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Wacom Tablet.localized/.Tablet/WacomTabletDriver.app"),
            URL(fileURLWithPath: "/Library/Application Support/Tablet/WacomTabletDriver.app")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let plist = url.appendingPathComponent("Contents/Info.plist")
            let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
                ?? "installed"
            return (url, "\(version) (detected)")
        }
        return (nil, "Not detected")
    }
}

struct CompanionView: View {
    @Bindable var model: CompanionModel
    @State private var showRestoreConfirmation = false
    @State private var installer = DriverInstaller()
    @State private var showCenterConfirmation = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.busy {
                ProgressView("Reading and verifying driver settings…").controlSize(.small)
            }
            if model.driverURL == nil { installationPane }
            else {
                DisclosureGroup("Install driver on a new Mac") { installationPane.padding(.top, 12) }
            }
            if !model.permissionGranted { permissionPane } else { configurationPane }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.permissionGranted {
                DisclosureGroup("Permissions and driver setup") { permissionPane.padding(.top, 12) }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        }
        .alert("Apply drawing shortcut?", isPresented: $model.showApplyConfirmation) {
            Button("Apply") { Task { await model.apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let tablet = model.selectedTablet?.name ?? "selected tablet"
            Text("On \(tablet), leftmost ExpressKey (index \(model.selectedKeyIndex)) will change from \(model.selectedTablet?.keys.first(where: { $0.index == model.selectedKeyIndex })?.summary ?? "current mapping") to Control-Option-Command-D globally. Other keys stay unchanged.")
        }
        .alert("Restore previous assignment?", isPresented: $showRestoreConfirmation) {
            Button("Restore") { Task { await model.restore() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This restores the saved assignment from before the drawing shortcut was applied.") }
        .alert("Disable Wacom Center autostart?", isPresented: $showCenterConfirmation) {
            Button("Disable autostart") { Task { await model.disableCenterAutostart() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes Wacom's startup preference and briefly restarts the driver. It does not uninstall Center, change ExpressKeys, or disable the hardware driver.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Tablet Companion").font(.largeTitle.bold())
            Text("Permission onboarding and ExpressKey preferences for your Wacom tablet.")
                .foregroundStyle(.secondary)
            HStack {
                Label("Driver: \(model.driverVersion)", systemImage: "shippingbox")
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy)
            }.font(.callout)
        }
    }

    private var installationPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install → Allow → Configure").font(.title2.bold())
            Text("Install the Wacom driver to use your tablet. Wacom Center is included, but you don’t need to open it.")
                .font(.callout).foregroundStyle(.secondary)
            if installer.busy { ProgressView(installer.status).controlSize(.small) }
            else { Text(installer.status).font(.callout) }
            if let error = installer.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Download driver") { Task { await installer.prepare() } }
                    .disabled(installer.busy || model.busy)
                if installer.packageURL != nil {
                    Button("Open Installer…") { installer.openInstaller() }.disabled(installer.busy)
                }
                Link("Help", destination: URL(string: "https://www.wacom.com/en-us/support/product-support/drivers")!)
            }
        }
    }

    private var permissionPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect → Allow → Configure").font(.title2.bold())
            Text("Connect your tablet, then approve Automation access when macOS asks. Tablet Companion does not need Accessibility or Input Monitoring itself; those permissions belong to the installed Wacom driver.")
                .foregroundStyle(.secondary)
            statusRow("Automation", ok: model.permissionGranted, detail: model.permissionGranted ? "Allowed" : "Consent needed") {
                Button("Request Automation Access") { Task { await model.requestAutomation() } }
                    .disabled(model.busy || model.driverURL == nil)
                settingsButton("Automation", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            }
            driverPermissionRow("Accessibility", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            driverPermissionRow("Input Monitoring", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            Text("macOS does not create Automation entries by dragging an app. Use Request Automation Access, approve the prompt, and recheck. For driver permissions, drag the actual installed driver app below into the relevant Settings list.")
                .font(.callout).foregroundStyle(.secondary)
            if let url = model.driverURL { driverDrop(url: url) }
            HStack {
                Button("Recheck") { Task { await model.refresh() } }.disabled(model.busy)
                settingsButton("Privacy & Security")
            }
        }
    }

    private var configurationPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configure ExpressKeys").font(.title2.bold())
            if model.snapshot == nil {
                Text(model.busy ? "Reading driver…" : "Driver information unavailable. Refresh to retry.")
                    .foregroundStyle(.secondary)
            } else if model.connectedTablets.isEmpty {
                ContentUnavailableView("No connected tablet", systemImage: "rectangle.connected.to.line.below", description: Text("Connect a Wacom tablet, then choose Refresh."))
            } else {
                Picker("Tablet", selection: $model.selectedTabletID) {
                    ForEach(model.connectedTablets, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                if let tablet = model.selectedTablet {
                    Text("Current keys").font(.headline)
                    ForEach(tablet.keys.sorted { $0.index < $1.index }, id: \.index) { key in
                        HStack {
                            Text("ExpressKey \(key.index)")
                            Spacer(); Text(key.summary).foregroundStyle(.secondary)
                        }
                    }
                    if let limitation = tablet.limitation {
                        Text("Unsupported settings — no mapping changes made.\n\(limitation)")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("Changes affect only the leftmost global ExpressKey. Applying or restoring briefly restarts the Wacom driver; keep the pen idle until verification finishes. Wacom Center is not required.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Apply drawing shortcut") { model.showApplyConfirmation = true }
                            .disabled(model.busy || tablet.limitation != nil || tablet.keys.isEmpty || model.snapshot?.hasRestorePoint == true)
                        if model.snapshot?.hasRestorePoint == true {
                            Button("Restore prior assignment") { showRestoreConfirmation = true }
                                .disabled(model.busy)
                        }
                    }
                }
            }
            Button("Refresh connected tablets") { Task { await model.refresh() } }.disabled(model.busy)
            if let state = model.snapshot {
                HStack {
                    Text("Wacom Center autostart: \(state.centerAutostart ? "On" : "Off")")
                    Spacer()
                    if state.centerAutostart {
                        Button("Disable autostart…") { showCenterConfirmation = true }.disabled(model.busy)
                    }
                }.font(.callout)
            }
        }
    }

    private func statusRow(_ title: String, ok: Bool, detail: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }
            Spacer(); action()
        }
    }

    private func driverPermissionRow(_ title: String, url: String) -> some View {
        HStack {
            Image(systemName: "keyboard").foregroundStyle(.secondary)
            Text(title)
            Spacer(); settingsButton("Open Settings", url: url)
        }
    }

    private func settingsButton(_ title: String, url: String? = nil) -> some View {
        Button(title) { NSWorkspace.shared.open(URL(string: url ?? "x-apple.systempreferences:com.apple.preference.security")!) }
    }

    private func driverDrop(url: URL) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 48, height: 48)
                .onDrag { NSItemProvider(object: url as NSURL) }
            VStack(alignment: .leading) {
                Text("Installed driver app").font(.headline)
                Text("Drag this icon into an Accessibility or Input Monitoring list, or reveal it in Finder.").font(.callout).foregroundStyle(.secondary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
