import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What two copies of the same photo or video have in common after Messages
/// has recompressed, resized or converted one of them.
struct Signature: Codable {
    var hash: UInt64
    var duration: Double?       // Videos only.

    func matches(_ other: Signature, threshold: Int) -> Int? {
        if let a = duration, let b = other.duration {
            guard abs(a - b) <= 0.6 else { return nil }
        } else if (duration == nil) != (other.duration == nil) {
            return nil
        }
        let d = (hash ^ other.hash).nonzeroBitCount
        return d <= threshold ? d : nil
    }
}

enum Signer {

    private static let side = 256

    /// Backup files have no extension, so AVFoundation needs a named link to
    /// tell what it is opening. ImageIO sniffs content and does not.
    static let linkDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("msgrescue-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func signature(of url: URL, isVideo: Bool, ext: String) -> Signature? {
        isVideo ? videoSignature(url, ext: ext) : imageSignature(url)
    }

    private static func imageSignature(_ url: URL) -> Signature? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let gray = grayscale(cg) else { return nil }
        return Signature(hash: dHash(gray))
    }

    private static func videoSignature(_ url: URL, ext: String) -> Signature? {
        let link = linkDir.appendingPathComponent(UUID().uuidString + "." + ext)
        guard (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(at: link) }

        let asset = AVURLAsset(url: link)
        return blocking { () async throws -> Signature in
            let duration = try await asset.load(.duration).seconds
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: side, height: side)
            // Exact frame, so both copies are sampled at the same moment even
            // when their keyframes fall in different places.
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            let at = CMTime(seconds: min(1.0, duration / 2), preferredTimescale: 600)
            let (cg, _) = try await gen.image(at: at)
            guard let gray = grayscale(cg) else { throw RescueError.message("frame") }
            return Signature(hash: dHash(gray), duration: duration)
        }
    }

    /// A JPEG still from about a second in, for the video report.
    static func writePoster(of url: URL, ext: String, to dst: URL) {
        if FileManager.default.fileExists(atPath: dst.path) { return }
        let link = linkDir.appendingPathComponent(UUID().uuidString + "." + ext)
        guard (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)) != nil
        else { return }
        defer { try? FileManager.default.removeItem(at: link) }

        let asset = AVURLAsset(url: link)
        let cg = blocking { () async throws -> CGImage in
            let duration = try await asset.load(.duration).seconds
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 480)
            return try await gen.image(at: CMTime(seconds: min(1.0, duration / 2), preferredTimescale: 600)).image
        }
        guard let cg, let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    /// Hashing runs on GCD worker threads, so waiting here never blocks the
    /// Swift concurrency pool the async AVFoundation calls run on.
    private static func blocking<T>(_ op: @escaping () async throws -> T) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = try? await op()
            done.signal()
        }
        done.wait()
        return box.value
    }

    // MARK: - Pixels (same approach as Cull's ImageSignals)

    private static func grayscale(_ cg: CGImage) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: side * side)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? buffer : nil
    }

    /// Difference hash: box-downsample to 9x8, then compare horizontal neighbors.
    private static func dHash(_ p: [UInt8]) -> UInt64 {
        let w = 9, h = 8
        var small = [Double](repeating: 0, count: w * h)
        let cellW = Double(side) / Double(w), cellH = Double(side) / Double(h)
        for gy in 0..<h {
            let y0 = Int(Double(gy) * cellH), y1 = max(y0 + 1, Int(Double(gy + 1) * cellH))
            for gx in 0..<w {
                let x0 = Int(Double(gx) * cellW), x1 = max(x0 + 1, Int(Double(gx + 1) * cellW))
                var total = 0.0, count = 0
                for y in y0..<min(y1, side) {
                    for x in x0..<min(x1, side) { total += Double(p[y * side + x]); count += 1 }
                }
                small[gy * w + gx] = count > 0 ? total / Double(count) : 0
            }
        }
        var bits: UInt64 = 0, bit = 0
        for gy in 0..<h {
            for gx in 0..<(w - 1) {
                if small[gy * w + gx] < small[gy * w + gx + 1] { bits |= 1 << UInt64(bit) }
                bit += 1
            }
        }
        return bits
    }
}

/// Signatures keyed by backup fileID, saved beside the output so a rerun with
/// a different threshold skips the slow decoding.
final class SignatureCache {
    private let url: URL
    private var store: [String: Signature]
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        store = (try? JSONDecoder().decode([String: Signature].self, from: Data(contentsOf: url))) ?? [:]
    }

    func get(_ id: String) -> Signature? { lock.withLock { store[id] } }
    func set(_ id: String, _ sig: Signature) { lock.withLock { store[id] = sig } }
    func save() throws { try lock.withLock { try JSONEncoder().encode(store).write(to: url) } }
}

/// Hash many backup files in parallel, printing progress as it goes.
func signAll(_ items: [(id: String, isVideo: Bool, ext: String)], backup: Backup,
             cache: SignatureCache, label: String) -> [Signature?] {
    var results = [Signature?](repeating: nil, count: items.count)
    let lock = NSLock()
    var done = 0
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        let item = items[i]
        let sig = cache.get(item.id) ?? {
            let s = Signer.signature(of: backup.url(forFileID: item.id), isVideo: item.isVideo, ext: item.ext)
            if let s { cache.set(item.id, s) }
            return s
        }()
        lock.withLock {
            results[i] = sig
            done += 1
            if done % 500 == 0 || done == items.count {
                FileHandle.standardError.write("\r\(label): \(done)/\(items.count)".data(using: .utf8)!)
            }
        }
    }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    return results
}
