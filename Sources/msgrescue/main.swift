import Foundation

// msgrescue: pull the photos and videos out of an iPhone backup's Messages,
// drop the ones already in the camera roll, and copy the rest to a folder
// ready to upload to iCloud Photos. The backup itself is never modified.

struct Options {
    var backup: String?
    var out: String?
    var threshold = 4
    var dryRun = false
    var videoReport = false

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--backup": o.backup = it.next()
            case "--out": o.out = it.next()
            case "--threshold": o.threshold = Int(it.next() ?? "") ?? o.threshold
            case "--dry-run": o.dryRun = true
            case "--video-report": o.videoReport = true
            default:
                print("""
                    usage: msgrescue [--backup DIR] [--out DIR] [--threshold N] [--dry-run] [--video-report]
                      --threshold     max dHash distance counted as the same photo (default 4)
                      --dry-run       write the report only, copy nothing
                      --video-report  also write an HTML page of every video in Messages
                    """)
                exit(a == "--help" || a == "-h" ? 0 : 1)
            }
        }
        return o
    }
}

let imageExts: Set = ["heic", "heif", "jpg", "jpeg", "png", "gif", "tif", "tiff", "dng", "webp"]
let videoExts: Set = ["mov", "mp4", "m4v", "3gp"]

func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }

func run() throws {
    let opts = Options.parse(CommandLine.arguments)
    let backup = try Backup.locate(opts.backup)
    print("Backup: \(backup.deviceName)  \(backup.root.path)")

    let outRoot = URL(fileURLWithPath: ((opts.out ?? "~/Pictures/\(backup.deviceName) Messages Rescue")
        as NSString).expandingTildeInPath)
    let photosDir = outRoot.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
    let cache = SignatureCache(url: outRoot.appendingPathComponent(".signatures.json"))
    defer { try? FileManager.default.removeItem(at: Signer.linkDir) }

    // Camera roll originals, plus edited renders, since Messages sends the
    // edited version of a photo when one exists.
    let roll = try (backup.files(domain: "CameraRollDomain", pathLike: "Media/DCIM/%")
        + backup.files(domain: "CameraRollDomain", pathLike: "Media/PhotoData/Mutations/%/FullSizeRender.%"))
        .filter { imageExts.contains(ext($0.path)) || videoExts.contains(ext($0.path)) }
    print("Camera roll: \(roll.count) photos and videos")

    let attachments = try MessagesReader.attachments(in: backup)
    let mediaIDs = Dictionary(uniqueKeysWithValues:
        try backup.files(domain: "MediaDomain", pathLike: "Library/SMS/Attachments/%").map { ($0.path, $0.id) })
    print("Messages: \(attachments.count) photos and videos")

    let rollSigs = signAll(roll.map { ($0.id, videoExts.contains(ext($0.path)), ext($0.path)) },
                           backup: backup, cache: cache, label: "Hashing camera roll")
    try cache.save()

    let present = attachments.compactMap { a in mediaIDs[a.devicePath].map { (a, $0) } }
    let msgSigs = signAll(present.map { a, id in
        (id, a.isVideo, ext(a.originalName).isEmpty ? ext(a.devicePath) : ext(a.originalName))
    }, backup: backup, cache: cache, label: "Hashing Messages")
    try cache.save()

    let rollIndex = zip(roll, rollSigs).compactMap { f, s in s.map { (f.path, $0) } }

    // Walk in date order so the first copy of a photo sent around several
    // chats is the one kept.
    var report = [ReportRow]()
    var kept: [(name: String, sig: Signature)] = []
    var exportedBytes: Int64 = 0
    var videos: [VideoReport.Video] = []
    let missing = attachments.filter { mediaIDs[$0.devicePath] == nil }
    report += missing.map { ReportRow(a: $0, status: "not_in_backup") }

    for ((a, id), sig) in zip(present, msgSigs) {
        var row = ReportRow(a: a, status: "")
        if let sig, let hit = bestMatch(sig, in: rollIndex, threshold: opts.threshold) {
            row.status = "in_camera_roll"; row.match = hit.0; row.distance = hit.1
        } else if let sig, let hit = bestMatch(sig, in: kept.map { ($0.name, $0.sig) }, threshold: opts.threshold) {
            row.status = "duplicate"; row.match = hit.0; row.distance = hit.1
        } else {
            // Unreadable files are exported too: when unsure, keep it.
            row.status = sig == nil ? "exported_unverified" : "exported"
            let src = backup.url(forFileID: id)
            let name = exportName(for: a, in: photosDir)
            if !opts.dryRun { try Exporter.clone(src, to: photosDir.appendingPathComponent(name), date: a.date) }
            row.exported = name
            exportedBytes += (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int64) ?? 0
            if let sig { kept.append((name, sig)) }
        }
        report.append(row)
        if a.isVideo {
            videos.append(.init(attachment: a, fileID: id, sig: sig, exported: row.exported.isEmpty ? nil : row.exported))
        }
    }

    if opts.videoReport {
        let rollVideos = zip(roll, rollSigs).compactMap { f, s in
            s.flatMap { $0.duration == nil ? nil : VideoReport.RollVideo(path: f.path, id: f.id, sig: $0) }
        }
        let page = try VideoReport.write(videos: videos, roll: rollVideos, backup: backup,
                                         contacts: Contacts(backup: backup), photosDir: photosDir, outRoot: outRoot)
        print("Video report: \(page.path)")
    }

    let reportURL = outRoot.appendingPathComponent("report.csv")
    try ReportRow.write(report, to: reportURL)

    let counts = Dictionary(grouping: report, by: \.status).mapValues(\.count)
    print("""

        Already in camera roll:  \(counts["in_camera_roll", default: 0])
        Duplicates in Messages:  \(counts["duplicate", default: 0])
        Not in backup:           \(counts["not_in_backup", default: 0])
        Exported:                \(counts["exported", default: 0] + counts["exported_unverified", default: 0]) \
        (\(counts["exported_unverified", default: 0]) unreadable, kept to be safe), \
        \(ByteCountFormatter.string(fromByteCount: exportedBytes, countStyle: .file))
        \(opts.dryRun ? "Dry run: nothing copied." : "Folder: \(photosDir.path)")
        Report: \(reportURL.path)
        """)
}

func bestMatch(_ sig: Signature, in index: [(String, Signature)], threshold: Int) -> (String, Int)? {
    var best: (String, Int)?
    for (name, other) in index {
        if let d = sig.matches(other, threshold: threshold), d < (best?.1 ?? .max) {
            best = (name, d)
            if d == 0 { break }
        }
    }
    return best
}

var usedNames = Set<String>()

/// "2023-07-14 18.02.33 IMG_4410.HEIC", made unique within the folder.
func exportName(for a: Attachment, in dir: URL) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let clean = a.originalName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    let base = "\(f.string(from: a.date)) \((clean as NSString).deletingPathExtension)"
    let e = (clean as NSString).pathExtension.isEmpty ? ext(a.devicePath) : (clean as NSString).pathExtension
    var name = "\(base).\(e)", n = 2
    while usedNames.contains(name.lowercased()) { name = "\(base) (\(n)).\(e)"; n += 1 }
    usedNames.insert(name.lowercased())
    return name
}

do { try run() } catch {
    FileHandle.standardError.write("msgrescue: \(error)\n".data(using: .utf8)!)
    exit(1)
}
