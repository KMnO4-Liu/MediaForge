import Foundation
import MediaForgeCore

enum ImportMediaHints {
    /// Conservative: GIF/WebP can be static, but keeping their container avoids
    /// accidental animation loss. APNG often uses the ordinary .png extension.
    static func animationContainer(for url: URL) -> OutputFormat? {
        switch url.pathExtension.lowercased() {
        case "gif": return .gif
        case "webp": return .webp
        case "apng": return .apng
        case "png": return hasAnimationControl(url) == false ? nil : .apng
        default: return nil
        }
    }

    // nil means unknown, not static: conservatively choose APNG to avoid silent loss.
    private static func hasAnimationControl(_ url: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            guard try handle.read(upToCount: 8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
            let size = try handle.seekToEnd()
            var offset: UInt64 = 8
            // Read only chunk headers; bound metadata work on the main actor.
            for _ in 0..<2048 {
                guard offset <= size, size - offset >= 12, offset < 64 * 1024 * 1024 else { return nil }
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: 8), data.count == 8 else { return nil }
                let bytes = [UInt8](data)
                let length = bytes.prefix(4).reduce(UInt64(0)) { $0 * 256 + UInt64($1) }
                guard length <= size - offset - 12 else { return nil }
                let type = String(decoding: bytes.suffix(4), as: UTF8.self)
                if type == "acTL" { return length == 8 }
                if type == "IDAT" || type == "IEND" { return false }
                offset += length + 12
            }
        } catch { return nil }
        return nil
    }
}
