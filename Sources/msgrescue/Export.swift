import Foundation

enum Exporter {

    /// APFS clone: the copy takes no extra disk space until one side changes.
    /// Dated to the message so iCloud sorts it sensibly if the file has no EXIF date.
    static func clone(_ src: URL, to dst: URL, date: Date) throws {
        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        guard copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            throw RescueError.message("Could not copy to \(dst.path): \(String(cString: strerror(errno)))")
        }
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: dst.path)
    }
}

struct ReportRow {
    let a: Attachment
    var status: String
    var exported = ""
    var match = ""
    var distance: Int?

    static func write(_ rows: [ReportRow], to url: URL) throws {
        let iso = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = "status,date,chat,sender,direction,original_name,type,exported_as,matched,distance\n"
        for r in rows {
            out += [r.status, iso.string(from: r.a.date), q(r.a.chat), q(r.a.sender),
                    r.a.isFromMe ? "sent" : "received", q(r.a.originalName), r.a.mimeType,
                    q(r.exported), q(r.match), r.distance.map(String.init) ?? ""]
                .joined(separator: ",") + "\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}
