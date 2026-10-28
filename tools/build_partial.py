#!/usr/bin/env python3
"""Build a Messages-only iOS restore package (sms.db + fresh journal files, no attachments) from a full backup.

Usage: build_partial.py <full backup dir> <out parent dir>
Writes <out parent dir>/<UDID>/ for:
    idevicebackup2 -u <UDID> restore --system --skip-apps <out parent dir>

Lessons baked in (each one cost a phone reboot on 2026-10-26):
  * Manifest.db must carry PRAGMA user_version=2 or the phone computes an empty file list.
  * Records sharing an InodeNumber are restored as hard links of one file. The journal
    placeholders need their own inode numbers or they get linked to the database itself,
    which then gets overwritten by SQLite's wal-index and Messages crash-loops.
  * The phone must receive -wal and -shm alongside sms.db, or the stale journals left on the
    phone get applied to the restored database. 32 zero bytes is below SQLite's WAL header
    size, so it reads as an empty journal; a zeroed 32 KB shm is rebuilt from it.
  * Status.plist's Date must be a real plist date.
  * Phone side: Stolen Device Protection off, then Find My iPhone off, phone unlocked and
    paired. The restore reboots the phone through a short Setup Assistant; data stays intact.
"""
import datetime, hashlib, os, plistlib, shutil, sqlite3, subprocess, sys, uuid

src, parent = sys.argv[1], sys.argv[2]
with open(os.path.join(src, "Info.plist"), "rb") as f:
    info = plistlib.load(f)
udid = info.get("Target Identifier") or info["Unique Identifier"]
dst = os.path.join(parent, udid)
if os.path.exists(dst):
    sys.exit(f"{dst} already exists")
os.makedirs(dst)

for name in ("Info.plist", "Manifest.plist"):
    shutil.copy2(os.path.join(src, name), os.path.join(dst, name))
with open(os.path.join(dst, "Status.plist"), "wb") as f:
    plistlib.dump({"BackupState": "new",
                   "Date": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
                   "IsFullBackup": False, "SnapshotState": "finished",
                   "UUID": str(uuid.uuid4()).upper(), "Version": "3.3"}, f)

sm = sqlite3.connect(f"file:{os.path.join(src,'Manifest.db')}?mode=ro", uri=True)
dm = sqlite3.connect(os.path.join(dst, "Manifest.db"))
for (sql,) in sm.execute("select sql from sqlite_master where sql is not null"):
    dm.execute(sql)
dm.executemany("insert into Properties values (?,?)", sm.execute("select * from Properties"))
dm.execute("pragma user_version=2")

DOMAIN = "HomeDomain"

def row(rel):
    r = sm.execute("select fileID, flags, file from Files where domain=? and relativePath=?", (DOMAIN, rel)).fetchone()
    if not r:
        sys.exit(f"{rel} not in source manifest")
    return r

def rewrite(blob, rel, size, digest, inode=None):
    p = plistlib.loads(blob)
    objs = p["$objects"]
    rec = next(o for o in objs if isinstance(o, dict) and "RelativePath" in o)
    objs[rec["RelativePath"]] = rel
    rec["Size"] = size
    if inode is not None:
        rec["InodeNumber"] = inode
    if "Digest" in rec:
        objs[rec["Digest"]] = digest
    else:
        objs.append(digest); rec["Digest"] = plistlib.UID(len(objs) - 1)
    return plistlib.dumps(p, fmt=plistlib.FMT_BINARY)

def put(rel, data, blob, inode=None):
    fid = hashlib.sha1(f"{DOMAIN}-{rel}".encode()).hexdigest()
    os.makedirs(os.path.join(dst, fid[:2]), exist_ok=True)
    with open(os.path.join(dst, fid[:2], fid), "wb") as f:
        f.write(data)
    dm.execute("insert into Files values (?,?,?,?,?)",
               (fid, DOMAIN, rel, 1, rewrite(blob, rel, len(data), hashlib.sha1(data).digest(), inode)))
    print(f"{rel:28} {len(data):>12,} bytes  {fid}")

# directory chain, copied as-is
for rel in ("Library", "Library/SMS"):
    fid, flags, blob = row(rel)
    dm.execute("insert into Files values (?,?,?,?,?)", (fid, DOMAIN, rel, flags, blob))

# the database, cloned out of the source backup (APFS clone: no extra disk)
fid, flags, blob = row("Library/SMS/sms.db")
srcfile = os.path.join(src, fid[:2], fid)
os.makedirs(os.path.join(dst, fid[:2]), exist_ok=True)
subprocess.run(["cp", "-c", srcfile, os.path.join(dst, fid[:2], fid)], check=True)
data = open(srcfile, "rb").read()
dm.execute("insert into Files values (?,?,?,?,?)",
           (fid, DOMAIN, "Library/SMS/sms.db", 1, rewrite(blob, "Library/SMS/sms.db", len(data), hashlib.sha1(data).digest())))
print(f"{'Library/SMS/sms.db':28} {len(data):>12,} bytes  {fid}")
chk = sqlite3.connect(f"file:{srcfile}?mode=ro", uri=True).execute("pragma integrity_check").fetchone()[0]
if chk != "ok":
    sys.exit(f"source sms.db failed integrity_check: {chk}")

# fresh journals with their own inode numbers
base = next(o for o in plistlib.loads(blob)["$objects"] if isinstance(o, dict) and "InodeNumber" in o)["InodeNumber"]
put("Library/SMS/sms.db-wal", b"\0" * 32, blob, inode=base + 1)
put("Library/SMS/sms.db-shm", b"\0" * 32768, blob, inode=base + 2)

dm.commit()
dm.execute("pragma journal_mode=wal"); dm.execute("pragma wal_checkpoint(truncate)")
print("built", dst)
print(f"next: idevicebackup2 -u {udid} restore --system --skip-apps '{parent}'")
