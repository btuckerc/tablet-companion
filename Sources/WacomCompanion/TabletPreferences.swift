import Foundation

// Preserve CDATA: Wacom's typed XML uses kestring values, not plist strings.
struct TabletPreferences {
    let document: XMLDocument
    init(data: Data) throws {
        document = try XMLDocument(data: data, options: [.nodePreserveAll])
        guard document.rootElement()?.elements(forName: "ImportFileVersion").first?.stringValue == "6" else {
            throw WacomDriver.Failure(message: "Unsupported Wacom preference format; no changes made.")
        }
    }
    func buttons(tabletID: String) throws -> [XMLElement] {
        let tablets = try document.nodes(forXPath: "/root/TabletArray/ArrayElement").compactMap { $0 as? XMLElement }
        let matches = tablets.filter {
            $0.elements(forName: "TabletCommInterface").first?.elements(forName: "BTDeviceAddress").first?.stringValue == tabletID
        }
        guard matches.count == 1, let tablet = matches.first,
              tablet.elements(forName: "DefaultTabName").first?.stringValue == "Intuos BT S" else {
            throw WacomDriver.Failure(message: "Cannot uniquely match the connected Intuos BT S to its saved settings.")
        }
        let containers = try tablet.nodes(forXPath: "TabletControlContainerArray/ArrayElement[ApplicationAssociated='0' and WorkflowAssociated='0']")
        guard containers.count == 1 else { throw WacomDriver.Failure(message: "Global ExpressKey settings are ambiguous.") }
        let keys = try containers[0].nodes(forXPath: "TabletControlsButtonsArray/ArrayElement").compactMap { $0 as? XMLElement }
        guard keys.count == 4, keys.enumerated().allSatisfy({ $0.element.elements(forName: "ButtonName").first?.stringValue == "Button\($0.offset + 1)" }) else {
            throw WacomDriver.Failure(message: "Unrecognized ExpressKey layout; no changes made.")
        }
        return keys
    }
    static func assignment(_ button: XMLElement) -> [String: String] {
        Dictionary(uniqueKeysWithValues: button.elements(forName: "ButtonFunction").map { ($0.name!, $0.stringValue ?? "") }
            + ["Modifier", "Keystroke", "ButtonKeystrokeShortcutName"].compactMap { name in
                button.elements(forName: name).first.map { (name, $0.stringValue ?? "") }
            })
    }
    static func replace(_ assignment: [String: String], in button: XMLElement) {
        for name in ["ButtonFunction", "Modifier", "Keystroke", "ButtonKeystrokeShortcutName"] {
            for node in button.elements(forName: name) { node.detach() }
            guard let value = assignment[name] else { continue }
            let node = XMLElement(name: name)
            node.addAttribute(XMLNode.attribute(withName: "type", stringValue: name == "ButtonFunction" ? "integer" : (["Modifier", "Keystroke"].contains(name) ? "kestring" : "string")) as! XMLNode)
            if ["Modifier", "Keystroke"].contains(name) {
                let text = XMLNode(kind: .text, options: .nodeIsCDATA)
                text.stringValue = value
                node.addChild(text)
            } else { node.stringValue = value }
            button.addChild(node)
        }
    }
    var data: Data { document.xmlData(options: [.nodePreserveAll]) }
    static func summary(_ value: [String: String]) -> String {
        if value["ButtonFunction"] == "8", value["Keystroke"] == "&command;&option;&control;&vk=2:cc=64:kb=5b;" { return "⌃⌥⌘D — Toggle drawing" }
        if value["ButtonFunction"] == "9" {
            return (value["Modifier"] ?? "").replacingOccurrences(of: "&shift;", with: "Shift").replacingOccurrences(of: "&option;", with: "Option").replacingOccurrences(of: "&control;", with: "Control").replacingOccurrences(of: "&command;", with: "Command")
        }
        return value["ButtonKeystrokeShortcutName"] ?? "Function \(value["ButtonFunction"] ?? "unknown")"
    }
}
