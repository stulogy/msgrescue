import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// An HTML page of every video in Messages: the ones already in the camera
/// roll, the ones that might be, and the ones that are not.
enum VideoReport {

    struct Video {
        let attachment: Attachment
        let fileID: String
        let sig: Signature?
        let exported: String?    // File name in the upload folder, if copied there.
    }

    struct RollVideo { let path: String; let id: String; let sig: Signature }

    /// Below this a frame difference reads as the same video; up to `greyMax`
    /// it might be a trimmed or edited copy, worth a look by eye.
    static let sameMax = 4, greyMax = 14

    private struct Entry: Encodable {
        let name: String
        let date: Date
        let chat: String
        let from: String
        let duration: Double
        let bytes: Int64
        let poster: String
        let file: String           // Where to open it.
        let uploadPath: String?    // Set when it is in the upload folder.
        let status: String         // in_library, grey, missing
        let distance: Int?
        let matchPoster: String?
        let matchName: String?
    }

    static func write(videos: [Video], roll: [RollVideo], backup: Backup, contacts: Contacts,
                      photosDir: URL, outRoot: URL) throws -> URL {
        let posterDir = outRoot.appendingPathComponent("Video Report/posters")
        try FileManager.default.createDirectory(at: posterDir, withIntermediateDirectories: true)

        var posterJobs: [(src: URL, ext: String, dst: URL)] = []
        var entries: [Entry] = []

        for (n, v) in videos.enumerated() {
            let a = v.attachment
            var best: (RollVideo, Int)?
            if let sig = v.sig, let duration = sig.duration {
                for r in roll where abs((r.sig.duration ?? -99) - duration) <= 0.6 {
                    let d = (sig.hash ^ r.sig.hash).nonzeroBitCount
                    if d < (best?.1 ?? .max) { best = (r, d) }
                }
            }
            let status = best.map { $0.1 <= sameMax ? "in_library" : $0.1 <= greyMax ? "grey" : "missing" } ?? "missing"

            let src = backup.url(forFileID: v.fileID)
            let open = v.exported.map { photosDir.appendingPathComponent($0) } ?? src
            let ext = (a.originalName as NSString).pathExtension.lowercased()
            let poster = "posters/m\(n).jpg"
            posterJobs.append((src, ext.isEmpty ? "mov" : ext, posterDir.appendingPathComponent("m\(n).jpg")))

            var matchPoster: String?
            if status == "grey", let (r, _) = best {
                matchPoster = "posters/r\(n).jpg"
                posterJobs.append((backup.url(forFileID: r.id), (r.path as NSString).pathExtension.lowercased(),
                                   posterDir.appendingPathComponent("r\(n).jpg")))
            }

            let size = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int64) ?? 0
            entries.append(Entry(
                name: a.originalName, date: a.date,
                chat: contacts.name(for: a.chat),
                from: a.isFromMe ? "Her" : contacts.name(for: a.sender),
                duration: v.sig?.duration ?? 0, bytes: size, poster: poster, file: open.path,
                uploadPath: v.exported.map { photosDir.appendingPathComponent($0).path },
                status: status, distance: best?.1, matchPoster: matchPoster,
                matchName: status == "grey" ? best.map { ($0.0.path as NSString).lastPathComponent } : nil))
        }

        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: posterJobs.count) { i in
            let job = posterJobs[i]
            Signer.writePoster(of: job.src, ext: job.ext, to: job.dst)
            lock.withLock {
                done += 1
                if done % 200 == 0 || done == posterJobs.count {
                    FileHandle.standardError.write("\rPosters: \(done)/\(posterJobs.count)".data(using: .utf8)!)
                }
            }
        }
        FileHandle.standardError.write("\n".data(using: .utf8)!)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let json = String(data: try enc.encode(entries), encoding: .utf8)!
            .replacingOccurrences(of: "</", with: "<\\/")
        let setAside = outRoot.appendingPathComponent("Set Aside/Videos").path
        let meta = String(data: try enc.encode(["setAside": setAside, "device": backup.deviceName]),
                          encoding: .utf8)!.replacingOccurrences(of: "</", with: "<\\/")

        let page = outRoot.appendingPathComponent("Video Report/videos.html")
        try template.replacingOccurrences(of: "__ENTRIES__", with: json)
            .replacingOccurrences(of: "__META__", with: meta)
            .write(to: page, atomically: true, encoding: .utf8)
        return page
    }

    private static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Messages Videos</title>
<style>
:root {
  --bg: #f7f7f5; --surface: #ffffff; --text: #1d1d1f; --muted: #6e6e73;
  --line: #e3e3e0; --accent: #0a66d8; --accent-text: #ffffff; --skip: #c4372c; --ok: #1f8a4c; --warn: #a86400;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #161617; --surface: #1f1f21; --text: #f2f2f2; --muted: #9a9aa0;
    --line: #2e2e31; --accent: #4c9bff; --accent-text: #0b0b0c; --skip: #ff6b5e; --ok: #4cc98a; --warn: #f0a23a;
  }
}
:root[data-theme="dark"] {
  --bg: #161617; --surface: #1f1f21; --text: #f2f2f2; --muted: #9a9aa0;
  --line: #2e2e31; --accent: #4c9bff; --accent-text: #0b0b0c; --skip: #ff6b5e; --ok: #4cc98a; --warn: #f0a23a;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
  font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
header, main { max-width: 1400px; margin: 0 auto; padding: 0 16px; }
header { padding-top: 28px; }
main { padding-bottom: 140px; }
h1 { font-size: 24px; margin: 0 0 4px; font-weight: 650; }
.sub { color: var(--muted); max-width: 70ch; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px; margin: 18px 0 0; }
.stat { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; }
.stat b { display: block; font-size: 22px; font-weight: 650; font-variant-numeric: tabular-nums; }
.stat span { color: var(--muted); }
section { margin-top: 36px; }
h2 { font-size: 18px; margin: 0; font-weight: 650; }
h2 span { color: var(--muted); font-weight: 400; font-size: 14px; margin-left: 6px; }
.note { color: var(--muted); margin: 2px 0 12px; max-width: 80ch; }
.controls { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 12px; }
input[type=search], select { font: inherit; padding: 7px 10px; border-radius: 8px; border: 1px solid var(--line);
  background: var(--surface); color: var(--text); }
input[type=search] { flex: 1 1 220px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 10px; }
.tile { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; overflow: hidden; position: relative; }
.tile img { display: block; width: 100%; aspect-ratio: 4 / 3; object-fit: cover; background: var(--line); }
.tile .dur { position: absolute; top: 6px; left: 6px; font-size: 11px; padding: 2px 6px; border-radius: 4px;
  background: rgba(0,0,0,.65); color: #fff; font-variant-numeric: tabular-nums; }
.tile label { position: absolute; top: 6px; right: 6px; display: flex; gap: 4px; align-items: center; font-size: 11px;
  padding: 2px 6px; border-radius: 4px; background: rgba(0,0,0,.65); color: #fff; cursor: pointer; }
.tile.skip { outline: 3px solid var(--skip); outline-offset: -3px; }
.tile.skip img { opacity: .5; }
.cap { padding: 6px 8px 8px; font-size: 12px; color: var(--muted); }
.cap div { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.cap .who { color: var(--text); }
.pairs { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 12px; }
.pair { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 8px; }
.pair .two { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }
.pair figure { margin: 0; }
.pair img { width: 100%; aspect-ratio: 4 / 3; object-fit: cover; border-radius: 4px; background: var(--line); display: block; }
.pair figcaption { font-size: 11px; color: var(--muted); margin-top: 3px; }
.pair .cap { padding: 6px 0 0; }
.chip { display: inline-block; font-size: 11px; padding: 1px 6px; border-radius: 999px; border: 1px solid var(--line); }
button { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid var(--line);
  background: var(--surface); color: var(--text); cursor: pointer; }
button.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-text); }
.more { margin-top: 12px; }
details summary { cursor: pointer; color: var(--muted); }
.bar { position: fixed; left: 0; right: 0; bottom: 0; padding: 12px 16px; background: var(--surface);
  border-top: 1px solid var(--line); display: none; }
.bar.on { display: block; }
.bar .inner { max-width: 1400px; margin: 0 auto; display: flex; flex-wrap: wrap; gap: 12px; align-items: center; }
.bar textarea { width: 100%; height: 90px; font: 12px ui-monospace, Menlo, monospace; background: var(--bg);
  color: var(--text); border: 1px solid var(--line); border-radius: 6px; padding: 8px; display: none; }
</style>
</head>
<body>
<header>
  <h1>Videos in Messages</h1>
  <p class="sub" id="sub"></p>
  <div class="stats" id="stats"></div>
</header>
<main>
  <section id="grey-sec">
    <h2>Possibly in her library<span id="grey-count"></span></h2>
    <p class="note">Same length as a library video and a similar frame, but not identical. Often a trimmed or edited copy. Left: from Messages. Right: closest library video.</p>
    <div class="pairs" id="grey"></div>
  </section>
  <section>
    <h2>Not in her library<span id="miss-count"></span></h2>
    <p class="note">These are in the upload folder. Tick any you don't want uploaded; the page builds the commands to set them aside (nothing is deleted).</p>
    <div class="controls">
      <input type="search" id="q" placeholder="Filter by person or chat">
      <select id="sort">
        <option value="bytes">Largest first</option>
        <option value="date">Newest first</option>
        <option value="dateAsc">Oldest first</option>
        <option value="duration">Longest first</option>
      </select>
      <select id="dir">
        <option value="">Sent and received</option>
        <option value="received">Received</option>
        <option value="sent">Sent by her</option>
      </select>
    </div>
    <div class="grid" id="miss"></div>
    <button class="more" id="more"></button>
  </section>
  <section>
    <details>
      <summary id="lib-summary"></summary>
      <div class="grid" id="lib" style="margin-top:12px"></div>
    </details>
  </section>
</main>
<div class="bar" id="bar"><div class="inner">
  <span id="count"></span>
  <button class="primary" id="copy">Copy set-aside commands</button>
  <button id="clear">Clear</button>
  <textarea id="cmds" readonly></textarea>
</div></div>
<script>
const ALL = __ENTRIES__;
const META = __META__;
const PAGE = 240;

const gb = b => b >= 1e9 ? (b / 1e9).toFixed(1) + " GB" : (b / 1e6).toFixed(0) + " MB";
const dur = s => { s = Math.round(s); return s >= 3600 ? `${Math.floor(s/3600)}:${String(Math.floor(s%3600/60)).padStart(2,"0")}:${String(s%60).padStart(2,"0")}` : `${Math.floor(s/60)}:${String(s%60).padStart(2,"0")}`; };
const day = d => new Date(d).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
const fileURL = p => "file://" + p.split("/").map(encodeURIComponent).join("/");
const shq = s => "'" + s.replace(/'/g, "'\\''") + "'";
const sum = xs => xs.reduce((a, x) => a + x.bytes, 0);

const lib = ALL.filter(e => e.status === "in_library");
const grey = ALL.filter(e => e.status === "grey");
const miss = ALL.filter(e => e.status !== "in_library");
const skip = new Set();

document.getElementById("sub").textContent =
  `Every video attached to a message on ${META.device}, checked against her photo library by length and by comparing frames.`;
document.getElementById("stats").innerHTML = [
  [ALL.length, "videos in Messages", gb(sum(ALL))],
  [lib.length, "already in her library", gb(sum(lib))],
  [grey.length, "possibly in her library", gb(sum(grey))],
  [miss.length - grey.length, "not in her library", gb(sum(miss) - sum(grey))],
].map(([n, label, size]) => `<div class="stat"><b>${n.toLocaleString()}</b><span>${label} · ${size}</span></div>`).join("");

function caption(e) {
  const cap = document.createElement("div");
  cap.className = "cap";
  const who = document.createElement("div");
  who.className = "who";
  who.textContent = e.from === "Her" ? `Sent by her${e.chat ? " to " + e.chat : ""}` : `From ${e.from || "unknown"}${e.chat && e.chat !== e.from ? " in " + e.chat : ""}`;
  who.title = who.textContent;
  const when = document.createElement("div");
  when.textContent = `${day(e.date)} · ${gb(e.bytes)}`;
  when.title = e.name;
  cap.append(who, when);
  return cap;
}

function tile(e, selectable) {
  const el = document.createElement("div");
  el.className = "tile" + (skip.has(e) ? " skip" : "");
  const a = document.createElement("a");
  a.href = fileURL(e.file);
  a.target = "_blank";
  const img = document.createElement("img");
  img.loading = "lazy"; img.src = e.poster; img.alt = e.name;
  a.appendChild(img);
  const d = document.createElement("span");
  d.className = "dur"; d.textContent = dur(e.duration);
  el.append(a, d);
  if (selectable && e.uploadPath) {
    const lab = document.createElement("label");
    const box = document.createElement("input");
    box.type = "checkbox"; box.checked = skip.has(e);
    box.onchange = () => { box.checked ? skip.add(e) : skip.delete(e); el.classList.toggle("skip", box.checked); update(); };
    lab.append(box, "Don't upload");
    el.appendChild(lab);
  }
  el.appendChild(caption(e));
  return el;
}

// Possibly in library: side by side.
document.getElementById("grey-count").textContent = `${grey.length} · ${gb(sum(grey))}`;
if (!grey.length) document.getElementById("grey-sec").hidden = true;
const greyEl = document.getElementById("grey");
for (const e of grey.sort((a, b) => a.distance - b.distance)) {
  const p = document.createElement("div");
  p.className = "pair";
  p.innerHTML = `<div class="two">
    <figure><a target="_blank"><img loading="lazy"></a><figcaption>Messages · ${dur(e.duration)}</figcaption></figure>
    <figure><img loading="lazy"><figcaption></figcaption></figure></div>`;
  p.querySelector("a").href = fileURL(e.file);
  const [m, r] = p.querySelectorAll("img");
  m.src = e.poster; r.src = e.matchPoster;
  p.querySelectorAll("figcaption")[1].textContent = `Library · ${e.matchName}`;
  p.appendChild(caption(e));
  const chip = document.createElement("span");
  chip.className = "chip"; chip.textContent = `difference ${e.distance}`;
  p.lastChild.appendChild(chip);
  greyEl.appendChild(p);
}

// Not in library: filterable grid, paged.
const missEl = document.getElementById("miss");
const more = document.getElementById("more");
let view = [], shown = 0;
function render() {
  const q = document.getElementById("q").value.trim().toLowerCase();
  const dir = document.getElementById("dir").value;
  const sort = document.getElementById("sort").value;
  view = miss.filter(e =>
    (!q || (e.chat + " " + e.from).toLowerCase().includes(q)) &&
    (!dir || (dir === "sent") === (e.from === "Her")));
  const cmp = { bytes: (a, b) => b.bytes - a.bytes, date: (a, b) => b.date.localeCompare(a.date),
                dateAsc: (a, b) => a.date.localeCompare(b.date), duration: (a, b) => b.duration - a.duration }[sort];
  view.sort(cmp);
  document.getElementById("miss-count").textContent = `${view.length.toLocaleString()} · ${gb(sum(view))}`;
  missEl.innerHTML = ""; shown = 0;
  page();
}
function page() {
  for (const e of view.slice(shown, shown + PAGE)) missEl.appendChild(tile(e, true));
  shown = Math.min(view.length, shown + PAGE);
  more.hidden = shown >= view.length;
  more.textContent = `Show more (${(view.length - shown).toLocaleString()} left)`;
}
more.onclick = page;
for (const id of ["q", "sort", "dir"]) document.getElementById(id).addEventListener("input", render);
render();

// Already in library: collapsed, rendered on first open.
document.getElementById("lib-summary").textContent =
  `Already in her library: ${lib.length.toLocaleString()} videos, ${gb(sum(lib))}. Skipped from the upload folder.`;
document.querySelector("details").addEventListener("toggle", function once() {
  const el = document.getElementById("lib");
  for (const e of lib) el.appendChild(tile(e, false));
  this.removeEventListener("toggle", once);
});

const bar = document.getElementById("bar");
const cmds = document.getElementById("cmds");
function update() {
  bar.classList.toggle("on", skip.size > 0);
  document.getElementById("count").textContent = `${skip.size} set aside · ${gb(sum([...skip]))}`;
  cmds.value = skip.size ? [`mkdir -p ${shq(META.setAside)}`,
    ...[...skip].map(e => `mv -n ${shq(e.uploadPath)} ${shq(META.setAside + "/")}`)].join("\n") : "";
}
document.getElementById("copy").onclick = async () => {
  cmds.style.display = "block"; cmds.select();
  try { await navigator.clipboard.writeText(cmds.value); document.getElementById("copy").textContent = "Copied. Paste into Terminal"; }
  catch { document.getElementById("copy").textContent = "Select the text below and copy it"; }
};
document.getElementById("clear").onclick = () => { skip.clear(); cmds.style.display = "none"; render(); update(); };
</script>
</body>
</html>
"""#
}
