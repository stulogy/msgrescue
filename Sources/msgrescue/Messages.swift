import Foundation

/// One photo or video attached to a message.
struct Attachment {
    let rowID: Int64
    let devicePath: String      // Relative to the MediaDomain root.
    let originalName: String
    let mimeType: String
    let date: Date
    let isFromMe: Bool
    let sender: String          // Phone number or email, empty when sent by her.
    let chat: String            // Group name, or the other party's handle.

    var isVideo: Bool { mimeType.hasPrefix("video/") }
}

enum MessagesReader {

    static func attachments(in backup: Backup) throws -> [Attachment] {
        guard let smsID = try backup.fileID(domain: "HomeDomain", path: "Library/SMS/sms.db") else {
            throw RescueError.message("This backup has no Messages database.")
        }
        let db = try SQLiteDB(readOnly: backup.url(forFileID: smsID))

        // Stickers, Genmoji and hidden link-preview images are not photos
        // anyone took, so they never leave the backup.
        var out: [Attachment] = []
        try db.rows("""
            SELECT a.ROWID, a.filename, a.transfer_name, a.mime_type, a.created_date,
                   m.date, m.is_from_me, h.id, c.display_name, c.chat_identifier
            FROM attachment a
            LEFT JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            LEFT JOIN message m ON m.ROWID = maj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE a.is_sticker = 0 AND a.hide_attachment = 0
              AND a.emoji_image_content_identifier IS NULL
              AND (a.mime_type LIKE 'image/%' OR a.mime_type LIKE 'video/%')
            GROUP BY a.ROWID
            ORDER BY m.date
            """) { row in
            guard let filename = row.string(1), let path = devicePath(filename) else { return }
            let date = row.isNull(5)
                ? Date(timeIntervalSinceReferenceDate: Double(row.int(4)))
                : appleDate(row.int(5))
            let displayName = row.string(8) ?? ""
            out.append(Attachment(
                rowID: row.int(0),
                devicePath: path,
                originalName: row.string(2) ?? (path as NSString).lastPathComponent,
                mimeType: row.string(3) ?? "",
                date: date,
                isFromMe: row.int(6) == 1,
                sender: row.string(7) ?? "",
                chat: displayName.isEmpty ? (row.string(9) ?? "") : displayName))
        }
        return out
    }

    /// sms.db stores "~/Library/SMS/..." or "/var/mobile/Library/SMS/...";
    /// the manifest wants the path relative to the home directory.
    private static func devicePath(_ filename: String) -> String? {
        for prefix in ["~/", "/var/mobile/", "/private/var/mobile/"] where filename.hasPrefix(prefix) {
            return String(filename.dropFirst(prefix.count))
        }
        return nil
    }

    /// Message dates are seconds since 2001 on old databases, nanoseconds on new ones.
    private static func appleDate(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
