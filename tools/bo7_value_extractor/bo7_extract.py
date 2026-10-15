"""BO7 movement value extractor.

Reads the files a community exporter (Cordycep + Greyhound, atian-cod-tools,
...) wrote from your BO7 install, pulls out every movement-related number,
and suggests bo7_* settings for the BO3 mod using mapping.json.

It never touches the game itself: point it at an export folder.

    python bo7_extract.py                 # GUI
    python bo7_extract.py scan <folder>   # command line, see --help
"""

import argparse
import csv
import html
import io
import json
import os
import re
import sys
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))
MOD_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
DEFAULT_GSC = os.path.join(MOD_ROOT, "scripts", "mp", "bo7_movement.gsc")
DEFAULT_MAPPING = os.path.join(HERE, "mapping.json")

MAX_TEXT_BYTES = 64 * 1024 * 1024
TEXT_EXTS = {".json", ".csv", ".tsv", ".txt", ".cfg", ".gdt", ".ini", ".kvp",
             ".str", ".gsc", ".csc", ".lua", ".xml", ".yaml", ".yml", ".bundle", ""}

# Category name -> regex on the key path. First match wins, so order matters.
CATEGORIES = [
    ("Wall jump",      r"wall.?(jump|run|kick)"),
    ("Tactical sprint", r"(tac|tactical|super).?sprint"),
    ("Sprint",         r"sprint"),
    ("Slide",          r"slide"),
    ("Dive",           r"dive|supine"),
    ("Mantle / ledge", r"mantle|ledge|vault|climb"),
    ("Jump",           r"jump"),
    ("Gravity / fall", r"grav|fall|land"),
    ("Prone / crouch", r"prone|crouch|stance"),
    ("Lean",           r"lean|peek"),
    ("Air control",    r"air|strafe"),
    ("Friction / accel", r"friction|accel|decel|stop"),
    ("Ladder / swim",  r"ladder|swim"),
    ("Speed (other)",  r"speed|velocity|omni|move|walk|run|stride"),
]
_CATEGORY_RES = [(n, re.compile(p, re.I)) for n, p in CATEGORIES]
_MOVEMENT_RE = re.compile("|".join(p for _, p in CATEGORIES), re.I)

_NUM = r"-?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?"
_NUM_RE = re.compile(rf"^\s*({_NUM})f?\s*$")
# key = 1.5 / key: 1.5 / key,1.5 / key 1.5 / "key" "1.5"
_KV_LINE_RE = re.compile(
    rf'^\s*"?([A-Za-z_][\w.\-/\[\]]*)"?\s*(?:=|:|,|\s)\s*"?({_NUM})f?"?\s*[,;]?\s*(?://.*)?$')
_GSC_DEFAULT_RE = re.compile(r'bo7_default\(\s*"(bo7_\w+)"\s*,\s*([^)]+?)\s*\)')
_GSC_GETDVAR_RE = re.compile(r'GetDvar(?:Float|Int)\(\s*"(bo7_\w+)"\s*,\s*([^)]+?)\s*\)')


@dataclass
class Value:
    file: str      # path relative to the export folder
    key: str       # flattened key inside the file
    value: float
    category: str = ""


@dataclass
class Suggestion:
    target: str
    label: str
    current: object
    suggested: float
    source: Value
    note: str = ""
    alternatives: list = field(default_factory=list)
    accepted: bool = False

    @property
    def change(self):
        try:
            cur = float(self.current)
        except (TypeError, ValueError):
            return None
        if cur == 0:
            return None
        return (self.suggested - cur) / abs(cur) * 100.0


# ---------------------------------------------------------------- parsing

def _to_number(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        m = _NUM_RE.match(v)
        if m:
            return float(m.group(1))
    return None


def _flatten_json(node, prefix, out):
    if isinstance(node, dict):
        # {"name": "slideSpeed", "value": 300} style entries
        name = node.get("name", node.get("key"))
        if isinstance(name, str) and "value" in node and len(node) <= 4:
            n = _to_number(node["value"])
            if n is not None:
                out.append((f"{prefix}.{name}" if prefix else name, n))
                return
        for k, v in node.items():
            _flatten_json(v, f"{prefix}.{k}" if prefix else str(k), out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _flatten_json(v, f"{prefix}[{i}]", out)
    else:
        n = _to_number(node)
        if n is not None:
            out.append((prefix, n))


def _parse_csv(text, delim):
    rows = [r for r in csv.reader(io.StringIO(text), delimiter=delim) if any(c.strip() for c in r)]
    if not rows:
        return []
    out = []
    first = rows[0]
    header_like = len(first) > 2 and all(_to_number(c) is None for c in first)
    if header_like:
        for r in rows[1:]:
            if not r:
                continue
            rowname = r[0].strip()
            for j in range(1, min(len(r), len(first))):
                n = _to_number(r[j])
                if n is not None:
                    out.append((f"{rowname}.{first[j].strip()}", n))
    else:
        for r in rows:
            if len(r) >= 2:
                n = _to_number(r[1])
                if n is not None and r[0].strip():
                    out.append((r[0].strip(), n))
    return out


def _parse_text(text):
    out = []
    for line in text.splitlines():
        m = _KV_LINE_RE.match(line)
        if m:
            out.append((m.group(1), float(m.group(2))))
    return out


def parse_file(path):
    """Returns [(key, number)] for one file, or [] when it isn't readable text."""
    ext = os.path.splitext(path)[1].lower()
    if ext not in TEXT_EXTS:
        return []
    try:
        if os.path.getsize(path) > MAX_TEXT_BYTES:
            return []
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return []
    if b"\0" in raw[:4096]:
        return []
    text = raw.decode("utf-8-sig", errors="replace")

    if ext == ".json":
        try:
            out = []
            _flatten_json(json.loads(text), "", out)
            return out
        except ValueError:
            pass
    if ext in (".csv", ".tsv"):
        return _parse_csv(text, "\t" if ext == ".tsv" else ",")
    return _parse_text(text)


def categorize(key):
    for name, rx in _CATEGORY_RES:
        if rx.search(key):
            return name
    return ""


def scan_folder(folder, movement_only=True, progress=None):
    values = []
    files = []
    for root, _, names in os.walk(folder):
        for n in names:
            files.append(os.path.join(root, n))
    for i, path in enumerate(files):
        if progress and i % 200 == 0:
            progress(i, len(files))
        rel = os.path.relpath(path, folder)
        for key, num in parse_file(path):
            if movement_only and not _MOVEMENT_RE.search(key):
                continue
            values.append(Value(rel, key, num, categorize(key)))
    if progress:
        progress(len(files), len(files))
    return values


# ---------------------------------------------------------------- mod side

def load_mod_defaults(gsc_path):
    """bo7_* defaults as the mod registers them with bo7_default()."""
    out = {}
    try:
        with open(gsc_path, encoding="utf-8", errors="replace") as f:
            src = f.read()
    except OSError:
        return out
    for name, raw in _GSC_DEFAULT_RE.findall(src):
        n = _to_number(raw)
        out[name] = n if n is not None else raw.strip().strip('"')
    # Dvars never passed to bo7_default() still have a GetDvar*() fallback.
    for name, raw in _GSC_GETDVAR_RE.findall(src):
        n = _to_number(raw)
        if name not in out and n is not None:
            out[name] = n
    return out


def load_mapping(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _transform(rule, value, refs):
    t = rule.get("transform", "direct")
    if t == "ms":
        return (value * 1000.0 if value < 20 else value), ""
    if t == "ratio":
        ref = refs.get(rule.get("ref", ""), {})
        rv = ref.get("value")
        if not rv:
            return None, f"missing reference '{rule.get('ref')}'"
        return value / float(rv), f"{value:g} / {rv:g} ({rule.get('ref')}); check the reference"
    return value, ""


def suggest(values, mapping, defaults):
    refs = mapping.get("references", {})
    out = []
    for rule in mapping.get("rules", []):
        pats = [re.compile(p, re.I) for p in rule.get("patterns", [])]
        hits = []
        for v in values:
            for rank, rx in enumerate(pats):
                if rx.search(v.key):
                    hits.append((rank, len(v.key), v))
                    break
        if not hits:
            continue
        hits.sort(key=lambda h: (h[0], h[1]))
        best = hits[0][2]
        sv, note = _transform(rule, best.value, refs)
        if sv is None:
            continue
        distinct = {round(h[2].value, 4) for h in hits}
        if len(distinct) > 1:
            note = (note + "; " if note else "") + f"{len(hits)} matches with {len(distinct)} different values, check the alternatives"
        out.append(Suggestion(
            target=rule["target"], label=rule.get("label", ""),
            current=defaults.get(rule["target"]), suggested=round(sv, 4),
            source=best, note=note, alternatives=[h[2] for h in hits[1:25]]))
    return out


# ---------------------------------------------------------------- output

def write_cfg(path, suggestions):
    lines = ["// Generated by bo7_extract.py from exported BO7 values.",
             "// Paste into mp_mod.cfg (or exec this file) to override the mod's defaults.", ""]
    for s in suggestions:
        if s.accepted:
            lines.append(f"// {s.label}: was {s.current}, from {s.source.file} :: {s.source.key}")
            lines.append(f'set {s.target} "{s.suggested:g}"')
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def write_html(path, values, suggestions, export_dir):
    e = html.escape
    srows = "".join(
        f"<tr><td><code>{e(s.target)}</code><div class=sub>{e(s.label)}</div></td>"
        f"<td class=n>{e(str(s.current))}</td><td class=n><b>{s.suggested:g}</b></td>"
        f"<td class=n>{'' if s.change is None else f'{s.change:+.0f}%'}</td>"
        f"<td><code>{e(s.source.key)}</code><div class=sub>{e(s.source.file)}</div></td>"
        f"<td>{e(s.note)}</td></tr>" for s in suggestions)
    by_cat = {}
    for v in values:
        by_cat.setdefault(v.category or "Other", []).append(v)
    sections = ""
    for cat, _ in CATEGORIES + [("Other", "")]:
        vs = by_cat.get(cat)
        if not vs:
            continue
        rows = "".join(f"<tr><td><code>{e(v.key)}</code></td><td class=n>{v.value:g}</td>"
                       f"<td class=sub>{e(v.file)}</td></tr>" for v in sorted(vs, key=lambda v: v.key.lower()))
        sections += f"<h3>{e(cat)} <span class=sub>({len(vs)})</span></h3><table><tr><th>Key</th><th>Value</th><th>File</th></tr>{rows}</table>"
    doc = f"""<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>BO7 Movement Values</title><style>
:root{{--bg:#fafaf8;--fg:#1d1d1b;--mut:#6b6b66;--line:#e2e2dc;--acc:#2f5bd3}}
@media (prefers-color-scheme:dark){{:root{{--bg:#151514;--fg:#ececea;--mut:#9a9a94;--line:#2c2c2a;--acc:#86a6ff}}}}
body{{background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif;margin:0;padding:24px 16px;max-width:1200px;margin:auto}}
table{{border-collapse:collapse;width:100%;margin:8px 0 24px}}th,td{{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}}
th{{color:var(--mut);font-weight:600}}.n{{text-align:right;font-variant-numeric:tabular-nums}}.sub{{color:var(--mut);font-size:12px}}
code{{font:12px ui-monospace,Consolas,monospace;word-break:break-all}}h1{{font-size:20px}}h2{{font-size:16px;margin-top:32px}}h3{{font-size:14px}}
</style></head><body><h1>BO7 movement values</h1>
<p class=sub>Export folder: {e(export_dir)} &middot; {len(values)} movement values &middot; {len(suggestions)} suggested settings</p>
<h2>Suggested bo7_* settings</h2><table><tr><th>Setting</th><th>Mod now</th><th>BO7</th><th>Change</th><th>Source</th><th>Note</th></tr>{srows}</table>
<h2>All movement values found</h2>{sections}</body></html>"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(doc)


def write_values_csv(path, values):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["category", "key", "value", "file"])
        for v in values:
            w.writerow([v.category, v.key, f"{v.value:g}", v.file])


# ---------------------------------------------------------------- CLI

def cli(argv):
    ap = argparse.ArgumentParser(description="Extract BO7 movement values from an asset export folder.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan", help="scan an export folder")
    s.add_argument("folder", help="folder your exporter wrote (Greyhound/Cordycep/acts output)")
    s.add_argument("--gsc", default=DEFAULT_GSC, help="mod script holding the bo7_default() values")
    s.add_argument("--mapping", default=DEFAULT_MAPPING)
    s.add_argument("--out", default=os.path.join(HERE, "output"))
    s.add_argument("--all", action="store_true", help="keep every number, not just movement-looking keys")
    s.add_argument("--accept-best", action="store_true", help="write every top suggestion to bo7_extracted.cfg")
    a = ap.parse_args(argv)

    if not os.path.isdir(a.folder):
        sys.exit(f"not a folder: {a.folder}")
    values = scan_folder(a.folder, movement_only=not a.all,
                         progress=lambda i, n: print(f"\rscanning {i}/{n} files", end="", file=sys.stderr))
    print(file=sys.stderr)
    sugg = suggest(values, load_mapping(a.mapping), load_mod_defaults(a.gsc))
    os.makedirs(a.out, exist_ok=True)
    write_values_csv(os.path.join(a.out, "bo7_values.csv"), values)
    write_html(os.path.join(a.out, "bo7_report.html"), values, sugg, a.folder)
    for s_ in sugg:
        s_.accepted = a.accept_best
        ch = "" if s_.change is None else f" ({s_.change:+.0f}%)"
        print(f"{s_.target:<18} {str(s_.current):>8} -> {s_.suggested:<10g}{ch}  [{s_.source.key}]")
    if a.accept_best:
        write_cfg(os.path.join(a.out, "bo7_extracted.cfg"), sugg)
    print(f"\n{len(values)} movement values, {len(sugg)} suggestions. Output: {a.out}")


# ---------------------------------------------------------------- GUI

def gui():
    import threading
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk

    root = tk.Tk()
    root.title("BO7 Movement Value Extractor")
    root.geometry("1180x720")

    state = {"values": [], "sugg": []}
    folder_var = tk.StringVar()
    gsc_var = tk.StringVar(value=DEFAULT_GSC)
    filter_var = tk.StringVar()
    status_var = tk.StringVar(value="Pick the folder your exporter wrote, then Scan.")

    top = ttk.Frame(root, padding=8)
    top.pack(fill="x")
    ttk.Label(top, text="Export folder").grid(row=0, column=0, sticky="w")
    ttk.Entry(top, textvariable=folder_var).grid(row=0, column=1, sticky="ew", padx=6)
    ttk.Button(top, text="Browse...", command=lambda: folder_var.set(
        filedialog.askdirectory() or folder_var.get())).grid(row=0, column=2)
    ttk.Label(top, text="Mod script").grid(row=1, column=0, sticky="w", pady=(4, 0))
    ttk.Entry(top, textvariable=gsc_var).grid(row=1, column=1, sticky="ew", padx=6, pady=(4, 0))
    ttk.Button(top, text="Browse...", command=lambda: gsc_var.set(
        filedialog.askopenfilename(filetypes=[("GSC", "*.gsc"), ("All", "*.*")]) or gsc_var.get())
    ).grid(row=1, column=2, pady=(4, 0))
    scan_btn = ttk.Button(top, text="Scan")
    scan_btn.grid(row=0, column=3, rowspan=2, padx=(8, 0), sticky="ns")
    top.columnconfigure(1, weight=1)

    nb = ttk.Notebook(root)
    nb.pack(fill="both", expand=True, padx=8)

    # Suggestions tab
    sf = ttk.Frame(nb)
    nb.add(sf, text="Suggested settings")
    scols = ("use", "setting", "label", "current", "bo7", "change", "source", "note")
    st = ttk.Treeview(sf, columns=scols, show="headings", selectmode="browse")
    for c, w, t in [("use", 40, "Use"), ("setting", 130, "Setting"), ("label", 200, "What it is"),
                    ("current", 70, "Mod now"), ("bo7", 80, "BO7"), ("change", 60, "Change"),
                    ("source", 330, "Source key"), ("note", 260, "Note")]:
        st.heading(c, text=t)
        st.column(c, width=w, anchor="e" if c in ("current", "bo7", "change") else "w")
    st.pack(fill="both", expand=True, side="left")
    ttk.Scrollbar(sf, command=st.yview).pack(side="right", fill="y")

    # Values tab
    vf = ttk.Frame(nb)
    nb.add(vf, text="All movement values")
    fr = ttk.Frame(vf)
    fr.pack(fill="x", pady=4)
    ttk.Label(fr, text="Filter").pack(side="left")
    ttk.Entry(fr, textvariable=filter_var, width=40).pack(side="left", padx=6)
    vcols = ("category", "key", "value", "file")
    vt = ttk.Treeview(vf, columns=vcols, show="headings")
    for c, w in zip(vcols, (130, 480, 90, 420)):
        vt.heading(c, text=c.capitalize(), command=lambda c=c: sort_values(c))
        vt.column(c, width=w, anchor="e" if c == "value" else "w")
    vt.pack(fill="both", expand=True, side="left")
    ttk.Scrollbar(vf, command=vt.yview).pack(side="right", fill="y")

    bottom = ttk.Frame(root, padding=8)
    bottom.pack(fill="x")
    ttk.Label(bottom, textvariable=status_var).pack(side="left")
    ttk.Button(bottom, text="Write cfg", command=lambda: do_cfg()).pack(side="right")
    ttk.Button(bottom, text="Save report", command=lambda: do_report()).pack(side="right", padx=6)
    ttk.Label(bottom, text="Double-click a suggestion to tick it.  ").pack(side="right")

    sort_state = {"col": "category", "rev": False}

    def fill_values():
        vt.delete(*vt.get_children())
        q = filter_var.get().lower()
        rows = [v for v in state["values"]
                if not q or q in v.key.lower() or q in v.file.lower() or q in v.category.lower()]
        col, rev = sort_state["col"], sort_state["rev"]
        rows.sort(key=(lambda v: v.value) if col == "value" else (lambda v: str(getattr(v, col)).lower()),
                  reverse=rev)
        for v in rows[:20000]:
            vt.insert("", "end", values=(v.category, v.key, f"{v.value:g}", v.file))

    def sort_values(col):
        sort_state["rev"] = not sort_state["rev"] if sort_state["col"] == col else False
        sort_state["col"] = col
        fill_values()

    def fill_sugg():
        st.delete(*st.get_children())
        for i, s in enumerate(state["sugg"]):
            ch = "" if s.change is None else f"{s.change:+.0f}%"
            st.insert("", "end", iid=str(i), values=(
                "[x]" if s.accepted else "[ ]", s.target, s.label, s.current, f"{s.suggested:g}",
                ch, f"{s.source.key}  ({s.source.file})", s.note))

    def toggle(_e):
        sel = st.selection()
        if sel:
            s = state["sugg"][int(sel[0])]
            s.accepted = not s.accepted
            fill_sugg()
            st.selection_set(sel)

    st.bind("<Double-1>", toggle)
    filter_var.trace_add("write", lambda *_: fill_values())

    def do_scan():
        folder = folder_var.get().strip()
        if not os.path.isdir(folder):
            messagebox.showerror("Scan", "Pick the folder your exporter wrote first.")
            return
        scan_btn.state(["disabled"])

        def work():
            try:
                vals = scan_folder(folder, progress=lambda i, n: root.after(
                    0, status_var.set, f"Scanning {i}/{n} files..."))
                sugg = suggest(vals, load_mapping(DEFAULT_MAPPING), load_mod_defaults(gsc_var.get()))
                err = None
            except Exception as ex:  # surface anything to the user instead of dying silently
                vals, sugg, err = [], [], ex

            def done():
                scan_btn.state(["!disabled"])
                if err:
                    messagebox.showerror("Scan failed", str(err))
                    return
                state["values"], state["sugg"] = vals, sugg
                fill_values()
                fill_sugg()
                status_var.set(f"{len(vals)} movement values, {len(sugg)} suggested settings.")
            root.after(0, done)
        threading.Thread(target=work, daemon=True).start()

    def do_report():
        if not state["values"]:
            return
        p = filedialog.asksaveasfilename(defaultextension=".html", initialfile="bo7_report.html")
        if p:
            write_html(p, state["values"], state["sugg"], folder_var.get())
            write_values_csv(os.path.splitext(p)[0] + "_values.csv", state["values"])
            status_var.set(f"Saved {p}")

    def do_cfg():
        if not any(s.accepted for s in state["sugg"]):
            messagebox.showinfo("Write cfg", "Tick at least one suggestion (double-click it).")
            return
        p = filedialog.asksaveasfilename(defaultextension=".cfg", initialfile="bo7_extracted.cfg")
        if p:
            write_cfg(p, state["sugg"])
            status_var.set(f"Saved {p}")

    scan_btn.configure(command=do_scan)
    root.mainloop()


if __name__ == "__main__":
    if len(sys.argv) > 1:
        cli(sys.argv[1:])
    else:
        gui()
