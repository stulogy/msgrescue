# msgrescue

Tools for getting photos, videos and whole conversations out of an iPhone
backup, and for putting just the Messages database back onto a phone. Written
in October 2026 to recover a deleted iMessage thread and free 80 GB of
Messages attachments on an iPhone 17 running iOS 26.1. The backup is never
modified by any of these tools.

Everything works on an unencrypted Finder (or `idevicebackup2`) backup, the
folder under `~/Library/Application Support/MobileSync/Backup/<UDID>/`.

## What is here

| Tool | What it does |
|---|---|
| `msgrescue` (Swift, `Sources/`) | Pulls every photo and video out of Messages, drops the ones already in the camera roll, and clones the rest into a folder ready to upload to iCloud Photos. Writes `report.csv` and, with `--video-report`, an HTML page of every video. |
| `tools/export_thread.py` | Exports one conversation to a self-contained HTML page that looks like Messages: bubbles, day headers, tapbacks, inline images and videos, attachments cloned out of the backup. |
| `tools/build_partial.py` | Builds a Messages-only restore package (sms.db plus fresh journal files, no attachments) that `idevicebackup2` can restore onto the phone. See `docs/messages-only-restore.md`. |

Photo copies are APFS clones (`cp -c` / `COPYFILE_CLONE`), so the output
folders cost no disk space until the backup is deleted.

## msgrescue

```sh
swift build -c release
.build/release/msgrescue --backup ~/Library/Application\ Support/MobileSync/Backup/<UDID> \
    --out ~/Pictures/Rescue --video-report
```

Options:

```
--backup DIR     backup folder (default: the only backup under MobileSync)
--out DIR        output folder (default: ~/Pictures/<device name> Messages Rescue)
--threshold N    max dHash distance counted as the same photo (default 4)
--dry-run        write the report only, copy nothing
--video-report   also write an HTML page of every video in Messages
```

How it decides what to export:

1. Reads `Manifest.db` to find the camera roll (`CameraRollDomain`, including
   edited renders) and the Messages attachments (`MediaDomain`).
2. Reads `sms.db` for every attachment, its chat, sender and date.
3. Computes a perceptual hash (dHash, plus duration for videos) for each file,
   cached in `.signatures.json` so re-runs are fast.
4. Walks the attachments in date order. Each one is `in_camera_roll`,
   `duplicate` (already exported from another chat), `not_in_backup`, or
   `exported`. Unreadable files are exported anyway.
5. Exported files are named `YYYY-MM-DD HH.MM.SS <original name>` and dated to
   the message so iCloud sorts them even without EXIF.

On a real library (22k Messages attachments against a 26k camera roll) it
exported 22,249 files, skipped 4,876 already in the roll and 2,318 duplicates,
and found 1,347 referenced attachments that the backup no longer held.

The exported folder can then be triaged with the `cull` CLI from
the companion `cull` photo-triage project (`cull FOLDER --move`), which writes a review page of
screenshots, memes and junk before the upload.

## export_thread.py

```sh
python3 tools/export_thread.py <backup dir> <chat_identifier> <out dir> [me name] [them name]
```

`chat_identifier` is the phone number or Apple ID as it appears in
`sms.db`'s `chat` table (`+15551234567`, `someone@icloud.com`). All chats with
that identifier (SMS and iMessage) are merged. Output is `index.html`,
`attachments/` and `thumbs/` (JPEG thumbnails made with `sips`, 8 in
parallel). Attachments the backup no longer holds are shown as "not in
backup". Names default to "Me" and "Them".

## build_partial.py and the restore

```sh
python3 tools/build_partial.py <full backup dir> <out parent dir>
idevicebackup2 -u <UDID> restore --system --skip-apps <out parent dir>
```

Replaces the Messages database on the phone with the one from the backup,
without touching the attachments folder. The phone reboots through a short
Setup Assistant; everything else stays intact. `docs/messages-only-restore.md`
has the full recipe, the phone-side prerequisites, and the four manifest
pitfalls that each cost a reboot to find. `tools/last-successful-restore-log.txt`
is what a working run looks like.

Because the restore replaces the whole database, it is also a bulk way to
drop attachments: delete the heavy conversations on the phone, then restore
the database, and the texts come back without their media.

## Requirements

- macOS 14 or later, Xcode command line tools (for `swift build` and `sips`)
- Python 3 (standard library only)
- `brew install libimobiledevice` for the restore step
- An unencrypted backup. Encrypted backups have an encrypted `Manifest.db`.

## Caveats

- Tested on one phone, one iOS version. The `sms.db` schema and the backup
  manifest format change between iOS releases.
- `attributedBody` parsing in `export_thread.py` is a minimal scan for the
  NSString payload, enough for ordinary texts.
- The restore requires Stolen Device Protection and Find My to be off. Read
  the doc before trying it on a phone you care about.
