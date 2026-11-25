import Foundation

/// Container metadata only: never decodes pixels or expands loop counts.
/// FFmpeg's WebP encoder averages the final delay; repair that field before publishing.
struct AnimationTiming {
    let last: Double?
    let total: Double

    static func read(_ url: URL) -> AnimationTiming? {
        guard let headerHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        let header = try? headerHandle.read(upToCount: 12)
        try? headerHandle.close()
        guard let header else { return nil }
        let b = [UInt8](header)
        let isWebP = b.count == 12 && b.starts(with: Array("RIFF".utf8)) && Array(b[8..<12]) == Array("WEBP".utf8)
        guard isWebP || b.starts(with: Array("GIF8".utf8)) || b.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        // Memory-map instead of copying input; retain only aggregate delays, never one item per frame.
        if b.starts(with: Array("RIFF".utf8)), b.count >= 12, Array(b[8..<12]) == Array("WEBP".utf8) {
            var last: Double?, total = 0.0
            _ = visitWebPFrames(data) { offset in
                let delay = Double(integer(data, offset + 20, 3, little: true)) / 1000
                last = delay; total += delay
            }
            return last == nil ? nil : AnimationTiming(last: last, total: total)
        }
        if b.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            var offset = 8, total = 0.0
            var last: Double?
            while offset + 12 <= data.count {
                let length = integer(data, offset, 4)
                guard length <= data.count - offset - 12 else { return nil }
                if data[(offset + 4)..<(offset + 8)].elementsEqual("fcTL".utf8), length == 26 {
                    let numerator = integer(data, offset + 28, 2)
                    let denominator = integer(data, offset + 30, 2)
                    let delay = Double(numerator) / Double(denominator == 0 ? 100 : denominator)
                    last = delay; total += delay
                }
                offset += length + 12
            }
            return last == nil ? nil : AnimationTiming(last: last, total: total)
        }
        if b.starts(with: Array("GIF8".utf8)), data.count >= 13 {
            var offset = 13, total = 0.0, pending = 0.1
            var last: Double?
            if data[10] & 128 != 0 { offset += 3 * (1 << (Int(data[10] & 7) + 1)) }
            func skipBlocks(_ start: Int) -> Int? {
                var p = start
                while p < data.count {
                    let size = Int(data[p]); p += 1
                    if size == 0 { return p }
                    guard size <= data.count - p else { return nil }; p += size
                }
                return nil
            }
            while offset < data.count {
                let marker = data[offset]; offset += 1
                if marker == 0x3b { break }
                if marker == 0x21 {
                    guard offset < data.count else { return nil }
                    let label = data[offset]; offset += 1
                    if label == 0xf9, offset + 6 <= data.count, data[offset] == 4 {
                        pending = Double(integer(data, offset + 2, 2, little: true)) / 100
                    }
                    guard let next = skipBlocks(offset) else { return nil }; offset = next
                } else if marker == 0x2c {
                    guard offset + 9 <= data.count else { return nil }
                    let packed = data[offset + 8]; offset += 9
                    if packed & 128 != 0 { offset += 3 * (1 << (Int(packed & 7) + 1)) }
                    guard offset < data.count, let next = skipBlocks(offset + 1) else { return nil }
                    offset = next; last = pending; total += pending; pending = 0.1
                } else { return nil }
            }
            return last == nil ? nil : AnimationTiming(last: last, total: total)
        }
        return nil
    }

    static func repairWebPDuration(_ url: URL, totalDuration: Double) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var total = 0.0, last = 0.0
        guard let offset = visitWebPFrames(data, visit: { offset in
            last = Double(integer(data, offset + 20, 3, little: true)) / 1000
            total += last
        }) else { return } // Static WebP has no ANMF.
        // libwebp may coalesce identical frames; preserve the full cycle, not merely source's last delay.
        let seconds = totalDuration - (total - last)
        guard seconds.isFinite, seconds > 0, seconds * 1000 <= 16_777_215 else {
            throw ConversionError.invalidOptions("WebP 无法表示此动画末帧时长。")
        }
        let value = Int((seconds * 1000).rounded())
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset + 20))
        try handle.write(contentsOf: Data([UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255)]))
    }
    private static func visitWebPFrames(_ data: Data, visit: (Int) -> Void) -> Int? {
        var offset = 12, last: Int?
        while offset + 8 <= data.count {
            let length = integer(data, offset + 4, 4, little: true)
            guard length <= data.count - offset - 8 else { return nil }
            if length >= 16, data[offset..<(offset + 4)].elementsEqual("ANMF".utf8) { last = offset; visit(offset) }
            offset += 8 + length + (length & 1)
        }
        return last
    }
    private static func integer(_ data: Data, _ start: Int, _ count: Int, little: Bool = false) -> Int {
        guard start >= 0, start + count <= data.count else { return 0 }
        var value = 0
        for index in 0..<count { value = value * 256 + Int(data[start + (little ? count - index - 1 : index)]) }
        return value
    }
}
