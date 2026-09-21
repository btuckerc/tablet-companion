import Foundation

enum ExpressKeyAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case annotate, color, strokeWidth, clear, unchanged
    var title: String {
        switch self {
        case .annotate: return "Annotate"
        case .color: return "Color"
        case .strokeWidth: return "Stroke width"
        case .clear: return "Clear"
        case .unchanged: return "Keep current"
        }
    }
    var id: String { rawValue }
    static let defaultLayout: [ExpressKeyAction] = [.annotate, .color, .strokeWidth, .clear]
}

enum PenButtonClick: String, CaseIterable, Codable, Sendable, Identifiable {
    case unchanged, middle, secondary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unchanged: return "Keep current"
        case .middle: return "Middle click"
        case .secondary: return "Secondary click"
        }
    }
    var assignment: [String: String]? {
        switch self {
        case .unchanged: return nil
        case .middle: return ["ButtonFunction": "2"]
        case .secondary: return ["ButtonFunction": "3"]
        }
    }
}

struct PenButtonSnapshot: Identifiable, Sendable {
    let id: String
    let name: String
    let click: PenButtonClick?
    let summary: String
}

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
        let tablet = try tablet(tabletID: tabletID)
        let containers = try tablet.nodes(forXPath: "TabletControlContainerArray/ArrayElement[ApplicationAssociated='0' and WorkflowAssociated='0']")
        guard containers.count <= 1 else { throw WacomDriver.Failure(message: "Global ExpressKey settings are ambiguous.") }
        guard let container = containers.first else { return [] }
        let keys = try container.nodes(forXPath: "TabletControlsButtonsArray/ArrayElement").compactMap { $0 as? XMLElement }
        let names = keys.compactMap { $0.elements(forName: "ButtonName").first?.stringValue }
        guard names.count == keys.count, Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty }),
              keys.allSatisfy(Self.validButton) else {
            throw WacomDriver.Failure(message: "Unrecognized ExpressKey settings; no changes made.")
        }
        return keys
    }
    private func tablet(tabletID: String) throws -> XMLElement {
        let tablets = try document.nodes(forXPath: "/root/TabletArray/ArrayElement").compactMap { $0 as? XMLElement }
        let matches = tablets.filter { $0.elements(forName: "TabletCommInterface").first?.elements(forName: "BTDeviceAddress").first?.stringValue == tabletID }
        guard !tabletID.isEmpty, matches.count == 1, let tablet = matches.first else {
            throw WacomDriver.Failure(message: "The driver identity cannot be uniquely matched to saved settings. Use your driver's setup controls; no changes made.")
        }
        return tablet
    }
    private static func validButton(_ button: XMLElement) -> Bool {
        button.elements(forName: "ButtonFunction").count == 1
            && ["Modifier", "Keystroke", "ButtonKeystrokeShortcutName"].allSatisfy { button.elements(forName: $0).count <= 1 }
    }
    func penButtons(tabletID: String) throws -> [(id: String, name: String, node: XMLElement)] {
        let pens = try tablet(tabletID: tabletID).nodes(forXPath: "TabletTransducerArray/ArrayElement[ApplicationAssociated='0' and WorkflowAssociated='0']").compactMap { $0 as? XMLElement }
        var result: [(id: String, name: String, node: XMLElement)] = []
        for pen in pens {
            guard let identity = pen.elements(forName: "TransducerName").first?.stringValue, !identity.isEmpty else {
                throw WacomDriver.Failure(message: "Pen identity is missing; no pen settings changed.")
            }
            let label = pen.elements(forName: "DefaultTransName").first?.stringValue ?? identity
            let candidates = (pen.children ?? []).compactMap { $0 as? XMLElement }.filter {
                ($0.name?.hasSuffix("ButtonSettings") ?? false)
                    && $0.name != "TransducerTipButtonSettings" && $0.name != "TransducerEraserButtonSettings"
            }
            for node in candidates {
                guard let name = node.elements(forName: "ButtonName").first?.stringValue,
                      !["tip", "eraser"].contains(name), Self.validButton(node) else {
                    throw WacomDriver.Failure(message: "Pen button settings are ambiguous; no changes made.")
                }
                let position: String
                switch node.name {
                case "TransducerLowerButtonSettings": position = "Lower pen button"
                case "TransducerUpperButtonSettings": position = "Upper pen button"
                default: position = name
                }
                result.append((identity + "/" + node.name!, pens.count > 1 ? "\(label): \(position)" : position, node))
            }
        }
        guard Set(result.map(\.id)).count == result.count else { throw WacomDriver.Failure(message: "Pen button identities are not unique.") }
        return result
    }
    func pressAndTap() throws -> Bool {
        let nodes = try document.nodes(forXPath: "/root/SideSwitchPressAndTap")
        guard nodes.count == 1, ["true", "false"].contains(nodes[0].stringValue ?? "") else {
            throw WacomDriver.Failure(message: "The driver does not expose a recognized pen hover-click mode.")
        }
        return nodes[0].stringValue == "true"
    }
    func setPressAndTap(_ enabled: Bool) throws {
        _ = try pressAndTap()
        try document.nodes(forXPath: "/root/SideSwitchPressAndTap")[0].stringValue = enabled ? "true" : "false"
    }
    func overlayDisabled(tabletID: String) throws -> Bool {
        let nodes = try tablet(tabletID: tabletID).nodes(forXPath: ".//ExpressKeysShowButtonHUD")
        guard nodes.count == 1, ["true", "false"].contains(nodes[0].stringValue ?? "") else { throw WacomDriver.Failure(message: "ExpressKeysShowButtonHUD is missing or ambiguous; no changes made.") }
        return nodes[0].stringValue == "false"
    }
    func setOverlayDisabled(_ disabled: Bool, tabletID: String) throws {
        let nodes = try tablet(tabletID: tabletID).nodes(forXPath: ".//ExpressKeysShowButtonHUD")
        guard nodes.count == 1, ["true", "false"].contains(nodes[0].stringValue ?? "") else { throw WacomDriver.Failure(message: "ExpressKeysShowButtonHUD is missing or ambiguous; no changes made.") }
        nodes[0].stringValue = disabled ? "false" : "true"
    }
    static func assignment(_ button: XMLElement) -> [String: String] {
        Dictionary(uniqueKeysWithValues: button.elements(forName: "ButtonFunction").map { ($0.name!, $0.stringValue ?? "") } +
            ["Modifier", "Keystroke", "ButtonKeystrokeShortcutName"].compactMap { name in button.elements(forName: name).first.map { (name, $0.stringValue ?? "") } })
    }
    static func replace(_ assignment: [String: String], in button: XMLElement) {
        for name in ["ButtonFunction", "Modifier", "Keystroke", "ButtonKeystrokeShortcutName"] {
            for node in button.elements(forName: name) { node.detach() }
            guard let value = assignment[name] else { continue }
            let node = XMLElement(name: name)
            node.addAttribute(XMLNode.attribute(withName: "type", stringValue: name == "ButtonFunction" ? "integer" : (["Modifier", "Keystroke"].contains(name) ? "kestring" : "string")) as! XMLNode)
            if ["Modifier", "Keystroke"].contains(name) {
                let text = XMLNode(kind: .text, options: .nodeIsCDATA); text.stringValue = value; node.addChild(text)
            } else { node.stringValue = value }
            button.addChild(node)
        }
    }
    static func action(_ assignment: [String: String]) -> ExpressKeyAction? {
        guard assignment["ButtonFunction"] == "8", let key = assignment["Keystroke"] else { return nil }
        switch key {
        case "&command;&option;&control;&vk=2:cc=64:kb=5b;": return .annotate
        case "&command;&option;&control;&vk=8:cc=63:kb=5b;": return .color
        case "&command;&option;&control;&vk=d:cc=77:kb=5b;": return .strokeWidth
        case "&command;&option;&control;&vk=7:cc=78:kb=5b;": return .clear
        default: return nil
        }
    }
    var data: Data { document.xmlData(options: [.nodePreserveAll]) }
    static func assignment(for action: ExpressKeyAction) -> [String: String]? {
        switch action {
        case .annotate: return ["ButtonFunction":"8", "ButtonKeystrokeShortcutName":"Annotate", "Keystroke":"&command;&option;&control;&vk=2:cc=64:kb=5b;"]
        case .color: return ["ButtonFunction":"8", "ButtonKeystrokeShortcutName":"Color", "Keystroke":"&command;&option;&control;&vk=8:cc=63:kb=5b;"]
        case .strokeWidth: return ["ButtonFunction":"8", "ButtonKeystrokeShortcutName":"Stroke width", "Keystroke":"&command;&option;&control;&vk=d:cc=77:kb=5b;"]
        case .clear: return ["ButtonFunction":"8", "ButtonKeystrokeShortcutName":"Clear", "Keystroke":"&command;&option;&control;&vk=7:cc=78:kb=5b;"]
        case .unchanged: return nil
        }
    }
    static func summary(_ value: [String: String]) -> String {
        if let action = action(value) { return action.title }
        if value["ButtonFunction"] == "9" { return (value["Modifier"] ?? "").replacingOccurrences(of: "&shift;", with: "Shift").replacingOccurrences(of: "&option;", with: "Option").replacingOccurrences(of: "&control;", with: "Control").replacingOccurrences(of: "&command;", with: "Command") }
        return value["ButtonKeystrokeShortcutName"] ?? "Function \(value["ButtonFunction"] ?? "unknown")"
    }
}
