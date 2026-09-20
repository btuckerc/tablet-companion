// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WacomCompanion",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "WacomCompanion", targets: ["WacomCompanion"])],
    targets: [
        .executableTarget(
            name: "WacomCompanion",
            path: "Sources/WacomCompanion",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
