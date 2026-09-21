import AppKit
import Carbon

struct ExpressKeySnapshot: Sendable {
    let index: Int
    let summary: String
    let action: ExpressKeyAction?
}
struct TabletSnapshot: Sendable {
    let id: String
    let name: String
    let connected: Bool
    let keys: [ExpressKeySnapshot]
    let penButtons: [PenButtonSnapshot]
    let overlayDisabled: Bool?
    let limitation: String?
}
struct DriverSnapshot: Sendable {
    let tablets: [TabletSnapshot]
    let hasRestorePoint: Bool
    let hasPenRestorePoint: Bool
    let centerAutostart: Bool
}

enum WacomPreferencesAccessError: Error, LocalizedError, Sendable {
    case denied
    case missing

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Access to Wacom settings was denied. Allow Wacom Settings access and try again."
        case .missing:
            return "The Wacom settings file is missing. Start Wacom Tablet Driver and try again."
        }
    }

    /// Classifies Cocoa/POSIX file-access failures, including nested underlying errors.
    /// Unrelated errors return nil so callers can preserve their original failure.
    static func classify(_ error: Error) -> Self? {
        var current: Error? = error
        for _ in 0..<8 {
            guard let value = current else { return nil }
            let nsError = value as NSError
            if nsError.domain == NSCocoaErrorDomain {
                if nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError { return .denied }
                if nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError { return .missing }
            }
            if nsError.domain == NSPOSIXErrorDomain {
                if nsError.code == EACCES || nsError.code == EPERM { return .denied }
                if nsError.code == ENOENT { return .missing }
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
        }
        return nil
    }
}

// Direct driver AppleEvents for discovery/save; native restore import for ExpressKeys.
// No Center automation, event interception, polling service, or added daemon.
actor WacomDriver {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Saved: Codable {
        let tabletID: String
        var before: [[String: String]]
        var applied: [[String: String]]
        var managed: [Bool]
        var pending: [[String: String]]?
        var pendingKeys: [Bool]?

        init(tabletID: String, current: [[String: String]]) {
            self.tabletID = tabletID
            before = current; applied = current; managed = Array(repeating: false, count: current.count)
        }
        private enum CodingKeys: String, CodingKey { case tabletID, before, applied, managed, pending, pendingKeys }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tabletID = try c.decode(String.self, forKey: .tabletID)
            if let values = try? c.decode([[String: String]].self, forKey: .before) {
                before = values; applied = try c.decode([[String: String]].self, forKey: .applied)
            } else {
                before = [try c.decode([String: String].self, forKey: .before)]
                applied = [try c.decode([String: String].self, forKey: .applied)]
            }
            managed = try c.decodeIfPresent([Bool].self, forKey: .managed) ?? Array(repeating: true, count: before.count)
            pending = try c.decodeIfPresent([[String: String]].self, forKey: .pending)
            pendingKeys = try c.decodeIfPresent([Bool].self, forKey: .pendingKeys)
        }
        mutating func reconcile(current: [[String: String]]) throws {
            guard !current.isEmpty else { throw Failure(message: "No configurable buttons were discovered.") }
            if before.count == 1 && applied.count == 1 && managed.count == 1 {
                before += current.dropFirst(); applied += current.dropFirst()
                managed += Array(repeating: false, count: current.count - 1)
            }
            guard before.count == current.count, applied.count == current.count, managed.count == current.count else {
                throw Failure(message: "Restore point is invalid; no changes made.")
            }
            if let pending {
                guard pending.count == current.count, let keys = pendingKeys, keys.count == current.count else {
                    throw Failure(message: "Pending restore data is invalid.")
                }
                let changed = current.indices.filter { keys[$0] }
                if changed.allSatisfy({ current[$0] == pending[$0] }) {
                    for i in changed { applied[i] = pending[i] }
                } else if !changed.allSatisfy({ current[$0] == applied[$0] }) {
                    throw Failure(message: "An interrupted import conflicts with current ExpressKeys. Backup retained.")
                }
                self.pending = nil; pendingKeys = nil
            }
        }
        mutating func prepare(current: [[String: String]], actions: [ExpressKeyAction]) throws -> [[String: String]] {
            try prepare(current: current, replacements: actions.map(TabletPreferences.assignment(for:)))
        }
        mutating func prepare(current: [[String: String]], replacements: [[String: String]?]) throws -> [[String: String]] {
            guard replacements.count == current.count else { throw Failure(message: "The action count must match the discovered buttons.") }
            try reconcile(current: current)
            var result = current
            var keys = Array(repeating: false, count: current.count)
            for i in current.indices {
                guard let value = replacements[i] else { continue }
                guard !managed[i] || current[i] == applied[i] else {
                    throw Failure(message: "Button \(i + 1) changed outside Tablet Companion. Choose Keep current or restore the expected assignment first.")
                }
                if !managed[i] { before[i] = current[i]; applied[i] = current[i] }
                managed[i] = true; result[i] = value; keys[i] = true
            }
            pending = result; pendingKeys = keys
            return result
        }
        mutating func restoration(current: [[String: String]]) throws -> [[String: String]] {
            try reconcile(current: current)
            var result = current
            for i in current.indices where managed[i] {
                guard current[i] == applied[i] || current[i] == before[i] else {
                    throw Failure(message: "Button \(i + 1) changed outside Tablet Companion. Restore point retained.")
                }
                result[i] = before[i]
            }
            return result
        }
    }
    private struct SavedPen: Codable {
        let ids: [String]
        var layout: Saved
        let pressAndTap: Bool
    }
    private var penRestoreURL: URL { support.appendingPathComponent("pen-restore.json") }
    private let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WacomCompanion")
    private var restoreURL: URL { support.appendingPathComponent("restore.json") }
    private let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/EG27766DY7.com.wacom.WacomTabletDriver/Library/Preferences/com.wacom.wacomtablet.prefs")
    private let utility = URL(fileURLWithPath: "/Applications/Wacom Tablet.localized/Wacom Tablet Utility.app/Contents/MacOS/Wacom Tablet Utility")
    private func target() -> NSAppleEventDescriptor { NSAppleEventDescriptor(bundleIdentifier: "com.wacom.wacomtablet") }
    private func target(processIdentifier: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(processIdentifier: processIdentifier)
    }
    func permissionStatus(request: Bool) -> Int32 {
        AEDeterminePermissionToAutomateTarget(target().aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), request)
    }
    private func authorize() throws {
        guard permissionStatus(request: false) == noErr else { throw Failure(message: "Approve Wacom driver Automation access, then Recheck.") }
    }
    private func flush() throws {
        try authorize()
        let request = event(AEEventID(kAESave))
        request.setParam(try property("Tprf", at: route("Drvr", index: 1)), forKeyword: AEKeyword(keyDirectObject))
        _ = try send(request, needsValue: false)
    }
    func snapshot() throws -> DriverSnapshot {
        try flush()
        let prefs = try TabletPreferences(data: try readPreferences())
        let n = try count("Tblt", parent: route("Drvr", index: 1))
        var tablets: [TabletSnapshot] = []
        for index in 0..<n {
            let tablet = try route("Tblt", index: index + 1)
            let id = try text("Tuid", at: tablet)
            let name = try text("pnam", at: tablet)
            let connected = try get("Cnct", type: typeBoolean, at: tablet).data.first == 1
            var keys: [ExpressKeySnapshot] = []
            var penButtons: [PenButtonSnapshot] = []
            var overlayDisabled: Bool?
            var limitation: String?
            do {
                let assignments = try prefs.buttons(tabletID: id).map(TabletPreferences.assignment)
                keys = assignments.enumerated().map { ExpressKeySnapshot(index: $0.offset + 1, summary: TabletPreferences.summary($0.element), action: TabletPreferences.action($0.element)) }
                overlayDisabled = try? prefs.overlayDisabled(tabletID: id)
                penButtons = try prefs.penButtons(tabletID: id).map { button in
                    let value = TabletPreferences.assignment(button.node)
                    let click: PenButtonClick? = value["ButtonFunction"] == "2" ? .middle : value["ButtonFunction"] == "3" ? .secondary : nil
                    return PenButtonSnapshot(id: button.id, name: button.name, click: click,
                                             summary: click?.title ?? (value["ButtonFunction"] == "91" ? "Scroll" : TabletPreferences.summary(value)))
                }
            } catch { limitation = error.localizedDescription }
            tablets.append(TabletSnapshot(id: id, name: name, connected: connected, keys: keys, penButtons: penButtons, overlayDisabled: overlayDisabled, limitation: limitation))
        }
        return DriverSnapshot(tablets: tablets, hasRestorePoint: FileManager.default.fileExists(atPath: restoreURL.path),
                              hasPenRestorePoint: FileManager.default.fileExists(atPath: penRestoreURL.path),
                              centerAutostart: try prefs.document.nodes(forXPath: "/root/WCAutoStart").first?.stringValue == "true")
    }
    func applyExpressKeyLayout(tabletID: String, actions: [ExpressKeyAction]) async throws -> DriverSnapshot {
        let state = try snapshot()
        guard state.tablets.contains(where: { $0.id == tabletID && $0.connected && $0.limitation == nil }) else {
            throw Failure(message: "The selected tablet is not ready.")
        }
        let staged = preferences.deletingLastPathComponent().appendingPathComponent("com.wacom.wacomtablet.restore.prefs")
        guard !FileManager.default.fileExists(atPath: staged.path) else { throw Failure(message: "A driver import is pending; finish it before applying another layout.") }
        let original = try readPreferences()
        let prefs = try TabletPreferences(data: original)
        let buttons = try prefs.buttons(tabletID: tabletID)
        let current = buttons.map(TabletPreferences.assignment)
        guard !buttons.isEmpty, actions.count == buttons.count else { throw Failure(message: "Choose one action per discovered ExpressKey.") }
        var saved = FileManager.default.fileExists(atPath: restoreURL.path)
            ? try JSONDecoder().decode(Saved.self, from: Data(contentsOf: restoreURL))
            : Saved(tabletID: tabletID, current: current)
        guard saved.tabletID == tabletID else { throw Failure(message: "Restore the other tablet's layout before configuring this tablet.") }
        let replacement = try saved.prepare(current: current, actions: actions)
        // Journal the intended assignments before importing, so failed/readback-interrupted imports remain restorable.
        try privateWrite(JSONEncoder().encode(saved), to: restoreURL)
        if replacement != current {
            for i in current.indices where replacement[i] != current[i] { TabletPreferences.replace(replacement[i], in: buttons[i]) }
            try await importPreferences(prefs, original: original) { readback in
                try readback.buttons(tabletID: tabletID).map(TabletPreferences.assignment) == replacement
            }
        }
        try saved.reconcile(current: replacement)
        try privateWrite(JSONEncoder().encode(saved), to: restoreURL)
        return try snapshot()
    }
    func restoreExpressKeyLayout() async throws -> DriverSnapshot {
        var saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: restoreURL))
        let pending = preferences.deletingLastPathComponent().appendingPathComponent("com.wacom.wacomtablet.restore.prefs")
        guard !FileManager.default.fileExists(atPath: pending.path) else { throw Failure(message: "A driver import is still pending. Restore point retained.") }
        try flush()
        let original = try readPreferences()
        let prefs = try TabletPreferences(data: original)
        let buttons = try prefs.buttons(tabletID: saved.tabletID)
        let current = buttons.map(TabletPreferences.assignment)
        let replacement = try saved.restoration(current: current)
        if current != replacement {
            for i in current.indices where current[i] != replacement[i] { TabletPreferences.replace(replacement[i], in: buttons[i]) }
            try await importPreferences(prefs, original: original) { readback in
                try readback.buttons(tabletID: saved.tabletID).map(TabletPreferences.assignment) == replacement
            }
        }
        try FileManager.default.removeItem(at: restoreURL)
        return try snapshot()
    }
    func disableExpressKeyOverlay(tabletID: String) async throws -> DriverSnapshot {
        let state = try snapshot()
        guard state.tablets.contains(where: { $0.id == tabletID && $0.connected }) else {
            throw Failure(message: "The selected tablet is not connected.")
        }
        let original = try readPreferences()
        let prefs = try TabletPreferences(data: original)
        let keys = try prefs.buttons(tabletID: tabletID).map(TabletPreferences.assignment)
        guard try !prefs.overlayDisabled(tabletID: tabletID) else { return state }
        try prefs.setOverlayDisabled(true, tabletID: tabletID)
        try await importPreferences(prefs, original: original) {
            try $0.overlayDisabled(tabletID: tabletID)
                && $0.buttons(tabletID: tabletID).map(TabletPreferences.assignment) == keys
        }
        return try snapshot()
    }
    func applyPenButtons(tabletID: String, assignments: [String: PenButtonClick]) async throws -> DriverSnapshot {
        let state = try snapshot()
        guard state.tablets.contains(where: { $0.id == tabletID && $0.connected && $0.limitation == nil }) else {
            throw Failure(message: "The selected tablet's pen settings are not ready.")
        }
        guard assignments.values.contains(where: { $0 != .unchanged }) else { return state }
        let pending = preferences.deletingLastPathComponent().appendingPathComponent("com.wacom.wacomtablet.restore.prefs")
        guard !FileManager.default.fileExists(atPath: pending.path) else { throw Failure(message: "A driver import is still pending. Pen settings were not changed.") }
        let original = try readPreferences()
        let prefs = try TabletPreferences(data: original)
        let buttons = try prefs.penButtons(tabletID: tabletID)
        let ids = buttons.map(\.id)
        guard !ids.isEmpty, Set(assignments.keys).isSubset(of: Set(ids)) else { throw Failure(message: "The selected pen buttons are no longer available.") }
        let current = buttons.map { TabletPreferences.assignment($0.node) }
        let pressAndTap = try prefs.pressAndTap()
        var saved = FileManager.default.fileExists(atPath: penRestoreURL.path)
            ? try JSONDecoder().decode(SavedPen.self, from: Data(contentsOf: penRestoreURL))
            : SavedPen(ids: ids, layout: Saved(tabletID: tabletID, current: current), pressAndTap: pressAndTap)
        guard saved.layout.tabletID == tabletID, saved.ids == ids else {
            throw Failure(message: "Restore the previous pen setup before configuring a different pen layout.")
        }
        let replacement = try saved.layout.prepare(current: current, replacements: ids.map { assignments[$0]?.assignment })
        try prefs.setPressAndTap(false)
        try privateWrite(JSONEncoder().encode(saved), to: penRestoreURL)
        if replacement != current || pressAndTap {
            for i in current.indices where current[i] != replacement[i] { TabletPreferences.replace(replacement[i], in: buttons[i].node) }
            try await importPreferences(prefs, original: original) { readback in
                let readButtons = try readback.penButtons(tabletID: tabletID)
                let hoverEnabled = try !readback.pressAndTap()
                return readButtons.map(\.id) == ids
                    && readButtons.map { TabletPreferences.assignment($0.node) } == replacement
                    && hoverEnabled
            }
        }
        try saved.layout.reconcile(current: replacement)
        try privateWrite(JSONEncoder().encode(saved), to: penRestoreURL)
        return try snapshot()
    }
    func restorePenButtons() async throws -> DriverSnapshot {
        var saved = try JSONDecoder().decode(SavedPen.self, from: Data(contentsOf: penRestoreURL))
        let pending = preferences.deletingLastPathComponent().appendingPathComponent("com.wacom.wacomtablet.restore.prefs")
        guard !FileManager.default.fileExists(atPath: pending.path) else { throw Failure(message: "A driver import is still pending. Pen restore point retained.") }
        try flush()
        let original = try readPreferences()
        let prefs = try TabletPreferences(data: original)
        let buttons = try prefs.penButtons(tabletID: saved.layout.tabletID)
        guard buttons.map(\.id) == saved.ids else { throw Failure(message: "The saved pen layout no longer matches; nothing was changed.") }
        let current = buttons.map { TabletPreferences.assignment($0.node) }
        let replacement = try saved.layout.restoration(current: current)
        let mode = try prefs.pressAndTap()
        guard !mode || mode == saved.pressAndTap else { throw Failure(message: "Pen activation mode changed outside Companion. Restore point retained.") }
        if current != replacement || mode != saved.pressAndTap {
            for i in current.indices where current[i] != replacement[i] { TabletPreferences.replace(replacement[i], in: buttons[i].node) }
            try prefs.setPressAndTap(saved.pressAndTap)
            try await importPreferences(prefs, original: original) { readback in
                try readback.penButtons(tabletID: saved.layout.tabletID).map { TabletPreferences.assignment($0.node) } == replacement
                    && readback.pressAndTap() == saved.pressAndTap
            }
        }
        try FileManager.default.removeItem(at: penRestoreURL)
        return try snapshot()
    }
    private func readPreferences() throws -> Data {
        do {
            return try Data(contentsOf: preferences)
        } catch {
            if let accessError = WacomPreferencesAccessError.classify(error) {
                throw accessError
            }
            throw error
        }
    }

    private func writeProtectedPreferences(_ data: Data, to url: URL) throws {
        do {
            try privateWrite(data, to: url)
        } catch {
            if let accessError = WacomPreferencesAccessError.classify(error) {
                throw accessError
            }
            throw error
        }
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func setCenterAutostart(_ enabled: Bool) async throws -> DriverSnapshot {
        try flush()
        let original = try readPreferences()
        let prefs = try TabletPreferences(data: original)
        let nodes = try prefs.document.nodes(forXPath: "/root/WCAutoStart")
        guard nodes.count == 1, ["true", "false"].contains(nodes[0].stringValue ?? "") else {
            throw Failure(message: "Unrecognized Wacom Center startup preference; no changes made.")
        }
        let value = enabled ? "true" : "false"
        if nodes[0].stringValue != value {
            nodes[0].stringValue = value
            try await importPreferences(prefs, original: original) {
                try $0.document.nodes(forXPath: "/root/WCAutoStart").first?.stringValue == value
            }
        }
        return try snapshot()
    }
    private func importPreferences(_ prefs: TabletPreferences, original: Data,
                                   verify: (TabletPreferences) throws -> Bool) async throws {
        let staged = preferences.deletingLastPathComponent().appendingPathComponent("com.wacom.wacomtablet.restore.prefs")
        guard !FileManager.default.fileExists(atPath: staged.path) else { throw Failure(message: "A Wacom restore is already pending. Finish it before changing this key.") }
        try privateWrite(original, to: support.appendingPathComponent("before-last-import.xml"))
        guard try readPreferences() == original else { throw Failure(message: "Wacom settings changed during preparation. Refresh and retry.") }
        try writeProtectedPreferences(prefs.data, to: staged)
        let process = Process()
        process.executableURL = utility
        process.arguments = ["--restart"]
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        guard !process.isRunning else { process.terminate(); throw Failure(message: "Wacom restart timed out. Backup retained; check the driver before retrying.") }
        guard process.terminationStatus == 0 else { throw Failure(message: "Wacom restart failed; backup retained.") }
        // Utility exit precedes driver readiness. A successful save flushes imported active state.
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            do {
                try flush()
                guard !FileManager.default.fileExists(atPath: staged.path) else { continue }
                guard try verify(TabletPreferences(data: try readPreferences())) else { continue }
                return
            } catch let error as WacomPreferencesAccessError {
                throw error
            } catch { continue }
        }

        throw Failure(message: "Driver import could not be verified. Restore data and full pre-import backup retained; do not assume the mapping changed.")
    }
    /// Read-only tablet discovery targeted at an already-running driver process.
    /// This intentionally avoids flushing or reading the driver's preferences.
    func liveTabletNames(processIdentifier: pid_t) throws -> [String] {
        let processTarget = target(processIdentifier: processIdentifier)
        guard AEDeterminePermissionToAutomateTarget(processTarget.aeDesc, AEEventClass(kAECoreSuite),
                                                    AEEventID(kAEGetData), false) == noErr else {
            throw Failure(message: "Open Tablet Companion to allow Automation access for tablet status.")
        }
        let driver = try specifier(kind: cc("Drvr"), form: DescType(formAbsolutePosition),
                                   key: numeric(1, type: typeUInt32), parent: .null())
        let n = try count("Tblt", parent: driver, target: processTarget)
        var names: [String] = []
        for index in 0..<n {
            let tablet = try specifier(kind: cc("Tblt"), form: DescType(formAbsolutePosition),
                                       key: numeric(UInt32(index + 1), type: typeUInt32), parent: driver)
            guard try get("Cnct", type: typeBoolean, at: tablet, target: processTarget).data.first == 1 else { continue }
            names.append(try text("pnam", at: tablet, target: processTarget))
        }
        return names
    }

    private func route(_ kind: String, index: Int, parent: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        try specifier(kind: cc(kind), form: DescType(formAbsolutePosition), key: numeric(UInt32(index), type: typeUInt32), parent: parent)
    }
    private func specifier(kind: DescType, form: DescType, key: NSAppleEventDescriptor, parent: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        var result = AEDesc()
        let status = CreateObjSpecifier(kind, UnsafeMutablePointer(mutating: parent.aeDesc), form, UnsafeMutablePointer(mutating: key.aeDesc), false, &result)
        guard status == noErr else { throw Failure(message: "Cannot build Wacom object route (\(status)).") }
        return NSAppleEventDescriptor(aeDescNoCopy: &result)
    }
    private func event(_ id: AEEventID) -> NSAppleEventDescriptor {
        event(id, target: target())
    }
    private func event(_ id: AEEventID, target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kAECoreSuite), eventID: id,
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
    private func send(_ event: NSAppleEventDescriptor, needsValue: Bool = true) throws -> NSAppleEventDescriptor {
        var reply = AppleEvent()
        let status = AESendMessage(event.aeDesc, &reply, AESendMode(kAEWaitReply | kAENeverInteract), 180)
        guard status == noErr else { throw Failure(message: "Wacom driver request failed (\(status)); timeout is 3 seconds.") }
        let result = NSAppleEventDescriptor(aeDescNoCopy: &reply)
        if let error = result.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw Failure(message: "Wacom rejected the request (\(error.int32Value)). \(result.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? "")")
        }
        if let value = result.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) { return value }
        guard !needsValue else { throw Failure(message: "Wacom reply omitted its value for \(ccString(event.eventID))") }
        return .null()
    }
    private func count(_ kind: String, parent: NSAppleEventDescriptor,
                       target: NSAppleEventDescriptor? = nil) throws -> Int {
        let request = event(AEEventID(kAECountElements), target: target ?? self.target())
        request.setParam(NSAppleEventDescriptor(typeCode: cc(kind)), forKeyword: AEKeyword(keyAEObjectClass))
        request.setParam(parent, forKeyword: AEKeyword(keyDirectObject))
        let n = try send(request).int32Value
        guard n >= 0 && n <= 128 else { throw Failure(message: "Invalid Wacom object count.") }
        return Int(n)
    }
    private func property(_ name: String, at route: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(kind: DescType(formPropertyID), form: DescType(formPropertyID), key: NSAppleEventDescriptor(typeCode: cc(name)), parent: route)
    }
    private func get(_ name: String, type: DescType, at route: NSAppleEventDescriptor,
                     target: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let request = event(AEEventID(kAEGetData), target: target ?? self.target())
        request.setParam(try property(name, at: route), forKeyword: AEKeyword(keyDirectObject))
        request.setParam(NSAppleEventDescriptor(typeCode: type), forKeyword: AEKeyword(keyAERequestedType))
        let result = try send(request)
        guard let coerced = result.coerce(toDescriptorType: type) else { throw Failure(message: "Wacom property \(name) has an unsupported type.") }
        return coerced
    }
    private func text(_ name: String, at route: NSAppleEventDescriptor,
                      target: NSAppleEventDescriptor? = nil) throws -> String {
        let data = try get(name, type: typeUTF8Text, at: route, target: target).data
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw Failure(message: "Missing Wacom \(name).") }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
    private func numeric(_ value: UInt32, type: DescType) -> NSAppleEventDescriptor {
        var copy = value
        return NSAppleEventDescriptor(descriptorType: type, bytes: &copy, length: 4)!
    }
}
private func cc(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
private func ccString(_ value: UInt32) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, as: UTF8.self)
}
