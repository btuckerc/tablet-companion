import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
@main
struct WacomCompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionApplicationDelegate.self) private var applicationDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    private var model: CompanionModel { applicationDelegate.model }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window("Tablet Companion", id: "companion") {
            CompanionView(model: model)
                .frame(minWidth: 560, minHeight: 520)
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .task { await model.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, NSApp.activationPolicy() == .regular else { return }
                    Task { await model.refresh() }
                }
        }
        .defaultSize(width: 620, height: 600)
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            CompanionMenu(status: applicationDelegate.status, model: model)
        } label: {
            Label("Tablet Companion", systemImage: applicationDelegate.status.needsAttention
                  ? "exclamationmark.triangle" : "rectangle.and.pencil.and.ellipsis")
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: showMenuBarIcon) { _, enabled in
            applicationDelegate.updateMenuBarVisibility(enabled)
        }
    }
}

@MainActor
final class CompanionApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = CompanionModel()
    lazy var status = CompanionStatus(driver: model.driver, isBusy: { [weak self] in self?.model.busy ?? false })

    private var showMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if showMenuBarIcon { status.start() }
    }

    func updateMenuBarVisibility(_ enabled: Bool) {
        if enabled {
            status.start()
        } else {
            status.stop()
            // Removing the icon must not leave an unreachable background app.
            if !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Tablet Companion" }) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.setActivationPolicy(.regular)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard showMenuBarIcon else { return true }
        sender.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        status.stop()
        guard model.busy else { return .terminateNow }
        // Let an in-flight driver import and its verification finish before exiting.
        Task {
            while model.busy { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
    var showRestoreConfirmation = false
    var showPenApplyConfirmation = false
    var showPenRestoreConfirmation = false
    var selectedTabletID: String? {
        didSet {
            guard oldValue != selectedTabletID else { return }
            if let id = selectedTabletID { ensureDraft(for: id); ensurePenDraft(for: id) }
        }
    }
    private var drafts: [String: [ExpressKeyAction]] = [:]
    private var penDrafts: [String: [String: PenButtonClick]] = [:]
    var draftActions: [ExpressKeyAction] {
        guard let id = selectedTablet?.id else { return [] }
        return drafts[id] ?? []
    }
    var draftPenActions: [String: PenButtonClick] {
        guard let id = selectedTablet?.id else { return [:] }
        return penDrafts[id] ?? [:]
    }
    var canApplyLayout: Bool {
        guard let tablet = selectedTablet else { return false }
        return !busy && tablet.limitation == nil && !tablet.keys.isEmpty
    }
    var canApplyPenActions: Bool {
        guard let tablet = selectedTablet else { return false }
        return !busy && tablet.limitation == nil && !tablet.penButtons.isEmpty
    }
    private(set) var preferencesAccessFailure: WacomPreferencesAccessError?
    var preferencesAccessRequested: Bool {
        UserDefaults.standard.bool(forKey: "wacomPreferencesAccessRequested")
    }
    var permissionGranted: Bool { permissionCode == 0 }
    var preferencesAccessReady: Bool { snapshot != nil && preferencesAccessFailure == nil }
    var connectedTablets: [TabletSnapshot] { snapshot?.tablets.filter(\.connected) ?? [] }
    var selectedTablet: TabletSnapshot? {
        connectedTablets.first { $0.id == selectedTabletID } ?? connectedTablets.first
    }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        preferencesAccessFailure = nil
        let found = Self.findDriver()
        driverURL = found.url
        driverVersion = found.version
        guard driverURL != nil else {
            permissionCode = nil
            snapshot = nil
            return
        }
        permissionCode = await driver.permissionStatus(request: false)
        guard preferencesAccessRequested else {
            snapshot = nil
            return
        }
        await readPreferences()
    }

    func requestWacomSettingsAccess() async {
        guard !busy, driverURL != nil else { return }
        busy = true
        defer { busy = false }
        error = nil
        UserDefaults.standard.set(true, forKey: "wacomPreferencesAccessRequested")
        await readPreferences()
    }

    private func readPreferences() async {
        do {
            snapshot = try await driver.snapshot()
            preferencesAccessFailure = nil
            if !connectedTablets.contains(where: { $0.id == selectedTabletID }) {
                selectedTabletID = connectedTablets.first?.id
            }
            for tablet in connectedTablets {
                if drafts[tablet.id] == nil {
                    drafts[tablet.id] = tablet.keys.sorted { $0.index < $1.index }.map { $0.action ?? .unchanged }
                }
                ensurePenDraft(for: tablet.id)
            }
        } catch let accessError as WacomPreferencesAccessError {
            snapshot = nil
            preferencesAccessFailure = accessError
        } catch {
            snapshot = nil
            self.error = errorMessage(error)
        }
    }

    private func ensureDraft(for id: String) {
        guard drafts[id] == nil else { return }
        let current = snapshot?.tablets.first { $0.id == id }?.keys.sorted { $0.index < $1.index } ?? []
        drafts[id] = current.map { $0.action ?? .unchanged }
    }
    private func ensurePenDraft(for id: String) {
        guard penDrafts[id] == nil else { return }
        let buttons = snapshot?.tablets.first { $0.id == id }?.penButtons ?? []
        penDrafts[id] = Dictionary(uniqueKeysWithValues: buttons.map { ($0.id, $0.click ?? .unchanged) })
    }
    func setDraftAction(_ action: ExpressKeyAction, at index: Int) {
        guard let id = selectedTablet?.id, draftActions.indices.contains(index) else { return }
        ensureDraft(for: id)
        var values = drafts[id] ?? []
        values[index] = action
        drafts[id] = values
    }
    func useSuggestedLayout() {
        guard let tablet = selectedTablet else { return }
        let current = tablet.keys.sorted { $0.index < $1.index }.map { $0.action ?? .unchanged }
        drafts[tablet.id] = current.indices.map { index in
            index < ExpressKeyAction.defaultLayout.count ? ExpressKeyAction.defaultLayout[index] : current[index]
        }
    }
    func action(at index: Int) -> ExpressKeyAction {
        draftActions.indices.contains(index) ? draftActions[index] : .unchanged
    }
    func setPenAction(_ action: PenButtonClick, for id: String) {
        guard let tablet = selectedTablet, tablet.penButtons.contains(where: { $0.id == id }) else { return }
        ensurePenDraft(for: tablet.id)
        var values = penDrafts[tablet.id] ?? [:]
        values[id] = action
        penDrafts[tablet.id] = values
    }
    func penAction(for id: String) -> PenButtonClick { draftPenActions[id] ?? .unchanged }
    var layoutConfirmation: String {
        guard let tablet = selectedTablet else { return "No tablet is selected." }
        let current = tablet.keys.sorted { $0.index < $1.index }
        return current.indices.map { index in
            let from = current[index].action?.title ?? "Unknown (\(current[index].summary))"
            return "ExpressKey \(index + 1): \(from) → \(action(at: index).title)"
        }.joined(separator: "\n")
    }
    var penConfirmation: String {
        guard let tablet = selectedTablet else { return "No tablet is selected." }
        return tablet.penButtons.map { button in
            "\(button.name): \(button.click?.title ?? button.summary) → \(penAction(for: button.id).title)"
        }.joined(separator: "\n")
    }
    func requestAutomation() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        permissionCode = await driver.permissionStatus(request: true)
        if permissionCode != 0 {
            error = "Automation access is not granted yet. Approve Tablet Companion in System Settings, then choose Recheck."
        } else if preferencesAccessRequested {
            await readPreferences()
        }
    }


    func applyLayout() async {
        guard let tablet = selectedTablet, canApplyLayout else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await driver.applyExpressKeyLayout(tabletID: tablet.id, actions: draftActions)
            drafts[tablet.id] = snapshot?.tablets.first { $0.id == tablet.id }?.keys.sorted { $0.index < $1.index }.map { $0.action ?? .unchanged } ?? draftActions
        } catch { handle(error) }
    }
    func applyPenActions() async {
        guard let tablet = selectedTablet, canApplyPenActions else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await driver.applyPenButtons(tabletID: tablet.id, assignments: draftPenActions)
            if let updated = snapshot?.tablets.first(where: { $0.id == tablet.id }) {
                penDrafts[tablet.id] = Dictionary(uniqueKeysWithValues: updated.penButtons.map { ($0.id, $0.click ?? .unchanged) })
            }
        } catch { handle(error) }
    }
    func restorePenActions() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await driver.restorePenButtons()
            if let id = selectedTablet?.id {
                penDrafts.removeValue(forKey: id)
                ensurePenDraft(for: id)
            }
        } catch { handle(error) }
    }
    func restore() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await driver.restoreExpressKeyLayout()
            if let id = selectedTablet?.id {
                drafts[id] = snapshot?.tablets.first { $0.id == id }?.keys.sorted { $0.index < $1.index }.map { $0.action ?? .unchanged }
            }
        } catch { handle(error) }
    }

    func disableOverlay() async {
        guard let tablet = selectedTablet, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { snapshot = try await driver.disableExpressKeyOverlay(tabletID: tablet.id) }
        catch { handle(error) }
    }
    func disableCenterAutostart() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { snapshot = try await driver.setCenterAutostart(false) }
        catch { handle(error) }
    }

    private func handle(_ error: Error) {
        if let accessError = error as? WacomPreferencesAccessError {
            snapshot = nil
            preferencesAccessFailure = accessError
            self.error = nil
        } else {
            self.error = errorMessage(error)
        }
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
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var installer = DriverInstaller()
    @State private var showCenterConfirmation = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            header
            if model.busy {
                ProgressView("Updating…").controlSize(.small)
            }
            if model.driverURL == nil { installationPane }
            if !model.permissionGranted || !model.preferencesAccessReady { permissionPane } else { configurationPane }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.permissionGranted && model.preferencesAccessReady {
                DisclosureGroup("Setup help") { permissionPane.padding(.top, 12) }
            }
            DisclosureGroup("More options") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Keep Companion in the menu bar", isOn: $showMenuBarIcon)
                    Text("Your tablet settings keep working when Companion is closed.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let state = model.snapshot, state.centerAutostart {
                        Button("Stop Wacom Center opening at login…") { showCenterConfirmation = true }.disabled(model.busy)
                    }
                    Text("Driver \(model.driverVersion)").font(.caption).foregroundStyle(.secondary)
                    if model.driverURL != nil {
                        DisclosureGroup("Reinstall driver") { installationPane.padding(.top, 8) }
                    }
                }.padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        }
        .alert("Apply ExpressKey layout?", isPresented: $model.showApplyConfirmation) {
            Button("Apply layout") { Task { await model.applyLayout() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let tablet = model.selectedTablet?.name ?? "selected tablet"
            Text("\(tablet)\n\(model.layoutConfirmation)\nAffects all apps. The tablet will briefly reconnect.")
        }
        .alert("Restore previous tablet buttons?", isPresented: $model.showRestoreConfirmation) {
            Button("Restore") { Task { await model.restore() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Put the tablet buttons back the way they were before Companion changed them. The tablet will briefly reconnect.")
        }
        .alert("Apply pen assignments?", isPresented: $model.showPenApplyConfirmation) {
            Button("Apply pen assignments") { Task { await model.applyPenActions() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.penConfirmation)\nAffects all apps. Buttons will work while hovering—no tip tap needed. The tablet will briefly reconnect.")
        }
        .alert("Restore previous pen assignments?", isPresented: $model.showPenRestoreConfirmation) {
            Button("Restore") { Task { await model.restorePenActions() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Put the pen buttons and hover behavior back the way they were before Companion changed them.")
        }
        .alert("Disable Wacom Center autostart?", isPresented: $showCenterConfirmation) {
            Button("Disable autostart") { Task { await model.disableCenterAutostart() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Wacom Center will stop opening at login. Your tablet will keep working and briefly reconnect.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Tablet Companion").font(.largeTitle.bold())
            HStack {
                Text("Set up your tablet buttons.").foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy)
            }.font(.callout)
        }
    }

    private var installationPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install the tablet driver").font(.title2.bold())
            Text("Download it, run the installer, then come back here.")
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
            Text("Allow tablet access").font(.title2.bold())
            Text("macOS needs your permission before we can change the buttons.")
                .foregroundStyle(.secondary)
            statusRow("Automation", ok: model.permissionGranted, detail: model.permissionGranted ? "Allowed" : "Consent needed") {
                Button("Allow") { Task { await model.requestAutomation() } }
                    .disabled(model.busy || model.driverURL == nil)
                settingsButton("Automation", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            }
            statusRow("Tablet settings", ok: model.preferencesAccessReady,
                      detail: wacomAccessDetail) {
                if !model.preferencesAccessReady {
                    Button("Allow") { Task { await model.requestWacomSettingsAccess() } }
                        .disabled(model.busy || model.driverURL == nil || !model.permissionGranted)
                } else {
                    Button("Recheck") { Task { await model.refresh() } }.disabled(model.busy)
                }
            }
            if let failure = model.preferencesAccessFailure {
                switch failure {
                case .denied:
                    Text("In Files & Folders → Tablet Companion, turn on “Data shared by Wacom Center and affiliated apps”. Then click Recheck.")
                        .font(.callout).foregroundStyle(.orange)
                    settingsButton("Open Files & Folders",
                                   url: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
                case .missing:
                    Text("Tablet settings are missing. Finish installing the Wacom driver, then click Recheck.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            DisclosureGroup("Pen not responding?") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Allow the Wacom driver in both places:").font(.callout)
                    driverPermissionRow("Accessibility", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    driverPermissionRow("Input Monitoring", url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                    if let url = model.driverURL { driverDrop(url: url) }
                }.padding(.top, 8)
            }
            HStack {
                Button("Recheck") { Task { await model.refresh() } }.disabled(model.busy)
                settingsButton("Privacy & Security")
            }
        }
    }
    private var wacomAccessDetail: String {
        if model.preferencesAccessReady { return "Allowed" }
        if let failure = model.preferencesAccessFailure {
            switch failure {
            case .denied: return "Denied"
            case .missing: return "Wacom preferences missing"
            }
        }
        return "Permission needed"
    }

    private var configurationPane: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    Text("Tablet buttons · left to right").font(.headline)
                    Text("Start with Annotate. The other actions work while drawing.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(tablet.keys.sorted(by: { $0.index < $1.index }), id: \.index) { key in
                        let index = tablet.keys.sorted(by: { $0.index < $1.index }).firstIndex(where: { $0.index == key.index }) ?? 0
                        HStack {
                            Text("ExpressKey \(index + 1)")
                            Spacer()
                            Picker("Action", selection: Binding(
                                get: { model.action(at: index) },
                                set: { model.setDraftAction($0, at: index) }
                            )) {
                                ForEach(ExpressKeyAction.allCases) { action in Text(action.title).tag(action) }
                            }
                            .labelsHidden().frame(width: 190)
                        }
                    }
                    if tablet.keys.isEmpty {
                        Text("No ExpressKeys were discovered for this tablet.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Use suggested layout") { model.useSuggestedLayout() }.disabled(tablet.keys.isEmpty)
                        Button("Apply layout") { model.showApplyConfirmation = true }
                            .disabled(!model.canApplyLayout)
                        if model.snapshot?.hasRestorePoint == true {
                            Button("Restore prior layout") { model.showRestoreConfirmation = true }.disabled(model.busy)
                        }
                    }
                    if !tablet.penButtons.isEmpty {
                        Divider()
                        Text("Pen buttons").font(.headline)
                        Text("In StreamApp: Middle click = Straighten. Secondary click = Tools.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(tablet.penButtons) { button in
                            HStack {
                                Text(button.name)
                                Spacer()
                                Picker("Click", selection: Binding(
                                    get: { model.penAction(for: button.id) },
                                    set: { model.setPenAction($0, for: button.id) }
                                )) {
                                    ForEach(PenButtonClick.allCases) { click in Text(click.title).tag(click) }
                                }
                                .labelsHidden().frame(width: 190)
                            }
                        }
                        HStack {
                            Button("Apply pen assignments") { model.showPenApplyConfirmation = true }
                                .disabled(!model.canApplyPenActions)
                            if model.snapshot?.hasPenRestorePoint == true {
                                Button("Restore pen assignments") { model.showPenRestoreConfirmation = true }.disabled(model.busy)
                            }
                        }
                    }
                    if let limitation = tablet.limitation {
                        Text("Unsupported settings — no mapping changes made.\n\(limitation)")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Hide Wacom button overlay") { Task { await model.disableOverlay() } }
                            .disabled(model.busy || tablet.limitation != nil || tablet.overlayDisabled == true)
                        Text(tablet.overlayDisabled == true ? "Hidden" : (tablet.overlayDisabled == false ? "Shown" : "Unknown"))
                            .foregroundStyle(tablet.overlayDisabled == true ? .green : .secondary)
                    }
                }
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
                Text("Wacom driver").font(.headline)
                Text("Drag this icon into the permission list if it is missing.").font(.callout).foregroundStyle(.secondary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
