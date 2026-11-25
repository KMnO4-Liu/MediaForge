import Foundation
import MediaForgeCore

/// App bundles never depend on a shell PATH or Homebrew installation.
/// Explicit user overrides remain available for advanced users.
enum EngineLocator {
    static var helpersDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    static func resolve(customFFmpeg: URL? = nil) throws -> Toolchain {
        if let customFFmpeg { return try Toolchain.discover(customFFmpeg: customFFmpeg) }
        if Bundle.main.bundleURL.pathExtension == "app" {
            let executable = helpersDirectory.appendingPathComponent("ffmpeg")
            _ = try Toolchain.discover(customFFmpeg: executable)
            let probe = helpersDirectory.appendingPathComponent("ffprobe")
            guard FileManager.default.isExecutableFile(atPath: probe.path) else { throw ConversionError.invalidTool(probe) }
            return Toolchain(ffmpeg: executable, ffprobe: probe)
        }
        // `swift run` development convenience only; a packaged app never reaches this branch.
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tools/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: local.path) { return try Toolchain.discover(customFFmpeg: local) }
        return try Toolchain.discover()
    }

    static func isBundled(_ toolchain: Toolchain) -> Bool {
        toolchain.ffmpeg.standardizedFileURL == helpersDirectory.appendingPathComponent("ffmpeg").standardizedFileURL
    }
}
