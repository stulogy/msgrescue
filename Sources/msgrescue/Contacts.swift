import Foundation

/// Names from the phone's address book, so reports show people instead of
/// phone numbers.
struct Contacts {
    private var names: [String: String] = [:]

    init(backup: Backup) {
        guard let id = try? backup.fileID(domain: "HomeDomain", path: "Library/AddressBook/AddressBook.sqlitedb"),
              let db = try? SQLiteDB(readOnly: backup.url(forFileID: id)) else { return }
        // Property 3 is a phone number, 4 an email address.
        try? db.rows("""
            SELECT v.value, p.First, p.Last, p.Organization
            FROM ABMultiValue v JOIN ABPerson p ON p.ROWID = v.record_id
            WHERE v.property IN (3, 4) AND v.value IS NOT NULL
            """) { row in
            let name = [row.string(1), row.string(2)].compactMap { $0 }.joined(separator: " ")
            let display = name.isEmpty ? (row.string(3) ?? "") : name
            if !display.isEmpty, let key = Contacts.key(row.string(0) ?? "") { names[key] = display }
        }
    }

    /// Emails compare case-insensitively, phone numbers on their last ten digits.
    private static func key(_ handle: String) -> String? {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return digits.count >= 7 ? String(digits.suffix(10)) : nil
    }

    /// A group chat's name, or the person it is with.
    func name(for handle: String) -> String {
        guard !handle.isEmpty else { return "" }
        if let key = Contacts.key(handle), let name = names[key] { return name }
        return handle
    }
}
