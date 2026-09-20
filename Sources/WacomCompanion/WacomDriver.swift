import AppKit
import Carbon

struct ExpressKeySnapshot: Sendable {
    let index: Int
    let summary: String
}
struct TabletSnapshot: Sendable {
    let id: String
    let name: String
    let connected: Bool
    let keys: [ExpressKeySnapshot]
    let limitation: String?
}
struct DriverSnapshot: Sendable {
    let tablets: [TabletSnapshot]
    let hasRestorePoint: Bool
    let centerAutostart: Bool
}

// Direct driver AppleEvents for discovery/save; native restore import for ExpressKeys.
// No Center automation, event interception, polling service, or added daemon.
actor WacomDriver {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Saved: Codable {
        let tabletID: String
        let before: [String: String]
        let applied: [String: String]
    }
    private let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WacomCompanion")
    private var restoreURL: URL { support.appendingPathComponent("restore.json") }
    private let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/EG27766DY7.com.wacom.WacomTabletDriver/Library/Preferences/com.wacom.wacomtablet.prefs")
    private let utility = URL(fileURLWithPath: "/Applications/Wacom Tablet.localized/Wacom Tablet Utility.app/Contents/MacOS/Wacom Tablet Utility")
    private let drawing = ["ButtonFunction": "8", "ButtonKeystrokeShortcutName": "Toggle drawing", "Keystroke": "&command;&option;&control;&vk=2:cc=64:kb=5b;"]
    private func target() -> NSAppleEventDescriptor { NSAppleEventDescriptor(bundleIdentifier: "com.wacom.wacomtablet") }
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
        let prefs = try TabletPreferences(data: Data(contentsOf: preferences))
        let n = try count("Tblt", parent: route("Drvr", index: 1))
        var tablets: [TabletSnapshot] = []
        for index in 0..<n {
            let tablet = try route("Tblt", index: index + 1)
            let id = try text("Tuid", at: tablet)
            let name = try text("pnam", at: tablet)
            let connected = try get("Cnct", type: typeBoolean, at: tablet).data.first == 1
            var keys: [ExpressKeySnapshot] = []
            var limitation: String?
            do {
                keys = try prefs.buttons(tabletID: id).enumerated().map { ExpressKeySnapshot(index: $0.offset + 1, summary: TabletPreferences.summary(TabletPreferences.assignment($0.element))) }
            } catch { limitation = error.localizedDescription }
            tablets.append(TabletSnapshot(id: id, name: name, connected: connected, keys: keys, limitation: limitation))
        }
        return DriverSnapshot(tablets: tablets, hasRestorePoint: FileManager.default.fileExists(atPath: restoreURL.path),
                              centerAutostart: try prefs.document.nodes(forXPath: "/root/WCAutoStart").first?.stringValue == "true")
    }
    func applyDrawingShortcut(tabletID: String, keyIndex: Int) async throws -> DriverSnapshot {
        guard keyIndex == 1 else { throw Failure(message: "Only the verified leftmost ExpressKey is supported.") }
        guard !FileManager.default.fileExists(atPath: restoreURL.path) else { throw Failure(message: "Restore the saved assignment before creating another restore point.") }
        let state = try snapshot()
        guard state.tablets.contains(where: { $0.id == tabletID && $0.connected && $0.limitation == nil }) else { throw Failure(message: "The selected tablet is not ready.") }
        let prefs = try TabletPreferences(data: Data(contentsOf: preferences))
        let before = TabletPreferences.assignment(try prefs.buttons(tabletID: tabletID)[0])
        guard before != drawing else { return state }
        let saved = Saved(tabletID: tabletID, before: before, applied: drawing)
        try privateWrite(JSONEncoder().encode(saved), to: restoreURL)
        try await importAssignment(tabletID: tabletID, expected: before, replacement: drawing)
        return try snapshot()
    }
    func restoreDrawingShortcut() async throws -> DriverSnapshot {
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: restoreURL))
        let pending = preferences.deletingLastPathComponent().appendingPathComponent("com.wacom.wacomtablet.restore.prefs")
        guard !FileManager.default.fileExists(atPath: pending.path) else {
            throw Failure(message: "A driver import is still pending. Restore point retained; finish the driver restart before restoring.")
        }
        try flush()
        let prefs = try TabletPreferences(data: Data(contentsOf: preferences))
        let current = TabletPreferences.assignment(try prefs.buttons(tabletID: saved.tabletID)[0])
        if current != saved.before {
            try await importAssignment(tabletID: saved.tabletID, expected: saved.applied, replacement: saved.before)
        }
        try FileManager.default.removeItem(at: restoreURL)
        return try snapshot()
    }
    private func privateWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func importAssignment(tabletID: String, expected: [String: String], replacement: [String: String]) async throws {
        try flush()
        let original = try Data(contentsOf: preferences)
        let prefs = try TabletPreferences(data: original)
        let buttons = try prefs.buttons(tabletID: tabletID)
        guard TabletPreferences.assignment(buttons[0]) == expected else { throw Failure(message: "The key changed outside Tablet Companion. Nothing was overwritten; restore data retained.") }
        let others = buttons.dropFirst().map(TabletPreferences.assignment)
        TabletPreferences.replace(replacement, in: buttons[0])
        try await importPreferences(prefs, original: original) { readback in
            let keys = try readback.buttons(tabletID: tabletID)
            return TabletPreferences.assignment(keys[0]) == replacement
                && keys.dropFirst().map(TabletPreferences.assignment) == others
        }
    }
    func setCenterAutostart(_ enabled: Bool) async throws -> DriverSnapshot {
        try flush()
        let original = try Data(contentsOf: preferences)
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
        guard try Data(contentsOf: preferences) == original else { throw Failure(message: "Wacom settings changed during preparation. Refresh and retry.") }
        try privateWrite(prefs.data, to: staged)
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
                guard try verify(TabletPreferences(data: Data(contentsOf: preferences))) else { continue }
                return
            } catch { continue }
        }
        throw Failure(message: "Driver import could not be verified. Restore data and full pre-import backup retained; do not assume the mapping changed.")
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
        NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kAECoreSuite), eventID: id,
            targetDescriptor: target(), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
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
    private func count(_ kind: String, parent: NSAppleEventDescriptor) throws -> Int {
        let request = event(AEEventID(kAECountElements))
        request.setParam(NSAppleEventDescriptor(typeCode: cc(kind)), forKeyword: AEKeyword(keyAEObjectClass))
        request.setParam(parent, forKeyword: AEKeyword(keyDirectObject))
        let n = try send(request).int32Value
        guard n >= 0 && n <= 128 else { throw Failure(message: "Invalid Wacom object count.") }
        return Int(n)
    }
    private func property(_ name: String, at route: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(kind: DescType(formPropertyID), form: DescType(formPropertyID), key: NSAppleEventDescriptor(typeCode: cc(name)), parent: route)
    }
    private func get(_ name: String, type: DescType, at route: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let request = event(AEEventID(kAEGetData))
        request.setParam(try property(name, at: route), forKeyword: AEKeyword(keyDirectObject))
        request.setParam(NSAppleEventDescriptor(typeCode: type), forKeyword: AEKeyword(keyAERequestedType))
        let result = try send(request)
        guard let coerced = result.coerce(toDescriptorType: type) else { throw Failure(message: "Wacom property \(name) has an unsupported type.") }
        return coerced
    }
    private func text(_ name: String, at route: NSAppleEventDescriptor) throws -> String {
        let data = try get(name, type: typeUTF8Text, at: route).data
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
