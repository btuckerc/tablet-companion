import AppKit
import Observation

@MainActor @Observable
final class CompanionStatus {
    private let driver: WacomDriver
    private let isBusy: @MainActor () -> Bool
    private var notifications: [NSObjectProtocol] = []
    private var monitor: Task<Void, Never>?
    private var started = false
    private var sleeping = false
    private var refreshGeneration = 0

    var driverText = "Checking…"
    var tabletText = "Checking…"
    var detail: String?
    var needsAttention = false
    var refreshing = false

    init(driver: WacomDriver, isBusy: @escaping @MainActor () -> Bool = { false }) {
        self.driver = driver
        self.isBusy = isBusy
    }

    func start() {
        guard !started else { return }
        started = true
        sleeping = false
        let center = NSWorkspace.shared.notificationCenter
        notifications = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.wacom.wacomtablet" else { return }
                Task { @MainActor [weak self] in await self?.refresh() }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.wacom.wacomtablet" else { return }
                Task { @MainActor [weak self] in await self?.refresh() }
            },
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.started else { return }
                    self.sleeping = true
                    self.refreshGeneration += 1
                    self.refreshing = false
                    self.monitor?.cancel()
                    self.monitor = nil
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.started else { return }
                    self.sleeping = false
                    self.beginMonitoring()
                    Task { @MainActor [weak self] in await self?.refresh() }
                }
            }
        ]
        beginMonitoring()
        Task { @MainActor [weak self] in await self?.refresh() }
    }

    func stop() {
        guard started else { return }
        started = false
        refreshGeneration += 1
        monitor?.cancel()
        monitor = nil
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        notifications.removeAll()
        refreshing = false
    }

    func refresh() async {
        guard started, !sleeping, !refreshing else { return }
        refreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        defer { if generation == refreshGeneration { refreshing = false } }

        let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.wacom.wacomtablet").first
        guard let app else {
            driverText = "Not running"
            tabletText = "Unavailable"
            detail = "Open Tablet Companion to check driver setup."
            needsAttention = true
            return
        }
        driverText = "Running"
        guard !isBusy() else { return }
        do {
            let names = try await driver.liveTabletNames(processIdentifier: app.processIdentifier)
            guard generation == refreshGeneration, started, !sleeping else { return }
            tabletText = names.isEmpty ? "No tablet connected" : names.joined(separator: ", ")
            detail = nil
            needsAttention = false
        } catch {
            guard generation == refreshGeneration, started, !sleeping else { return }
            tabletText = "Tablet information unavailable"
            detail = error.localizedDescription
            needsAttention = true
        }
    }

    private func beginMonitoring() {
        guard started, !sleeping, monitor == nil else { return }
        monitor = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.started, !self.sleeping {
                try? await Task.sleep(for: .seconds(15), tolerance: .seconds(2))
                guard !Task.isCancelled, self.started, !self.sleeping else { break }
                await self.refresh()
            }
        }
    }
}
