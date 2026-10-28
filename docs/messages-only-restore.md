# Messages-only restore to an iPhone

Verified on an iPhone 17 running iOS 26.1 with libimobiledevice 1.4.0 (brew). Script: tools/build_partial.py <backup dir> <out dir>, then `idevicebackup2 -u <UDID> restore --system --skip-apps <out dir>`. Success looks like three data "Sending" lines (sms.db ~816 MB, 32 KB, 32 B) and the phone log line "Starting to restore 3 files". The phone reboots through a short Setup Assistant each time; data stays intact; re-pair with `idevicepair pair` afterward. Phone needs Stolen Device Protection off, then Find My iPhone off (error 211 otherwise), unlocked and plugged in.

Pitfalls found the hard way:
1. Manifest.db must have `PRAGMA user_version=2`; with 0 the phone "migrates" it and restores zero files while still saying Restore Successful.
2. Records with the same InodeNumber are restored as hard links of one file. Placeholder -wal/-shm records copied from sms.db's record got linked to the database, SQLite wrote its wal-index into it, IMDPersistenceAgent segfaulted in integrity_check, Messages showed a black screen.
3. -wal and -shm must be shipped (32 zero bytes and 32 KB zeros, unique inodes) so stale journals on the phone can't be applied to the restored database.
4. Status.plist Date must be a real plist date (error 205 otherwise).

Diagnostics: `idevicesyslog -u <UDID>` during the run, grep BackupAgent2 for "Enqueued batches"; `idevicecrashreport -k -e <dir>` pulls .ips crash files. The restore replaces the whole Messages database (all conversations); it can't inject one thread. It never touches the attachments folder, so deleting conversations on the phone first and then restoring the database is a bulk way to drop attachments while keeping texts.

