import AppKit
import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class DriverInstaller {
    private static let sourceURL = URL(string: "https://cdn.wacom.com/u/productsupport/drivers/mac/professional/WacomTablet_6.4.14-1.dmg")!
    private static let expectedSHA256 = "446c6889ad5602827fe1a6f597067428ffdbdd9b4e0cb00930385d99b876fb06"
    private static let signingTeamID = "EG27766DY7"

    var busy = false
    var status = "Download the driver, then open the installer."
    var error: String?
    var packageURL: URL?

    private var mountedVolumeURL: URL?
    private let fileManager = FileManager.default

    func prepare() async {
        guard !busy else { return }
        if packageURL != nil {
            status = "Ready to install."
            return
        }
        busy = true
        error = nil
        defer { busy = false }

        do {
            status = "Downloading driver…"
            let cache = try Self.cacheDirectory()
            let dmgURL = cache.appendingPathComponent("WacomTablet_6.4.14-1.dmg")
            if fileManager.fileExists(atPath: dmgURL.path), try await Self.sha256(of: dmgURL) == Self.expectedSHA256 {
                status = "Download checked."
            } else {
                let (temporaryURL, response) = try await URLSession.shared.download(from: Self.sourceURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw InstallerError.message("Wacom's driver download returned an unexpected response.")
                }
                guard try await Self.sha256(of: temporaryURL) == Self.expectedSHA256 else {
                    try? fileManager.removeItem(at: temporaryURL)
                    throw InstallerError.message("The downloaded driver failed its SHA-256 verification and was discarded.")
                }
                try? fileManager.removeItem(at: dmgURL)
                try fileManager.moveItem(at: temporaryURL, to: dmgURL)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dmgURL.path)
            }

            status = "Opening download…"
            let mount = try await Self.mount(dmgURL)
            mountedVolumeURL = mount.volume
            guard let pkg = Self.findPackage(in: mount.volume) else {
                throw InstallerError.message("The Wacom disk image did not contain an installer package.")
            }

            status = "Checking installer…"
            let signature = try await Self.runProcess(executable: "/usr/sbin/pkgutil", arguments: ["--check-signature", pkg.path], timeout: 20)
            guard signature.status == 0,
                  signature.output.contains("Developer ID Installer"),
                  signature.output.contains("Wacom Technology Corp. (\(Self.signingTeamID))") else {
                throw InstallerError.message("The installer signature could not be verified as Wacom (Developer ID Installer, team EG27766DY7).")
            }
            packageURL = pkg
            status = "Ready. Open the installer, then return here and click Refresh."
        } catch {
            if let volume = mountedVolumeURL {
                _ = try? await Self.runProcess(executable: "/usr/bin/hdiutil", arguments: ["detach", volume.path, "-force"], timeout: 20)
            }
            mountedVolumeURL = nil
            packageURL = nil
            self.error = (error as? InstallerError)?.localizedDescription ?? error.localizedDescription
            status = "Driver preparation failed."
        }
    }

    /// Opens the already verified package only in response to the user's explicit button action.
    func openInstaller() {
        guard let packageURL else {
            error = "Prepare and verify the Wacom installer before opening it."
            return
        }
        if !NSWorkspace.shared.open(packageURL) {
            error = "macOS could not open the verified Wacom installer package."
        }
    }

    private enum InstallerError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }
            return nil
        }
    }

    private struct ProcessResult: Sendable {
        let status: Int32
        let output: String
    }

    private struct MountResult: Sendable {
        let volume: URL
    }

    private static func cacheDirectory() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/WacomCompanion", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return Data(hasher.finalize()).hexString
        }.value
    }

    private static func mount(_ dmg: URL) async throws -> MountResult {
        let result = try await runProcess(executable: "/usr/bin/hdiutil", arguments: ["attach", dmg.path, "-plist", "-readonly", "-nobrowse", "-noautoopen"], timeout: 45)
        guard result.status == 0 else { throw InstallerError.message("macOS could not mount the Wacom disk image.") }
        guard let plist = result.output.data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil),
              let root = object as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw InstallerError.message("The mounted Wacom disk image had no usable volume.")
        }
        return MountResult(volume: URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func findPackage(in volume: URL) -> URL? {
        let package = volume.appendingPathComponent("Install Wacom Tablet.pkg")
        return FileManager.default.fileExists(atPath: package.path) ? package : nil
    }

    private static func runProcess(executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() >= deadline {
                    process.terminate()
                    throw InstallerError.message("The macOS installer verification command timed out.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return ProcessResult(status: process.terminationStatus, output: output)
        }.value
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
