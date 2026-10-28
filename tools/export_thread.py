#!/usr/bin/env python3
"""Export one Messages conversation from an iOS backup to a static HTML page.

Usage: export_thread.py <backup dir> <chat_identifier> <out dir> [me name] [them name]
"me" is the owner of the backup (default "Me"), "them" the other party (default "Them").
Attachments are APFS-cloned out of the backup (no extra disk), images get JPEG thumbnails.
"""
import html, os, sqlite3, subprocess, sys
from collections import defaultdict
from datetime import datetime, timezone

backup, ident, out = sys.argv[1], sys.argv[2], sys.argv[3]
ME = sys.argv[4] if len(sys.argv) > 4 else "Me"
THEM = sys.argv[5] if len(sys.argv) > 5 else "Them"
TITLE = f"{ME} and {THEM}"
att_dir, thumb_dir = os.path.join(out, "attachments"), os.path.join(out, "thumbs")
os.makedirs(att_dir, exist_ok=True); os.makedirs(thumb_dir, exist_ok=True)

man = sqlite3.connect(f"file:{os.path.join(backup,'Manifest.db')}?mode=ro", uri=True)
sms_id = man.execute("select fileID from Files where domain='HomeDomain' and relativePath='Library/SMS/sms.db'").fetchone()[0]
db = sqlite3.connect(f"file:{os.path.join(backup, sms_id[:2], sms_id)}?mode=ro", uri=True)
db.row_factory = sqlite3.Row

paths = {r[0]: r[1] for r in man.execute(
    "select relativePath, fileID from Files where domain='MediaDomain' and relativePath like 'Library/SMS/Attachments/%' and flags=1")}

chat_ids = [r[0] for r in db.execute("select ROWID from chat where chat_identifier=?", (ident,))]
q = ",".join("?" * len(chat_ids))

def ts(ns):
    return datetime.fromtimestamp(ns / 1e9 + 978307200, tz=timezone.utc).astimezone()

def body_text(row):
    if row["text"]:
        return row["text"]
    blob = row["attributedBody"]
    if not blob:
        return ""
    i = blob.find(b"NSString")
    if i < 0:
        return ""
    i = blob.find(b"+", i)
    if i < 0:
        return ""
    i += 1
    ln = blob[i]
    if ln == 0x81:
        ln = int.from_bytes(blob[i + 1:i + 3], "little"); i += 3
    else:
        i += 1
    return blob[i:i + ln].decode("utf-8", "replace")

atts = defaultdict(list)
for a in db.execute(f"""select maj.message_id mid, a.ROWID aid, a.filename, a.mime_type, a.total_bytes, a.transfer_name
    from attachment a join message_attachment_join maj on maj.attachment_id=a.ROWID
    join chat_message_join j on j.message_id=maj.message_id where j.chat_id in ({q})""", chat_ids):
    atts[a["mid"]].append(dict(a))

# clone attachments out of the backup
missing, copied, thumbs = 0, 0, []
for mid, lst in atts.items():
    for a in lst:
        rel = (a["filename"] or "").replace("~/", "", 1)
        fid = paths.get(rel)
        a["href"] = None
        if not fid:
            missing += 1; continue
        src = os.path.join(backup, fid[:2], fid)
        name = f"{a['aid']}_{os.path.basename(rel)}"
        dst = os.path.join(att_dir, name)
        if not os.path.exists(dst):
            subprocess.run(["cp", "-c", src, dst], check=True)
        copied += 1
        a["href"] = "attachments/" + name
        mt = a["mime_type"] or ""
        ext = os.path.splitext(name)[1].lower()
        if mt.startswith("image/") and ext not in (".gif",):
            tn = os.path.splitext(name)[0] + ".jpg"
            a["thumb"] = "thumbs/" + tn
            thumbs.append((dst, os.path.join(thumb_dir, tn)))

# thumbnails in parallel via sips
with open(os.path.join(out, "thumbs.txt"), "w") as f:
    for s, d in thumbs:
        if not os.path.exists(d):
            f.write(f"{s}\0{d}\0")
subprocess.run(f"""xargs -0 -n2 -P8 sh -c 'sips -s format jpeg -s formatOptions 80 -Z 900 "$0" --out "$1" >/dev/null 2>&1' < "{os.path.join(out,'thumbs.txt')}" """, shell=True)
os.remove(os.path.join(out, "thumbs.txt"))

TAPBACK = {2000: "❤️", 2001: "👍", 2002: "👎", 2003: "😂", 2004: "‼️", 2005: "❓"}
rows = db.execute(f"""select m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody, m.associated_message_type,
    m.associated_message_guid, m.guid, m.item_type, m.balloon_bundle_id, m.date_edited, m.date_retracted
    from message m join chat_message_join j on j.message_id=m.ROWID where j.chat_id in ({q}) order by m.date""", chat_ids).fetchall()

reacts = defaultdict(list)
for r in rows:
    t = r["associated_message_type"] or 0
    if 2000 <= t <= 2005:
        g = (r["associated_message_guid"] or "").split("/")[-1]
        reacts[g].append((r["is_from_me"], TAPBACK[t]))

parts = []
last_day = None
n = 0
for r in rows:
    t = r["associated_message_type"] or 0
    if t >= 2000:
        continue
    if r["item_type"] not in (0, None) and not body_text(r) and r["ROWID"] not in atts:
        continue
    d = ts(r["date"])
    day = d.strftime("%A, %B %-d, %Y")
    if day != last_day:
        parts.append(f'<div class="day">{day}</div>'); last_day = day
    side = "me" if r["is_from_me"] else "them"
    who = ME if r["is_from_me"] else THEM
    txt = body_text(r).replace("￼", "").strip()
    inner = ""
    if txt:
        inner += f"<p>{html.escape(txt)}</p>"
    for a in atts.get(r["ROWID"], []):
        mt = a["mime_type"] or ""
        nm = html.escape(a["transfer_name"] or os.path.basename(a["filename"] or "attachment"))
        if not a["href"]:
            inner += f'<div class="att gone">{nm} (not in backup)</div>'
        elif a.get("thumb"):
            inner += f'<a href="{a["href"]}" target="_blank"><img loading="lazy" src="{a["thumb"]}" alt="{nm}"></a>'
        elif mt.startswith("image/"):
            inner += f'<a href="{a["href"]}" target="_blank"><img loading="lazy" src="{a["href"]}" alt="{nm}"></a>'
        elif mt.startswith("video/"):
            inner += f'<video controls preload="none" src="{a["href"]}"></video>'
        elif mt.startswith("audio/"):
            inner += f'<audio controls preload="none" src="{a["href"]}"></audio>'
        else:
            inner += f'<div class="att"><a href="{a["href"]}" target="_blank">{nm}</a></div>'
    if not inner:
        continue
    rx = reacts.get(r["guid"])
    if rx:
        inner += '<div class="rx">' + " ".join(e for _, e in rx) + "</div>"
    edited = ' <span class="meta">edited</span>' if r["date_edited"] else ""
    parts.append(f'<div class="msg {side}"><div class="bubble">{inner}</div><div class="time">{who} · {d.strftime("%-I:%M %p")}{edited}</div></div>')
    n += 1

first, last = ts(rows[0]["date"]).strftime("%b %-d, %Y"), ts(rows[-1]["date"]).strftime("%b %-d, %Y")
page = f"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(TITLE)}</title>
<style>
:root{{--bg:#fff;--fg:#111;--me:#1f8fff;--them:#e9e9eb;--themfg:#111;--muted:#777}}
@media (prefers-color-scheme:dark){{:root{{--bg:#000;--fg:#eee;--them:#26262a;--themfg:#eee;--muted:#999}}}}
body{{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 -apple-system,system-ui,sans-serif}}
main{{max-width:720px;margin:0 auto;padding:16px}}
h1{{font-size:20px;margin:8px 0 2px}} .sub{{color:var(--muted);margin-bottom:24px}}
.day{{text-align:center;color:var(--muted);font-size:12px;margin:28px 0 10px}}
.msg{{display:flex;flex-direction:column;margin:3px 0;max-width:78%}}
.msg.me{{align-self:flex-end;margin-left:auto;align-items:flex-end}} .msg.them{{align-items:flex-start}}
.bubble{{padding:7px 12px;border-radius:18px;background:var(--them);color:var(--themfg);word-wrap:break-word;overflow-wrap:anywhere}}
.me .bubble{{background:var(--me);color:#fff}}
.bubble p{{margin:0;white-space:pre-wrap}}
.bubble img,.bubble video{{display:block;max-width:100%;max-height:420px;border-radius:12px;margin:4px 0}}
.bubble audio{{display:block;margin:4px 0}}
.att{{font-size:13px}} .gone{{opacity:.6;font-style:italic}}
.rx{{font-size:13px;margin-top:4px}} .time{{font-size:11px;color:var(--muted);margin:2px 6px}}
.me .bubble a{{color:#fff}}
</style></head><body><main>
<h1>{html.escape(TITLE)}</h1>
<div class="sub">{n:,} messages, {copied:,} attachments · {first} to {last} · exported from an iPhone backup</div>
{"".join(parts)}
</main></body></html>"""
open(os.path.join(out, "index.html"), "w").write(page)
print(f"messages={n} attachments_copied={copied} attachments_missing={missing} thumbs={len(thumbs)}")
