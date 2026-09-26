#!/usr/bin/env python3
"""media-stage: bring a batch of files into the /srv/media library.

Every batch goes through the same steps, whatever its source (a Google Drive
share, a GCS listing, a Mac's Downloads folder):

  scan   STAGING   read each file's own metadata  -> STAGING.manifest.jsonl
  draft  STAGING   propose library paths by rule  -> STAGING.tsv
  (review STAGING.tsv: fill the blank `new` cells, correct the rest)
  check  STAGING   validate the table against the files and the layout
  apply  STAGING   move each file into place, then write its standard metadata
  lint   [DIR...]  audit the library: layout and metadata
  close  STAGING   remove the batch's records once it is filed (and audited)

  restage STAGING PATH...   move library files back into a new batch, to be
                            filed again under other names (a layout change)

STAGING is a batch directory: /srv/media/staging/<batch> on desk, which the
Mac sees as /Volumes/media-staging/<batch>. Its sidecars sit next to it:
staging/print/ has staging/print.manifest.jsonl and staging/print.tsv. The
library share is read-only from the Mac, so apply, tag and lint --fix run
on desk (`ssh desk media-stage apply /srv/media/staging/<batch>`).

The table (TSV, header row) needs `old` and `new` columns; `confidence` and
`note` are optional. `old` is relative to STAGING, `new` to the library root.
Special values of `new`: `beets` (music, imported by beets instead), `skip`
(left in staging on purpose), `discard` (deleted by apply: a copy already
filed, or a worse copy of what the batch files) and `trash` (moved by apply
to staging/trash/<batch>/, for a copy that might yet be wanted). apply logs
all of them, with the file's sha256, to STAGING.applied.jsonl.

Several hosts may run this against one library (desk locally, the Mac over
SMB). Writers take lock files (see Lock) and fail fast, naming the holder;
moves never replace an existing file; apply re-validates under its locks and
refuses a file that changed since it was scanned. The table itself is edited
by hand: one person or agent per batch.

The layout is docs/desktop-migration.md, "Layout on the share". LAYOUT below
is its machine-checked form; keep the two in step.
"""

import argparse
import datetime
import errno
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

# --------------------------------------------------------------------------
# Kinds and layout

VIDEO_EXT = {"mkv", "mp4", "m4v", "mov", "avi", "wmv", "webm", "mpg", "mpeg", "ts", "m2ts", "flv"}
SUB_EXT = {"srt", "ass", "ssa", "vtt", "sub", "idx", "sup"}
AUDIO_EXT = {"mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "aif", "aiff", "wma", "alac"}
IMAGE_EXT = {"jpg", "jpeg", "png", "webp", "gif"}
LIBRARY_DIRS = ("music", "books", "rpg", "movies", "tv", "youtube")

# Junk the Mac, Windows and old readers leave behind; never part of a batch.
IGNORED_NAMES = {".DS_Store", "Thumbs.db", "desktop.ini", ".localized"}

_V = "|".join(sorted(VIDEO_EXT))
_S = "|".join(sorted(SUB_EXT))
# Subtitle/sidecar suffix after a video's stem: .en.srt, .en.forced.srt, .info.json, .jpg
_SIDE = rf"(\.[A-Za-z]{{2,3}}(-[A-Za-z]{{2}})?)?(\.(forced|sdh|cc|default))?\.({_S})|\.info\.json|\.(jpg|jpeg|png|webp|nfo)"

# A TMDB id in a movie or show folder: "Heat (1995) {tmdb-949}". Plex and
# Jellyfin read it from the folder, Infuse from the file name, so a movie's
# file repeats its folder name, id included. Episodes carry only the show's
# folder id: it is the show's, not the episode's.
_ID = r"( \{tmdb-\d+\})?"

# Books and RPGs are read in Kavita, which groups files into series: one
# folder is one series (books/<author>/<series>/, rpg/<game>/). See "Books and
# RPGs: what Kavita reads" below for the rest of what its layout needs.
LAYOUT = {
    "music": re.compile(r"^music/[^/]+/[^/]+/[^/]+\.[A-Za-z0-9]+$"),
    "books": re.compile(r"^books/[^/]+/[^/]+/[^/]+\.(epub|pdf|mobi|azw3|cbz|cbr|djvu)$"),
    "rpg": re.compile(r"^rpg/[^/]+/[^/]+\.[A-Za-z0-9]+$"),
    "movies": re.compile(
        rf"^movies/(?P<m>[^/]+ \(\d{{4}}\){_ID})/"
        rf"((?P=m)( - [^/]+)?(\.({_V})|{_SIDE})|extras/[^/]+)$"),
    "tv": re.compile(
        rf"^tv/(?P<s>[^/]+ \(\d{{4}}\)){_ID}/Season (?P<n>\d{{2}})/"
        rf"(?P=s) - S(?P=n)E\d{{2,3}}(-E\d{{2,3}})?( - [^/]+)?(\.({_V})|{_SIDE})$"),
    "youtube": re.compile(
        rf"^youtube/[^/]+/\d{{4}}-\d{{2}}-\d{{2}} - [^/]+ \[[A-Za-z0-9_-]+\](\.({_V})|{_SIDE}|\.(m4a|opus|mp3|webm))$"),
}

# SMB-safe for the Windows clients: none of these in any path component.
SMB_BAD = re.compile(r'[:*?"<>|\\\x00-\x1f]')


def ext_of(p):
    name = Path(p).name
    return name.rsplit(".", 1)[1].lower() if "." in name else ""


def kind_of(p):
    e = ext_of(p)
    if e in VIDEO_EXT:
        return "video"
    if e in SUB_EXT:
        return "subtitle"
    if e in AUDIO_EXT:
        return "audio"
    if e in ("pdf", "epub", "cbz", "cbr", "mobi", "azw3", "djvu"):
        return e if e in ("pdf", "epub", "cbz") else "document"
    if e in IMAGE_EXT:
        return "image"
    if Path(p).name.endswith(".info.json"):
        return "infojson"
    return "other"


def layout_error(rel):
    """None if `rel` (relative to the library root) fits the layout, else why not."""
    parts = rel.split("/")
    for c in parts:
        if not c:
            return "empty path component"
        if SMB_BAD.search(c):
            return f"character not allowed over SMB in {c!r}"
        if c != c.strip() or c.endswith("."):
            return f"leading/trailing space or trailing dot in {c!r}"
        if len(c.encode()) > 255:
            return f"component longer than 255 bytes: {c[:40]!r}…"
    top = parts[0]
    if top not in LAYOUT:
        return f"top directory must be one of {', '.join(LIBRARY_DIRS)}"
    if not LAYOUT[top].match(rel):
        return f"does not fit the {top}/ layout"
    if top in ("books", "rpg"):
        return shelf_error(rel)
    return None


# --------------------------------------------------------------------------
# Books and RPGs: what Kavita reads
#
# Kavita (the reading server for books/ and rpg/, both "Book" libraries)
# groups files into series, with volumes and loose "specials". It takes the
# series and title from each file's own metadata, not from its path:
#   EPUB  calibre:series + calibre:series_index (only the two together; else
#         the series is dc:title) and dc:title
#   PDF   XMP calibre:series, calibreSI:series_index and dc:title, in every
#         revision of the file: an older one it cannot parse (an incremental
#         update, a /Length by reference) loses all of it, and so does a
#         catalog kept in a compressed object stream, which it cannot reach
#   CBZ   ComicInfo.xml's Series, Volume and Title
# From the name it takes only a volume number, and it finds one in any "v2",
# "vol 2", "volume 2", "tome 2", "t12 " or "S01" (KAVITA_VOLUME).
#
# So the folder is the series: apply writes it, with the volume and title
# the name gives, into each file (shelf_meta), and a PDF is written out as
# one plain revision (pdf_plain). A name gives a volume only as "<series> Vol. <N>",
# and a version is "version 1.1", never "v1.1". An EPUB with no volume
# number is a series of its own, named by its title: its folder is its title.

# Kavita's Latin-script volume patterns (Kavita.Services/Scanner/Parser.cs,
# MangaVolumeRegex, which Book libraries use), in its order.
_KV_NUM = r"\d+(\.\d)?"
KAVITA_VOLUME = [re.compile(p, re.I) for p in (
    r"(\b|_)(v|tome(\s|_)?|t)(?P<v>\d+-?\d+)(\s|_)",
    r"^.+?(\s*Chapter\s*\d+)?(\s|_|\-\s)+((Vol(ume)?|tome)\.?(\s|_)?)(?P<v>\d+(\.\d+)?(\-\d+(\.\d+)?)?)(.+?|$)",
    rf"(\b|_)(?!\[)v(?P<v>{_KV_NUM}(-{_KV_NUM})?)(?!\])(\b|_)",
    r"(\b|_)(vol\.? ?)(?P<v>\d+(\.\d)?(-\d+)?(\.\d)?)",
    r"(vol\.? ?)(?P<v>\d+(\.\d)?)",
    r"((volume|tome)\s)(?P<v>\d+(\.\d)?)",
    r"(\b|_)((S|T)(?P<v>\d+)(\b|_))",
    r"(vol_)(?P<v>\d+(\.\d)?)",
)]

# "Discworld Vol. 3 - Equal Rites (tr. X)", "Test Game Vol. 2"
VOL_NAME = re.compile(r"^(?P<series>.+?) Vol\. (?P<n>\d+(?:\.\d+)?)(?: - (?P<title>.+))?$")


def kavita_volume(stem):
    """The volume number Kavita reads from a file name, or None."""
    for rx in KAVITA_VOLUME:
        m = rx.search(stem)
        if m and m.group("v"):
            return m.group("v")
    return None


def split_variant(stem):
    """'Foo (pages, v1.3)' -> ('Foo', ' (pages, v1.3)'); a year '(1999)' stays."""
    base = strip_variants(stem)
    return base, stem[len(base):]


def volume_clashes(rels):
    """Books/RPG paths that number the same volume of one series: Kavita
    makes them one volume of both files' pages. One message per clash."""
    seen, out = {}, []
    for rel in rels:
        p = Path(rel)
        if p.parts[0] not in ("books", "rpg") or len(p.parts) < 3:
            continue
        m = VOL_NAME.match(split_variant(p.stem)[0])
        if m:
            key = (str(p.parent), num(m["n"]))
            if key in seen:
                out.append(f"{rel}: the same volume as {seen[key]} (Kavita merges them; keep one)")
            seen.setdefault(key, rel)
    return out


def shelf_error(rel):
    """Why a books/ or rpg/ path would come out wrong in Kavita, or None."""
    p = Path(rel)
    stem, series = p.stem, p.parts[-2]
    base, _ = split_variant(stem)
    m = VOL_NAME.match(base)
    said = kavita_volume(stem)
    if m:
        if m["series"] != series:
            return f"a volume is named for its folder: {series} Vol. {m['n']}"
        if said != m["n"]:
            return f"Kavita reads volume {said} from {stem!r}, not {m['n']}"
    elif said:
        return (f"Kavita reads {stem!r} as volume {said}: write a version as 'version 1.1', "
                f"and a volume as '{series} Vol. <N>'")
    if p.parts[0] == "books" and ext_of(rel) == "epub" and not m and base != series:
        return (f"an EPUB with no volume number is a series of its own in Kavita: "
                f"name its folder for it ({p.parts[1]}/{base}/), or number it ({series} Vol. <N>)")
    return None


# --------------------------------------------------------------------------
# External tools (on PATH via the nix wrapper)

def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def ffprobe(path):
    r = run(["ffprobe", "-v", "error", "-of", "json", "-show_format", "-show_streams", str(path)])
    if r.returncode:
        return {"error": r.stderr.strip()[:300]}
    return json.loads(r.stdout or "{}")


def lower_tags(d):
    return {k.lower(): v for k, v in (d or {}).items()}


def pdfinfo(path):
    r = run(["pdfinfo", str(path)])
    return parse_pdfinfo(r.stdout, r.returncode, r.stderr)


def parse_pdfinfo(out, code=0, err=""):
    info = {}
    for line in out.splitlines():
        # Indented lines describe a subtype (PDF/X's "Title: ISO 15930 …"),
        # not the document: they must not replace its Title.
        if line[:1].isspace():
            continue
        k, sep, v = line.partition(":")
        if sep:
            info.setdefault(k.strip(), v.strip())
    if code:
        info["error"] = err.strip()[:300]
    return info


def pdftext(path, pages=3, limit=800):
    r = run(["pdftotext", "-l", str(pages), str(path), "-"])
    return re.sub(r"\s+", " ", r.stdout).strip()[:limit]


# --------------------------------------------------------------------------
# EPUB

NS = {
    "c": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
}


def _opf_path(z):
    root = ET.fromstring(z.read("META-INF/container.xml"))
    return root.find(".//c:rootfile", NS).get("full-path")


def epub_meta(path):
    try:
        with zipfile.ZipFile(path) as z:
            root = ET.fromstring(z.read(_opf_path(z)))
    except Exception as e:  # malformed books are common; report, don't crash
        return {"error": str(e)[:300]}
    md = root.find("opf:metadata", NS)
    if md is None:
        return {"error": "no <metadata> in OPF"}
    def all_(tag):
        return [(e.text or "").strip() for e in md.findall(f"dc:{tag}", NS) if (e.text or "").strip()]
    series, volume = _epub_series(md)
    return {
        "title": (all_("title") or [""])[0],
        "creators": all_("creator"),
        "identifiers": all_("identifier"),
        "language": (all_("language") or [""])[0],
        "date": (all_("date") or [""])[0],
        "publisher": (all_("publisher") or [""])[0],
        "series": series,
        "volume": volume,
        "source": next((s[len(SOURCE):] for s in all_("source") if s.startswith(SOURCE)), ""),
    }


# The original file's sha256, kept in the metadata of a book or RPG file that
# apply rewrote: how a later batch recognises the same download as filed.
SOURCE = "sha256:"


def _epub_series(md):
    """(series, volume) as Kavita reads them: the last of each wins."""
    series = volume = ""
    for e in md.findall("opf:meta", NS):
        name, prop = e.get("name"), e.get("property")
        if name == "calibre:series":
            series = e.get("content", "")
        elif name == "calibre:series_index":
            volume = e.get("content", "")
        elif prop == "belongs-to-collection":
            series = (e.text or "").strip()
        elif prop == "group-position":
            volume = (e.text or "").strip()
    return series, volume


def num(v):
    """'2.00' and '2' are one volume number."""
    try:
        return f"{float(v):g}" if v not in (None, "") else ""
    except ValueError:
        return v


def rewrite_zip(path, replace, comment=None):
    """Rewrite a zip with members replaced ({name: bytes}); new names are
    appended. Entry order, and each entry's compression, are kept: an EPUB's
    mimetype stays first and stored, as the spec requires."""
    fd, tmp = tempfile.mkstemp(dir=Path(path).parent, prefix=".tagging.", suffix=Path(path).suffix)
    os.close(fd)
    try:
        with zipfile.ZipFile(path) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
            for item in src.infolist():
                dst.writestr(item, replace.pop(item.filename) if item.filename in replace else src.read(item.filename))
            for name, data in replace.items():
                dst.writestr(name, data)
            dst.comment = src.comment if comment is None else comment
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def epub_write(path, want, source=None):
    """Make the EPUB say what Kavita should read: dc:title first, the series
    and volume (or none, so its title is its series), dc:creator where the
    book has none, and the original's sha256 as a dc:source. A publisher's
    own titles stay, after ours."""
    with zipfile.ZipFile(path) as z:
        opf_name = _opf_path(z)
        raw = z.read(opf_name)
    ET.register_namespace("", NS["opf"])
    ET.register_namespace("dc", NS["dc"])
    root = ET.fromstring(raw)
    before = ET.tostring(root)
    md = root.find("opf:metadata", NS)
    dc = lambda t: f"{{{NS['dc']}}}{t}"
    meta = f"{{{NS['opf']}}}meta"
    for t in md.findall("dc:title", NS):
        if (t.text or "").strip() == want["title"]:
            md.remove(t)
    first = next((i for i, e in enumerate(list(md)) if e.tag == dc("title")), len(list(md)))
    new = ET.Element(dc("title"))
    new.text = want["title"]
    md.insert(first, new)
    # Series and volume: ours only. A publisher's collection would name
    # another series than the folder's.
    ids = {f"#{e.get('id')}" for e in md.findall("opf:meta", NS)
           if e.get("property") == "belongs-to-collection" and e.get("id")}
    for e in md.findall("opf:meta", NS):
        if (e.get("name") in ("calibre:series", "calibre:series_index")
                or e.get("property") == "belongs-to-collection" or e.get("refines") in ids):
            md.remove(e)
    if want.get("volume"):
        ET.SubElement(md, meta, {"name": "calibre:series", "content": want["series"]})
        ET.SubElement(md, meta, {"name": "calibre:series_index", "content": want["volume"]})
    if want.get("author") and not any((e.text or "").strip() for e in md.findall("dc:creator", NS)):
        ET.SubElement(md, dc("creator")).text = want["author"]
    if source and not any((e.text or "").startswith(SOURCE) for e in md.findall("dc:source", NS)):
        ET.SubElement(md, dc("source")).text = SOURCE + source
    if ET.tostring(root) == before:
        return
    rewrite_zip(path, {opf_name: ET.tostring(root, encoding="utf-8", xml_declaration=True)})


# --------------------------------------------------------------------------
# PDF metadata, as Kavita reads it: XMP first, the Info dictionary under it

RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
XMP_NS = {"x": "adobe:ns:meta/", "rdf": RDF, "dc": NS["dc"],
          "calibre": "http://calibre-ebook.com/xmp-namespace",
          "calibreSI": "http://calibre-ebook.com/xmp-namespace-series-index"}


def _q(prefix, tag):
    return f"{{{XMP_NS[prefix]}}}{tag}"


def xmp_read(raw):
    """{title, author, series, volume, source} from an XMP packet."""
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return {}
    def first(path):
        e = root.find(f".//{path}//rdf:li", XMP_NS)
        e = e if e is not None else root.find(f".//{path}", XMP_NS)
        return (e.text or "").strip() if e is not None else ""
    return {"title": first("dc:title"),
            "author": ", ".join((e.text or "").strip() for e in root.findall(".//dc:creator//rdf:li", XMP_NS)),
            "series": first("calibre:series/rdf:value"),
            "volume": first("calibre:series//calibreSI:series_index"),
            "source": next((s[len(SOURCE):] for s in ((e.text or "").strip() for e in
                            root.findall(".//dc:source", XMP_NS)) if s.startswith(SOURCE)), "")}


def xmp_with(raw, want, source):
    """The XMP packet `raw` (or a new one) with our title, author, series,
    volume and source in place of any it had."""
    for p, u in XMP_NS.items():
        ET.register_namespace(p, u)
    try:
        root = ET.fromstring(raw) if raw else None
    except ET.ParseError:
        root = None
    rdf = root.find(".//rdf:RDF", XMP_NS) if root is not None else None
    if rdf is None:
        root = ET.Element(_q("x", "xmpmeta"))
        rdf = ET.SubElement(root, _q("rdf", "RDF"))
    theirs = [e.text for d in rdf for e in d.findall("dc:source", XMP_NS)]
    for d in rdf.findall("rdf:Description", XMP_NS):
        for tag in ("dc:title", "dc:creator", "dc:source", "calibre:series"):
            for e in d.findall(tag, XMP_NS):
                d.remove(e)
    d = ET.SubElement(rdf, _q("rdf", "Description"), {_q("rdf", "about"): ""})
    def seq(tag, kind, value, **attrs):
        c = ET.SubElement(ET.SubElement(d, _q("dc", tag)), _q("rdf", kind))
        ET.SubElement(c, _q("rdf", "li"), attrs).text = value
    seq("title", "Alt", want["title"], **{"{http://www.w3.org/XML/1998/namespace}lang": "x-default"})
    if want.get("author"):
        seq("creator", "Seq", want["author"])
    s = ET.SubElement(d, _q("calibre", "series"), {_q("rdf", "parseType"): "Resource"})
    ET.SubElement(s, _q("rdf", "value")).text = want["series"]
    if want.get("volume"):
        ET.SubElement(s, _q("calibreSI", "series_index")).text = want["volume"]
    old = next((t for t in theirs if t and t.startswith(SOURCE)), None)
    if old or source:
        ET.SubElement(d, _q("dc", "source")).text = old or SOURCE + source
    body = ET.tostring(root, encoding="unicode")
    return f'<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n{body}\n<?xpacket end="w"?>'.encode()


def pdf_plain(path):
    """True if the PDF is one revision with a plain xref table, which is all
    Kavita's PDF reader follows reliably: it reads every earlier revision too
    (an incremental update's /Prev), and cannot reach an object kept in a
    compressed object stream (an xref stream's), such as the catalog that
    holds the XMP, nor, from the end of a linearized file, the first page's
    objects."""
    with open(path, "rb") as f:
        if b"/Linearized" in f.read(1024):
            return False
        f.seek(0, 2)
        f.seek(max(0, f.tell() - 2048))
        tail = f.read()
    m = re.search(rb"startxref\s+(\d+)\s+%%EOF\s*$", tail)
    i = tail.rfind(b"trailer")
    if not m or i == -1 or i > m.start():
        return False  # an xref stream, or nothing a strict reader can follow
    return b"/Prev" not in tail[i:m.start()]


def pdf_meta(path):
    """{title, author, series, volume, source, plain, encrypted} as Kavita
    would read them, or {'error': …}."""
    import pikepdf
    try:
        with pikepdf.open(path) as pdf:
            info = pdf.docinfo
            got = {"title": str(info.get("/Title", "")).strip(), "author": str(info.get("/Author", "")).strip(),
                   "series": "", "volume": "", "source": ""}
            md = pdf.Root.get("/Metadata")
            if md is not None:
                got.update({k: v for k, v in xmp_read(md.read_bytes()).items() if v})
            got["encrypted"] = pdf.is_encrypted
    except Exception as e:
        return {"error": str(e)[:300]}
    got["plain"] = pdf_plain(path)
    return got


def pdf_write(path, want, source=None):
    """Write our metadata into the PDF as one plain revision (see pdf_plain;
    every stream copied as it is): Info Title/Author, and XMP with the
    series. Returns an error string, or None."""
    import pikepdf
    tmp = Path(path).with_name(f".tagging.{socket.gethostname()}.{os.getpid()}.{Path(path).name}")
    try:
        with pikepdf.open(path) as pdf:
            if pdf.is_encrypted:
                return "encrypted: left as it is (Kavita cannot read an encrypted PDF's metadata)"
            pdf.docinfo["/Title"] = want["title"]
            if want.get("author"):
                pdf.docinfo["/Author"] = want["author"]
            old = pdf.Root.get("/Metadata")
            raw = old.read_bytes() if old is not None else b""
            pdf.Root.Metadata = pdf.make_stream(xmp_with(raw, want, source),
                                                Type=pikepdf.Name.Metadata, Subtype=pikepdf.Name.XML)
            pdf.save(tmp, stream_decode_level=pikepdf.StreamDecodeLevel.none, fix_metadata_version=False,
                     object_stream_mode=pikepdf.ObjectStreamMode.disable)
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except Exception as e:
        return f"not written: {str(e)[:200]}"
    finally:
        if tmp.exists():
            tmp.unlink()
    return None


def pdf_original_sha256(path):
    """The sha256 a PDF had before exiftool's incremental updates (how apply
    wrote PDF titles until it wrote clean files): exiftool keeps what it
    replaced and can take its updates back off. The file's own hash if it has
    none."""
    fd, tmp = tempfile.mkstemp(suffix=".pdf")
    os.close(fd)
    os.unlink(tmp)
    try:
        r = run(["exiftool", "-q", "-q", "-m", "-PDF-update:all=", "-o", tmp, str(path)])
        return sha256(tmp) if r.returncode == 0 and os.path.exists(tmp) else sha256(path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


# --------------------------------------------------------------------------
# CBZ: ComicInfo.xml; the original's sha256 goes in the zip's comment

def _comicinfo_name(z):
    return next((n for n in z.namelist() if n.lower() == "comicinfo.xml"), None)


def cbz_meta(path):
    try:
        with zipfile.ZipFile(path) as z:
            name = _comicinfo_name(z)
            root = ET.fromstring(z.read(name)) if name else None
            comment = z.comment.decode(errors="replace")
    except Exception as e:
        return {"error": str(e)[:300]}
    get = lambda t: ((root.findtext(t) or "").strip() if root is not None else "")
    m = re.search(r"\bsha256:([0-9a-f]{64})\b", comment)
    return {"title": get("Title"), "author": get("Writer"), "series": get("Series"),
            "volume": get("Volume"), "source": m.group(1) if m else ""}


def cbz_write(path, want, source=None):
    with zipfile.ZipFile(path) as z:
        name = _comicinfo_name(z) or "ComicInfo.xml"
        try:
            root = ET.fromstring(z.read(name))
        except (KeyError, ET.ParseError):
            root = ET.Element("ComicInfo")
        comment = z.comment
    for tag, value in (("Series", want["series"]), ("Title", want["title"]),
                       ("Volume", want.get("volume")), ("Writer", want.get("author"))):
        e = root.find(tag)
        if not value:
            if e is not None and tag == "Volume":
                root.remove(e)
            continue
        if e is None:
            e = ET.SubElement(root, tag)
        e.text = value
    if source and b"sha256:" not in comment:
        comment = (comment + b"\n" if comment else b"") + f"media-stage source {SOURCE}{source}".encode()
    rewrite_zip(path, {name: ET.tostring(root, encoding="utf-8", xml_declaration=True)}, comment)


# --------------------------------------------------------------------------
# scan

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def guess(name):
    from guessit import guessit  # imported lazily: only video needs it
    g = guessit(name)
    out = {}
    for k, v in g.items():
        out[k] = v if isinstance(v, (str, int, float, bool, type(None))) else (
            [x if isinstance(x, (str, int)) else str(x) for x in v] if isinstance(v, list) else str(v))
    return out


def scan_file(path, rel, want_hash):
    st = path.stat()
    rec = {"path": rel, "size": st.st_size, "kind": kind_of(rel), "ext": ext_of(rel),
           "mtime": datetime.datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds"),
           "mtime_epoch": st.st_mtime}  # timezone-free, for comparing across hosts
    k = rec["kind"]
    if k == "pdf":
        info = pdfinfo(path)
        rec["meta"] = {x: info.get(x, "") for x in
                       ("Title", "Author", "Subject", "Creator", "Producer", "Pages", "Page size", "error") if info.get(x)}
        rec["text"] = pdftext(path)
    elif k == "epub":
        rec["meta"] = epub_meta(path)
    elif k == "cbz":
        try:
            with zipfile.ZipFile(path) as z:
                names = z.namelist()
                rec["meta"] = {"images": sum(ext_of(n) in IMAGE_EXT for n in names)}
                ci = next((n for n in names if n.lower().endswith("comicinfo.xml")), None)
                if ci:
                    root = ET.fromstring(z.read(ci))
                    rec["meta"]["comicinfo"] = {c.tag: c.text for c in root if c.text}
        except Exception as e:
            rec["meta"] = {"error": str(e)[:300]}
    elif k in ("audio", "video"):
        p = ffprobe(path)
        fmt = p.get("format", {})
        streams = p.get("streams", [])
        m = {"duration": round(float(fmt.get("duration", 0) or 0), 1),
             "bit_rate": int(fmt.get("bit_rate", 0) or 0),
             "tags": lower_tags(fmt.get("tags"))}
        if "error" in p:
            m["error"] = p["error"]
        if k == "video":
            v = next((s for s in streams if s.get("codec_type") == "video"), {})
            m.update({
                "video": f"{v.get('codec_name', '?')} {v.get('width', '?')}x{v.get('height', '?')}",
                "audio_langs": [lower_tags(s.get("tags")).get("language", "und") for s in streams if s.get("codec_type") == "audio"],
                "sub_langs": [lower_tags(s.get("tags")).get("language", "und") for s in streams if s.get("codec_type") == "subtitle"],
            })
            rec["guess"] = guess(path.name)
            ij = info_json_for(path)
            if ij:
                rec["info_json"] = ij
        else:
            # Only the fields a library needs; the full tag dump is noise.
            m["tags"] = {x: m["tags"][x] for x in
                         ("artist", "album_artist", "album", "title", "track", "disc", "date", "composer", "genre")
                         if x in m["tags"]}
        rec["meta"] = m
    elif k == "subtitle":
        rec["guess"] = guess(path.name)
    if want_hash:
        rec["sha256"] = sha256(path)
    return rec


def info_json_for(video):
    """yt-dlp's --write-info-json sidecar, if the video has one."""
    for cand in (video.with_suffix(".info.json"), video.parent / (video.stem + ".info.json")):
        if cand.exists():
            try:
                d = json.loads(cand.read_text())
            except Exception:
                return None
            return {k: d.get(k) for k in ("id", "title", "channel", "uploader", "upload_date", "extractor", "webpage_url")}
    return None


def walk(staging):
    """Files in a batch, relative paths, sorted. Dotfiles and OS junk excluded."""
    files, ignored = [], []
    for dirpath, dirnames, filenames in os.walk(staging):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        rel_dir = os.path.relpath(dirpath, staging)
        for d in os.listdir(dirpath):
            if d.startswith(".") and os.path.isdir(os.path.join(dirpath, d)):
                ignored.append(os.path.normpath(os.path.join(rel_dir, d)) + "/")
        for f in sorted(filenames):
            rel = os.path.normpath(os.path.join(rel_dir, f))
            if f in IGNORED_NAMES or f.startswith("._") or f.startswith("."):
                ignored.append(rel)
            else:
                files.append(rel)
    return files, ignored


def sidecar_paths(staging):
    s = str(Path(staging)).rstrip("/")
    return Path(s + ".manifest.jsonl"), Path(s + ".tsv"), Path(s + ".applied.jsonl")


def cmd_scan(a):
    with batch_lock(a.staging, "scan"):
        scan(a)


def scan(a):
    staging = Path(a.staging)
    manifest, _, _ = sidecar_paths(staging)
    files, ignored = walk(staging)
    kinds, recs = {}, []
    tmp = manifest.with_name(f".{manifest.name}.{os.getpid()}")
    with open(tmp, "w") as out:
        for i, rel in enumerate(files, 1):
            rec = scan_file(staging / rel, rel, a.hash)
            recs.append(rec)
            kinds[rec["kind"]] = kinds.get(rec["kind"], 0) + 1
            out.write(json.dumps(rec, ensure_ascii=False) + "\n")
            if sys.stderr.isatty():
                print(f"\r{i}/{len(files)}", end="", file=sys.stderr)
    os.replace(tmp, manifest)  # a concurrent check reads the old or the new, never half
    if sys.stderr.isatty():
        print(file=sys.stderr)
    print(f"{len(files)} files -> {manifest}")
    print("  by kind: " + ", ".join(f"{k} {n}" for k, n in sorted(kinds.items())))
    if ignored:
        print(f"  ignored (dotfiles, OS junk): {len(ignored)} — e.g. {ignored[0]}")
    audio = [r for r in recs if r["kind"] == "audio"]
    if audio:
        print("  audio tag coverage:")
        for t in ("artist", "album_artist", "album", "title", "track", "disc", "date"):
            n = sum(1 for r in audio if r["meta"]["tags"].get(t))
            print(f"    {t:13} {n}/{len(audio)}")
    errs = [r for r in recs if (r.get("meta") or {}).get("error")]
    for r in errs[:10]:
        print(f"  unreadable: {r['path']}: {r['meta']['error']}")
    if a.hash:
        by = {}
        for r in recs:
            by.setdefault(r["sha256"], []).append(r["path"])
        dups = [v for v in by.values() if len(v) > 1]
        print(f"  identical-content groups: {len(dups)}")
        for g in dups[:20]:
            print("    " + "  ==  ".join(g))


# --------------------------------------------------------------------------
# draft: the rules. Anything a rule cannot decide is left blank for review.

def clean(s):
    s = SMB_BAD.sub(" ", str(s)).replace("/", "-")
    s = re.sub(r"\s+", " ", s).strip().rstrip(".")
    return s


def person(name):
    """'Camus, Albert' -> 'Albert Camus'."""
    m = re.match(r"^([^,]+),\s*([^,]+)$", name.strip())
    return f"{m.group(2)} {m.group(1)}" if m else name.strip()


def ep_code(season, episode):
    eps = episode if isinstance(episode, list) else [episode]
    code = f"S{int(season):02d}E{int(eps[0]):02d}"
    if len(eps) > 1:
        code += f"-E{int(eps[-1]):02d}"
    return code


def title_clean(s):
    """A film or show title for a path: 'Alien: Covenant' -> 'Alien - Covenant'."""
    return clean(re.sub(r"\s*:\s+", " - ", str(s)))


# A TMDB id already in a source path: Radarr/Sonarr's "{tmdb-438631}", Jellyfin's
# "[tmdbid-438631]".
TMDB_IN_PATH = re.compile(r"[{\[]tmdb(?:id)?[-=](\d+)[}\]]", re.I)


def id_suffix(tmdb):
    return f" {{tmdb-{tmdb}}}" if tmdb else ""


def video_target(rec, lookup=None):
    """{'stem', 'conf', 'note', 'group', 'orig_lang'} — `stem` is the target
    without extension, relative to the library, or None when no rule decides.
    `group` names the film or episode, so copies of one can be ranked.
    `lookup(title, year, kind)` (draft --lookup) returns Wikidata's canonical
    title, year, TMDB id and original language, or None."""
    ij = rec.get("info_json")
    if ij and ij.get("id") and ij.get("upload_date"):
        ch = clean(ij.get("channel") or ij.get("uploader") or "Unknown channel")
        d = ij["upload_date"]
        date = f"{d[:4]}-{d[4:6]}-{d[6:8]}"
        return {"stem": f"youtube/{ch}/{date} - {clean(ij.get('title') or '')} [{ij['id']}]",
                "conf": "high", "note": "from yt-dlp info.json", "group": ("youtube", ij["id"])}
    g = rec.get("guess") or {}
    title = g.get("title") or ""
    if g.get("date") and "episode" not in g:
        return {"stem": None, "conf": "", "note": f"{title!r} episode named by air date {g['date']}: find its SxxEyy"}
    kind = {"episode": "tv", "movie": "movie"}.get(g.get("type"))
    if kind == "tv" and not ("season" in g and "episode" in g):
        kind = None
    if not title or not kind:
        return {"stem": None, "conf": "", "note": "not a recognisable movie/episode name"}
    year, conf, notes = g.get("year"), "medium", ["from file name (guessit)"]
    m = TMDB_IN_PATH.search(rec["path"])
    tmdb = m.group(1) if m else None
    orig_lang = None
    found = lookup(title, year, kind) if lookup else None
    if found:
        title, year, orig_lang = found["title"], found["year"], found.get("orig_lang")
        tmdb = tmdb or found["tmdb"]
        notes = [found["note"]]
        conf = found.get("conf", "medium")
        if m and m.group(1) != found["tmdb"]:
            conf, notes = "medium", notes + [f"check: the source path says tmdb {m.group(1)}"]
    elif lookup:
        notes.append("check: no single Wikidata match")
    title = title_clean(title)
    if kind == "tv":
        code = ep_code(g["season"], g["episode"])
        if not year:
            return {"stem": None, "conf": "", "note": f"episode of {title!r} {code}: show year unknown",
                    "group": ("tv", norm_title(title), None, code)}
        show = f"{title} ({year})"
        name = f"{show} - {code}" + (f" - {clean(g['episode_title'])}" if g.get("episode_title") else "")
        return {"stem": f"tv/{show}{id_suffix(tmdb)}/Season {int(g['season']):02d}/{name}", "conf": conf,
                "note": "; ".join(notes), "group": ("tv", norm_title(title), year, code), "orig_lang": orig_lang}
    if not year:
        return {"stem": None, "conf": "", "note": f"movie {title!r}? year unknown", "group": ("movie", norm_title(title), None)}
    folder = f"{title} ({year}){id_suffix(tmdb)}"
    edition = g.get("edition")
    stem = folder + (f" - {clean(edition if isinstance(edition, str) else ' '.join(edition))}" if edition else "")
    return {"stem": f"movies/{folder}/{stem}", "conf": conf, "note": "; ".join(notes),
            "group": ("movie", norm_title(title), year), "orig_lang": orig_lang}


# --------------------------------------------------------------------------
# Wikidata: canonical titles, years, TMDB ids and original languages, with no
# API key. Search is restricted to items that carry a TMDB id (P4947 film,
# P4983 series); a match must have the same title (spelling and punctuation
# aside) and, for a film, the same year. Anything else is no match.

WIKIDATA_API = "https://www.wikidata.org/w/api.php"
USER_AGENT = "media-stage/0.1 (https://github.com/natb1/nix-config)"


def http_json(params):
    import urllib.parse
    import urllib.request
    req = urllib.request.Request(WIKIDATA_API + "?" + urllib.parse.urlencode({**params, "format": "json"}),
                                 headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def norm_title(s):
    s = str(s or "").casefold().replace("&", " and ")
    s = re.sub(r"^(.*), (the|a|an)$", r"\2 \1", s.strip())
    return re.sub(r"[\W_]+", " ", s).strip()


def _claims(ent, prop, best=False):
    """A property's values; with `best`, only the preferred ones when any
    are (a film lists every language it was released in; the original is
    the preferred one)."""
    cs = [c for c in ent.get("claims", {}).get(prop, []) if c["mainsnak"].get("datavalue")
          and c.get("rank") != "deprecated"]
    if best and any(c.get("rank") == "preferred" for c in cs):
        cs = [c for c in cs if c.get("rank") == "preferred"]
    return [c["mainsnak"]["datavalue"]["value"] for c in cs]


def _years(ent, *props):
    ys = [int(v["time"][1:5]) for p in props for v in _claims(ent, p) if isinstance(v, dict) and "time" in v]
    return min(ys) if ys else None


class Wikidata:
    def __init__(self, fetch=http_json):
        self.fetch, self.cache, self.langs = fetch, {}, {}

    def __call__(self, title, year, kind):
        key = (norm_title(title), year, kind)
        if key not in self.cache:
            try:
                self.cache[key] = self._find(title, year, kind)
            except Exception as e:  # offline, rate-limited: the rules still apply
                print(f"  wikidata: {title!r}: {e}", file=sys.stderr)
                self.cache[key] = None
        return self.cache[key]

    def _find(self, title, year, kind):
        prop = "P4947" if kind == "movie" else "P4983"
        hits = self.fetch({"action": "query", "list": "search", "srnamespace": 0, "srlimit": 20,
                           "srsearch": f"{title} haswbstatement:{prop}"})["query"]["search"]
        if not hits:
            return None
        ents = self.fetch({"action": "wbgetentities", "ids": "|".join(h["title"] for h in hits),
                           "props": "labels|aliases|claims", "languages": "en|mul"})["entities"]
        want, exact, near = norm_title(title), [], []
        for qid, e in ents.items():
            # "mul" is Wikidata's label for names the same in every language
            # (South Park has no "en" label, only "mul").
            labels = e.get("labels", {})
            names = [(labels.get("en") or labels.get("mul") or {}).get("value", "")] + \
                    [a["value"] for lang in ("en", "mul") for a in e.get("aliases", {}).get(lang, [])]
            tmdb = next(iter(_claims(e, prop)), None)
            if not tmdb or want not in {norm_title(n) for n in names if n}:
                continue
            y = _years(e, "P577") if kind == "movie" else (_years(e, "P580") or _years(e, "P577"))
            hit = {"qid": qid, "title": names[0] or title, "year": y, "tmdb": str(tmdb), "ent": e}
            if year is None or y == year:
                exact.append(hit)
            elif y and abs(y - year) == 1:
                near.append(hit)
        pick, conf, note = None, "high", ""
        if len(exact) == 1:
            pick = exact[0]
            note = f"Wikidata {pick['qid']}" + ("" if year else f" (the one {kind} of that name)")
        elif not exact and len(near) == 1:
            pick, conf = near[0], "medium"
            note = f"check: Wikidata {pick['qid']} is {pick['year']}, the name says {year}"
        if not pick or not pick["year"]:
            return None
        return {"title": pick["title"], "year": pick["year"], "tmdb": pick["tmdb"], "conf": conf, "note": note,
                "orig_lang": self._lang(pick["ent"])}

    def _lang(self, ent):
        """ISO 639 codes (639-1, -2 and -3) of the original language(s) (P364)."""
        codes = set()
        for q in (v["id"] for v in _claims(ent, "P364", best=True) if isinstance(v, dict) and "id" in v):
            if q not in self.langs:
                e = self.fetch({"action": "wbgetentities", "ids": q, "props": "claims"})["entities"][q]
                self.langs[q] = {c for p in ("P218", "P219", "P220") for c in _claims(e, p) if isinstance(c, str)}
            codes |= self.langs[q]
        return sorted(codes) or None


# --------------------------------------------------------------------------
# Copies: one film or episode kept per batch, the best of its copies.

SOURCE_RANK = [  # guessit's `source`, worst first
    ({"camera", "hd camera", "telesync", "hd telesync", "telecine", "workprint", "screener"}, 0),
    ({"vhs", "tv", "hdtv", "ultra hdtv", "satellite", "digital tv"}, 2),
    ({"dvd", "video on demand"}, 3),
    ({"web", "hd-dvd"}, 4),
    ({"blu-ray", "ultra hd blu-ray"}, 5),
]


def source_rank(g):
    src = g.get("source")
    src = (src[0] if isinstance(src, list) else src or "").casefold()
    return next((r for names, r in SOURCE_RANK if src in names), 3)


def video_height(rec):
    """The resolution class: 2160, 1080, 720, 576 or 480 — by width as much
    as height, so a letterboxed 1920x800 film is 1080p."""
    m = re.search(r"(\d+)x(\d+)", (rec.get("meta") or {}).get("video", ""))
    if not m:
        return 0
    w, h = int(m.group(1)), int(m.group(2))
    for cls, minw, minh in ((2160, 3200, 1800), (1080, 1600, 900), (720, 1120, 650), (576, 700, 540)):
        if w >= minw or h >= minh:
            return cls
    return 480


def audio_langs(rec):
    return {l for l in (rec.get("meta") or {}).get("audio_langs", []) if l not in ("und", "")}


def rank(rec, orig_lang, has_subs):
    """A sort key: higher is the better copy. Original-language audio first
    (when the original is known and a copy says what it has), then not a cam,
    then resolution, then subtitles, source and bit rate."""
    langs = audio_langs(rec)
    lang = 1 if not orig_lang or not langs else (2 if langs & set(orig_lang) else 0)
    g = rec.get("guess") or {}
    return (lang, source_rank(g) > 0, video_height(rec), has_subs, source_rank(g),
            (rec.get("meta") or {}).get("bit_rate", 0))


def describe(rec):
    g = rec.get("guess") or {}
    src = g.get("source")
    src = src[0] if isinstance(src, list) else src
    bits = [f"{video_height(rec)}p" if video_height(rec) else "?p", src or "source?",
            f"{(rec.get('meta') or {}).get('bit_rate', 0) // 1000} kb/s",
            "audio " + ("/".join(sorted(audio_langs(rec))) or "und")]
    return " ".join(bits)


def rank_copies(groups, recs, rows, stems, has_subs):
    """Keep the best copy of each film or episode; the rest are `discard`
    when plainly worse (a cam, a lower resolution, the wrong language) and
    `trash` when it is a matter of taste (same resolution, another encode)."""
    for key, members in groups.items():
        if len(members) < 2:
            continue
        orig = next((o for _, o in members if o), None)
        ranked = sorted(members, key=lambda m: rank(recs[m[0]], orig, has_subs(m[0])), reverse=True)
        best = ranked[0][0]
        brec = recs[best]
        brank = rank(brec, orig, has_subs(best))
        langs = {frozenset(audio_langs(recs[p])) for p, _ in members} - {frozenset()}
        for p, _ in ranked[1:]:
            r = rank(recs[p], orig, has_subs(p))
            plainly = r[0] < brank[0] or r[1] < brank[1] or r[2] < brank[2]
            verdict = "discard" if plainly else "trash"
            why = f"{'worse' if plainly else 'other'} copy of {best} ({describe(recs[p])} vs {describe(brec)})"
            if recs[p].get("sha256") and recs[p]["sha256"] == brec.get("sha256"):
                verdict, why = "discard", f"identical to {best}"
            elif len(langs) > 1 and not orig:
                verdict, why = "trash", why + "; check: audio languages differ and the original is unknown"
            rows[p] = [verdict, "medium", why]
            stems[str(Path(p).with_suffix(""))] = verdict
        if len(langs) > 1 and not orig:
            rows[best][1] = "medium"
            rows[best][2] += "; check: copies differ in audio language, original unknown"
        if rows[best][0] and rows[best][0] not in ("discard", "trash"):
            rows[best][2] += f"; best of {len(members)} copies"


# --------------------------------------------------------------------------
# Filed copies: a staged file whose content is already in the library. apply
# rewrites what it files (a book's or RPG's metadata, rewritten whole; a
# video's title, set in place or by a remux), so a filed file rarely hashes
# like its source. Three ways to still recognise it:
#   - the sha256 apply logged of the source, in any batch's applied.jsonl;
#   - a book or RPG file's own record of it (SOURCE, in its metadata);
#   - for a PDF titled before apply wrote clean files, the library file
#     begins with the source's exact bytes (exiftool appended an update).

PREFIX_SLACK = 256 * 1024  # what an incremental PDF update may append


class FiledIndex:
    def __init__(self, library, staging_root=None):
        self.library = Path(library)
        self.logged, self.by_ext, self.sources = {}, None, None
        for log in sorted(Path(staging_root or self.library / "staging").glob("*.applied.jsonl")):
            for line in log.read_text().splitlines():
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("sha256") and e.get("new") not in (None, "discard", "trash"):
                    self.logged[e["sha256"]] = e["new"]

    def _files(self):
        if self.by_ext is None:
            self.by_ext = {}
            for top in LIBRARY_DIRS:
                for dirpath, dirnames, filenames in os.walk(self.library / top):
                    dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                    for f in filenames:
                        if not f.startswith("."):
                            p = Path(dirpath) / f
                            self.by_ext.setdefault(ext_of(f), []).append((p.stat().st_size, p))
        return self.by_ext

    def _sources(self):
        """sha256 of the original -> library path, from what books and RPG
        files record of themselves (apply rewrites them)."""
        if self.sources is None:
            self.sources = {}
            for ext in SHELF_KINDS:
                for _, p in self._files().get(ext, []):
                    rel = str(p.relative_to(self.library))
                    if rel.split("/")[0] in ("books", "rpg"):
                        src = current_meta(p).get("source")
                        if src:
                            self.sources[src] = rel
        return self.sources

    def find(self, rel_ext, size, digest):
        """The library path holding this content, or None."""
        hit = self.logged.get(digest)
        if hit and (self.library / hit).exists():
            return hit
        if rel_ext in SHELF_KINDS and digest in self._sources():
            return self._sources()[digest]
        for fsize, p in self._files().get(rel_ext, []):
            same = fsize == size
            prefix = rel_ext == "pdf" and size < fsize <= size + PREFIX_SLACK
            if (same or prefix) and prefix_sha256(p, size) == digest:
                return str(p.relative_to(self.library))
        return None


def prefix_sha256(path, n):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while n > 0:
            block = f.read(min(n, 1 << 20))
            if not block:
                break
            h.update(block)
            n -= len(block)
    return h.hexdigest()


def sub_suffix(suffix):
    """'.eng.srt' -> '.en.srt', '.English.srt' -> '.en.srt', '.srt' -> '.en.srt'
    is not assumed: an untagged subtitle keeps its bare suffix."""
    m = re.match(r"^\.(?:(eng|english|en))(\..+)$", suffix, re.I)
    return f".en{m.group(2)}" if m else suffix


def library_video_for(library, group):
    """A library video that is already this film or episode, or None.
    `group` is video_target's: ("movie", title, year) or ("tv", title, year, SxxEyy)."""
    if group[0] not in ("movie", "tv") or not group[2]:
        return None
    kind, title, year = group[:3]
    base = Path(library) / ("movies" if kind == "movie" else "tv")
    for d in (base.iterdir() if base.is_dir() else []):
        m = re.match(r"^(.*) \((\d{4})\)( \{tmdb-\d+\})?$", d.name)
        if not m or int(m.group(2)) != year or norm_title(m.group(1)) != title:
            continue
        for f in (d.iterdir() if kind == "movie" else d.rglob(f"* - {group[3]}*")):
            if ext_of(f.name) in VIDEO_EXT:
                return str(f.relative_to(library))
    return None


def cmd_draft(a):
    with batch_lock(a.staging, "draft"):
        draft(a)


def draft(a, lookup=None):
    staging = Path(a.staging)
    library = Path(a.library) if getattr(a, "library", None) else find_library()
    if lookup is None and getattr(a, "lookup", False):
        lookup = Wikidata()
    manifest, table, _ = sidecar_paths(staging)
    # An existing table holds review work: keep its rows as they are and only
    # add rows for files it does not list yet (a batch that grew since).
    keep_header, kept = None, {}
    if table.exists() and not a.force:
        with open(table) as f:
            keep_header = f.readline().rstrip("\n").split("\t")
            for line in f:
                if line.strip():
                    kept[line.rstrip("\n").split("\t")[keep_header.index("old")]] = line.rstrip("\n")
    recs = {r["path"]: r for r in (json.loads(l) for l in Path(manifest).read_text().splitlines() if l)}
    filed = FiledIndex(library, staging.parent) if library else None
    rows, stems, groups = {}, {}, {}
    # A show's year from the batch's other episodes, when they agree on one.
    years = {}
    for r in recs.values():
        g = r.get("guess") or {}
        if r["kind"] == "video" and g.get("type") == "episode" and g.get("title") and g.get("year"):
            years.setdefault(norm_title(g["title"]), set()).add(g["year"])
    for r in recs.values():
        g = r.get("guess") or {}
        if r["kind"] == "video" and g.get("type") == "episode" and g.get("title") and not g.get("year"):
            known = years.get(norm_title(g["title"]), set())
            if len(known) == 1:
                g["year"] = next(iter(known))
    # Pass 1: primary files.
    for p, r in recs.items():
        k = r["kind"]
        new, conf, note = "", "", ""
        if k == "video":
            t = video_target(r, lookup)
            conf, note = t["conf"], t["note"]
            if t["stem"]:
                new = f"{t['stem']}.{r['ext']}"
                stems[str(Path(p).with_suffix(""))] = t["stem"]
            if t.get("group"):
                groups.setdefault(t["group"], []).append((p, t.get("orig_lang")))
        elif k == "audio":
            new, conf, note = "beets", "", "music: imported by beets"
        elif k == "epub":
            m = r.get("meta", {})
            if m.get("title") and m.get("creators"):
                title = clean(re.split(r"[:;]", m["title"])[0])
                author = clean(person(m["creators"][0]))
                if m.get("series") and m.get("volume"):
                    series = clean(m["series"])
                    new = f"books/{author}/{series}/{series} Vol. {num(m['volume'])} - {title}.epub"
                else:
                    new = f"books/{author}/{title}/{title}.epub"
                conf, note = "medium", "from EPUB metadata"
            else:
                note = "EPUB has no title/creator: " + json.dumps(m, ensure_ascii=False)[:200]
        elif k in ("pdf", "cbz", "document"):
            m = r.get("meta", {})
            bits = [f"{x}={m[x]}" for x in ("Title", "Author", "Creator", "Pages", "Page size") if m.get(x)]
            text = r.get("text", "")
            note = "classify (books/ or rpg/): " + "; ".join(bits) + (f"; text: {text[:160]}" if text else "")
        else:
            note = f"{k}: classify, or `skip`"
        rows[p] = [new, conf, note]
    # Content already in the library is not filed twice.
    for p, r in recs.items():
        if filed and r.get("sha256") and r["kind"] != "audio":
            hit = filed.find(r["ext"], r["size"], r["sha256"])
            if hit:
                rows[p] = ["discard", "high", f"already filed as {hit}"]
                stems[str(Path(p).with_suffix(""))] = "discard"
    # One copy of each film or episode: the best one.
    def has_subs(p):
        stem = Path(p).with_suffix("").name
        side = any(q != p and Path(q).parent == Path(p).parent and Path(q).name.startswith(stem + ".")
                   and recs[q]["kind"] == "subtitle" for q in recs)
        return side or bool((recs[p].get("meta") or {}).get("sub_langs"))
    live = {g: [m for m in ms_ if rows[m[0]][0] != "discard"] for g, ms_ in groups.items()}
    rank_copies(live, recs, rows, stems, has_subs)
    for g, members in live.items():
        hit = library_video_for(library, g) if library else None
        for p, _ in members:
            if hit and rows[p][0] not in ("discard", "trash"):
                rows[p] = ["trash", "medium", f"check: the library already has this: {hit}; " + rows[p][2]]
                stems[str(Path(p).with_suffix(""))] = "trash"
    # A dropped copy's subtitles go with the kept copy when the two run the
    # same length (the same cut; the timings fit), and the kept copy has none.
    adopt = {}
    for members in live.values():
        keep = [p for p, _ in members if rows[p][0] not in ("discard", "trash")]
        if len(keep) != 1 or not rows[keep[0]][0] or has_subs(keep[0]):
            continue
        k = keep[0]
        for p, _ in members:
            dur = lambda q: (recs[q].get("meta") or {}).get("duration") or 0
            if p != k and has_subs(p) and dur(k) and abs(dur(p) - dur(k)) <= 2:
                adopt[str(Path(p).with_suffix(""))] = stems[str(Path(k).with_suffix(""))]
                break
    # Pass 2: sidecars follow their video (subtitles, info.json, thumbnails).
    for p, r in recs.items():
        if p.endswith(".nfo") and "<" not in (staging / p).read_text(errors="replace")[:200]:
            rows[p] = ["discard", "medium", "a release group's .nfo, not Kodi metadata"]
            continue
        if r["kind"] in ("subtitle", "infojson", "image") or p.endswith(".nfo"):
            name = Path(p).name
            parent = str(Path(p).parent)
            for vstem, target in stems.items():
                vname = Path(vstem).name
                if str(Path(vstem).parent) == parent and name.startswith(vname + ".") and name != vname:
                    suffix = name[len(vname):]
                    if vstem in adopt and r["kind"] == "subtitle":
                        rows[p] = [adopt[vstem] + sub_suffix(suffix), "medium",
                                   "subtitle of a dropped copy of the same length; check: timing"]
                    elif target in ("discard", "trash"):
                        rows[p] = [target, "medium", "follows its video"]
                    else:
                        rows[p] = [target + suffix.lower() if r["kind"] != "subtitle" else target + suffix,
                                   "medium", "follows its video"]
                    break
            else:
                if r["kind"] == "subtitle":
                    rows[p][2] = "subtitle with no matching video"
    header = keep_header or ["old", "new", "confidence", "note"]
    added = {p: v for p, v in rows.items() if p not in kept}
    tmp = table.with_name(f".{table.name}.{os.getpid()}")
    with open(tmp, "w") as out:
        out.write("\t".join(header) + "\n")
        for line in kept.values():
            out.write(line + "\n")
        for p, (new, conf, note) in added.items():
            cols = {"old": p, "new": new, "confidence": conf, "note": note}
            out.write("\t".join(cols.get(h, "").replace("\t", " ").replace("\n", " ") for h in header) + "\n")
    os.replace(tmp, table)  # readers never see half a table
    blank = sum(1 for v in added.values() if not v[0])
    dup = sum(1 for v in added.values() if v[0] in ("discard", "trash"))
    extra = f"; {dup} copies set aside (discard/trash)" if dup else ""
    if kept:
        print(f"kept {len(kept)} rows, added {len(added)} -> {table}; {blank} new rows left blank for review{extra}")
    else:
        print(f"{len(added)} rows -> {table}; {blank} left blank for review{extra}")


# --------------------------------------------------------------------------
# group: a flat folder of audio into one folder per album, for beets
# (`beet stage-review` imports folder by folder, so each answer names one).

# "Artist - Album - 04 Title.mp3", "Artist - Album (2000) - 04 - Title.mp3"
AUDIO_NAME = re.compile(r"^(?P<artist>.+?) - (?P<album>.+) - (?P<track>\d{1,3})(?: - |\.? )(?P<title>.+)\.[^.]+$")
# "Album CD2", "Album (Disc 2)", "Album [disk 2]", a folder named "CD2"
DISC_MARKER = re.compile(r"^(?P<base>.*?)[\s_-]*[(\[]?\b(?:cd|disc|disk)[\s_-]*(?P<disc>\d{1,2})[)\]]?\s*$", re.I)


def split_disc(name):
    """("Album", 2) for "Album CD2"; (name, None) without a disc marker."""
    m = DISC_MARKER.match(name or "")
    return (m.group("base"), int(m.group("disc"))) if m else (name, None)


def _int(v):
    m = re.match(r"\s*(\d+)", str(v or ""))
    return int(m.group(1)) if m else None


def cmd_group(a):
    with batch_lock(a.staging, "group"):
        group(a)


def group(a):
    """One folder per album, decided by the files' own tags, wherever they
    sit in the batch. beets decides albums by folder, and on its own merges
    sibling folders named like discs ("… CD1", "… CD2") whatever they hold;
    `beet stage-review` imports each folder by itself, so this is the only
    place albums are merged, and each merge is logged to STAGING.group.json
    for the review page to show."""
    staging = Path(a.staging)
    recs = load_manifest(staging)
    if recs is None:
        sys.exit(f"{staging}: no manifest; run `media-stage scan` first")
    groups = {}  # (album artist, album) -> {"base", "artist", "files": [(rel, disc)]}
    for rel, r in sorted(recs.items()):
        if r["kind"] != "audio":
            continue
        tags = (r.get("meta") or {}).get("tags", {})
        name = AUDIO_NAME.match(Path(rel).name)
        parent = Path(rel).parent.name if "/" in rel else ""
        pbase, pdisc = split_disc(parent)
        album = tags.get("album") or (name and name.group("album")) or pbase or "_loose"
        base, tdisc = split_disc(album)
        base = clean(base) or clean(pbase) or "_loose"
        disc = _int(tags.get("disc")) or tdisc or pdisc or 1
        artist = tags.get("album_artist") or ""
        g = groups.setdefault((artist.casefold(), base.casefold()), {"base": base, "artist": artist, "files": []})
        g["files"].append((rel, disc))
    taken = {}
    for key, g in sorted(groups.items()):
        folder = g["base"]
        if folder.casefold() in taken:
            folder = clean(f"{g['base']} ({g['artist'] or 'no album artist'})")
        taken[folder.casefold()] = key
        g["folder"] = folder

    log_path = Path(str(staging).rstrip("/") + ".group.json")
    log = json.loads(log_path.read_text()) if log_path.exists() else {}
    moved, stuck = 0, []
    for g in groups.values():
        discs = sorted({d for _, d in g["files"]})
        origins = sorted({str(Path(rel).parent) for rel, _ in g["files"]})
        for rel, disc in g["files"]:
            fname = Path(rel).name
            if len(discs) > 1 and not re.match(rf"^0?{disc}-", fname):
                fname = f"{disc}-{fname}"
            dst = Path(g["folder"]) / fname
            if dst.as_posix() == rel:
                continue
            (staging / g["folder"]).mkdir(exist_ok=True)
            try:
                move_noclobber(staging / rel, staging / dst)
                moved += 1
            except FileExistsError:
                stuck.append(rel)
        if len(origins) > 1 or len(discs) > 1:
            prev = log.get(g["folder"], {})
            log[g["folder"]] = {
                "from": sorted(set(prev.get("from", [])) | set(origins)),
                "discs": sorted(set(prev.get("discs", [])) | set(discs)),
            }
    # Folders the moves emptied; never the batch itself or a dot-folder.
    for dirpath, _, _ in os.walk(staging, topdown=False):
        p = Path(dirpath)
        if p != staging and not any(x.startswith(".") for x in p.relative_to(staging).parts):
            if not [f for f in os.listdir(p) if f not in IGNORED_NAMES]:
                shutil.rmtree(p)
    if log:
        log_path.write_text(json.dumps(log, indent=1, ensure_ascii=False))
    merged = [f for f, v in log.items() if len(v["from"]) > 1]
    print(f"grouped {moved} files into {len(groups)} album folders; "
          f"{len(merged)} made from more than one folder (-> {log_path.name})")
    for f in merged:
        print(f"  {f}: " + ", ".join(log[f]["from"]))
    for rel in stuck:
        print(f"  not moved, a file of that name is already there: {rel}")
    a.hash = False
    scan(a)


# --------------------------------------------------------------------------
# review: what a person decides, as a file the review page shows, and back.
# The shape is shared with beets' `stage-review` (beetsplug/stagereview.py).

REVIEW_FLAG = re.compile(r"\b(check|guess|guessed|likely|unsure|unknown)\b|\?", re.I)


def review_id(key):
    return hashlib.sha1(key.encode()).hexdigest()[:12]


def read_table_full(table):
    with open(table) as f:
        header = f.readline().rstrip("\n").split("\t")
        rows = []
        for line in f:
            if line.strip():
                cols = line.rstrip("\n").split("\t")
                rows.append(dict(zip(header, cols + [""] * (len(header) - len(cols)))))
    return header, rows


def write_table(table, header, rows):
    tmp = table.with_name(f".{table.name}.{os.getpid()}")
    with open(tmp, "w") as out:
        out.write("\t".join(header) + "\n")
        for r in rows:
            out.write("\t".join(str(r.get(h, "")).replace("\t", " ").replace("\n", " ") for h in header) + "\n")
    os.replace(tmp, table)


def needs_review(row):
    new, conf, note = row.get("new", ""), row.get("confidence", ""), row.get("note", "")
    if conf == "reviewed" or new == "beets" or (new == "discard" and conf == "high"):
        return False
    return (not new or new == "skip" or (conf and conf != "high") or bool(REVIEW_FLAG.search(note)))


def evidence(rec):
    ev = [{"label": "Size", "value": f"{rec.get('size', 0) / 1e6:.1f} MB"}]
    m = rec.get("meta") or {}
    if rec["kind"] in ("pdf", "cbz", "document"):
        for k in ("Title", "Author", "Creator", "Producer", "Pages", "Page size"):
            if m.get(k):
                ev.append({"label": k, "value": str(m[k])})
    elif rec["kind"] == "epub":
        for k in ("title", "creators", "publisher", "language", "identifiers"):
            if m.get(k):
                ev.append({"label": k.capitalize(), "value": ", ".join(m[k]) if isinstance(m[k], list) else str(m[k])})
    elif rec["kind"] == "video":
        for k in ("duration", "width", "height", "title"):
            if m.get(k):
                ev.append({"label": k.capitalize(), "value": str(m[k])})
        if rec.get("guess"):
            ev.append({"label": "Name reads as", "value": ", ".join(f"{k} {v}" for k, v in rec["guess"].items()
                                                                  if k in ("title", "year", "season", "episode", "type", "edition"))})
        ij = rec.get("info_json") or {}
        if ij:
            ev.append({"label": "yt-dlp", "value": f"{ij.get('channel') or ij.get('uploader')}: {ij.get('title')} ({ij.get('upload_date')})"})
    if rec.get("text"):
        ev.append({"label": "First pages", "value": re.sub(r"\s+", " ", rec["text"])[:700]})
    return ev


def cmd_review(a):
    staging = Path(a.staging)
    _, table, _ = sidecar_paths(staging)
    if a.action == "export":
        return review_export(a, staging, table)
    with batch_lock(staging, "review import"):
        review_import(a, staging, table)


def review_export(a, staging, table):
    header, rows = read_table_full(table)
    recs = load_manifest(staging) or {}
    items = []
    for r in rows:
        if not needs_review(r):
            continue
        old, new, note = r["old"], r.get("new", ""), r.get("note", "")
        rec = recs.get(old, {"kind": kind_of(old), "size": 0})
        why = "no place proposed" if not new else "set aside (skip)" if new == "skip" else \
            "another copy is kept" if new in ("discard", "trash") else \
            f"confidence {r['confidence']}" if r.get("confidence") and r["confidence"] != "high" else "flagged in the note"
        if new in ("discard", "trash"):
            options = [{"value": new, "recommended": True, "detail": note,
                        "label": "Delete it" if new == "discard" else "Move it to staging/trash"},
                       {"value": "trash" if new == "discard" else "discard", "detail": "",
                        "label": "Move it to staging/trash" if new == "discard" else "Delete it"}]
        else:
            options = [] if new in ("", "skip") else [
                {"value": "path:" + new, "label": new, "detail": note, "recommended": True}]
        items.append({
            "id": review_id(old), "key": old, "kind": rec["kind"],
            "title": Path(old).name, "subtitle": rec["kind"] + (f" · {Path(old).parent}" if "/" in old else ""),
            "why": why, "note": note, "evidence": evidence(rec), "options": options,
            "custom": {"kind": "path", "label": "Somewhere else in the library", "fields": [
                {"key": "new", "label": "Library path", "value": "" if new in ("skip", "discard", "trash") else new}]},
        })
    out = Path(str(staging).rstrip("/") + ".review.json")
    out.write_text(json.dumps({
        "batch": staging.name, "kind": "table", "source": "media-stage",
        "created": datetime.datetime.now().isoformat(timespec="seconds"),
        "layout": LAYOUT_HELP, "items": items,
    }, indent=1, ensure_ascii=False))
    print(f"for review: {len(items)} of {len(rows)} rows -> {out}")


LAYOUT_HELP = [
    "movies/<Title> (<Year>) {tmdb-<id>}/<Title> (<Year>) {tmdb-<id>}[ - <edition>].<ext>",
    "tv/<Show> (<Year>) {tmdb-<id>}/Season NN/<Show> (<Year>) - SxxEyy[ - <episode title>].<ext>",
    "youtube/<channel>/<YYYY-MM-DD> - <title> [<video id>].<ext>",
    "books/<author>/<series or title>/<title>[ (<variant>)].<ext>",
    "books/<author>/<series>/<series> Vol. <N>[ - <title>].<ext>",
    "rpg/<game>/<title>[ (<variant>)].<ext>  (a version is 'version 1.1', never 'v1.1')",
]


def load_answers(where, batch):
    """Answer documents under `where` (a file or a directory of exported
    documents) for this batch, keyed by item id. A document may be wrapped
    in {"data": ...}, as an export may write it."""
    p = Path(where)
    files = [p] if p.is_file() else sorted(p.rglob("*.json"))
    out = {}
    for f in files:
        doc = json.loads(f.read_text())
        for d in doc if isinstance(doc, list) else [doc]:
            if isinstance(d.get("data"), dict):
                d = d["data"]
            if d.get("batch") == batch and d.get("item") and d.get("choice"):
                out[d["item"]] = d
    return out


def review_import(a, staging, table):
    header, rows = read_table_full(table)
    answers = load_answers(a.answers, staging.name)
    if "confidence" not in header:
        header.insert(header.index("new") + 1, "confidence")
    done = 0
    for r in rows:
        ans = answers.get(review_id(r["old"]))
        if not ans:
            continue
        if ans["choice"] == "skip":
            new = "skip"
        elif ans["choice"] == "custom":
            new = ((ans.get("fields") or {}).get("new") or "").strip()
        else:
            new = str(ans.get("value", ""))
            new = new[5:] if new.startswith("path:") else new
        if not new:
            print(f"  {r['old']}: answer has no path; left as it was")
            continue
        r["new"], r["confidence"] = new, "reviewed"
        if ans.get("note"):
            r["note"] = (r.get("note", "") + " · reviewer: " + ans["note"]).strip(" ·")
        done += 1
    write_table(table, header, rows)
    left = sum(1 for r in rows if needs_review(r))
    print(f"answers applied: {done}; still to review: {left} -> {table}")


# --------------------------------------------------------------------------
# check / apply

def read_table(table):
    with open(table) as f:
        header = f.readline().rstrip("\n").split("\t")
        if "old" not in header or "new" not in header:
            sys.exit(f"{table}: header must name 'old' and 'new' columns")
        io, inew = header.index("old"), header.index("new")
        rows = []
        for n, line in enumerate(f, 2):
            if not line.strip():
                continue
            cols = line.rstrip("\n").split("\t")
            cols += [""] * (len(header) - len(cols))
            rows.append((n, cols[io].strip(), cols[inew].strip()))
    return rows


def find_library():
    env = os.environ.get("MEDIA_LIBRARY")
    if env:
        return Path(env)
    for p in ("/srv/media", "/Volumes/media"):
        if Path(p).is_dir():
            return Path(p)
    return None


def default_library():
    return find_library() or sys.exit("no library root: pass --library or set MEDIA_LIBRARY")


# --------------------------------------------------------------------------
# Concurrency. desk and the Mac (over SMB) may both run this against one
# library. Two locks, both plain files created with O_EXCL — atomic on a local
# disk and over SMB alike (the server does the create), unlike fcntl locks,
# which macOS's SMB client does not reliably carry:
#   staging/<batch>.lock   one writer per batch: scan, draft, apply
#   <library>/.media-stage.lock   one writer into the library: apply, tag, lint --fix
# Moves under the library lock also refuse to replace anything, so a writer
# that skipped the lock (Finder, a hand `mv`) still cannot be overwritten.

class Lock:
    def __init__(self, path, what):
        self.path, self.what = Path(path), what

    def __enter__(self):
        for attempt in (1, 2):
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
                break
            except FileExistsError:
                holder = self._holder()
                if attempt == 1 and self._stale(holder):
                    self.path.unlink(missing_ok=True)
                    continue
                sys.exit(f"locked: {self.path}\n  held by: {holder or '?'}\n"
                         "  wait for it, or delete the file if that process is gone")
            except (PermissionError, OSError) as e:
                if not isinstance(e, PermissionError) and e.errno != errno.EROFS:
                    raise
                # The library share is read-only over SMB (hosts/desk/media.nix).
                sys.exit(f"cannot write {self.path}: {e.strerror}\n"
                         "  from the Mac the library is read-only: run this on desk, e.g.\n"
                         "  ssh desk media-stage apply /srv/media/staging/<batch>")
        with os.fdopen(fd, "w") as f:
            f.write(f"{socket.gethostname()} {os.getpid()} {self.what} "
                    f"{datetime.datetime.now().isoformat(timespec='seconds')}\n")
        return self

    def __exit__(self, *exc):
        self.path.unlink(missing_ok=True)

    def _holder(self):
        try:
            return self.path.read_text().strip()
        except OSError:
            return ""

    @staticmethod
    def _stale(holder):
        """Only provable here: a lock from this host whose process is gone."""
        parts = holder.split()
        if len(parts) < 2 or parts[0] != socket.gethostname() or not parts[1].isdigit():
            return False
        try:
            os.kill(int(parts[1]), 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        return False


def trash_dir(staging):
    """Where `trash` rows go: staging/trash/<batch>/, on the writable share,
    so the user can look through them from the Mac and delete them there."""
    return Path(staging).parent / "trash" / Path(staging).name


def batch_lock(staging, what):
    return Lock(str(Path(staging)).rstrip("/") + ".lock", what)


def library_lock(library, what):
    return Lock(Path(library) / ".media-stage.lock", what)


def move_noclobber(src, dst):
    """Move, failing with FileExistsError rather than replacing `dst`.
    link() is the atomic no-replace primitive; where there are no hard links
    (the Mac's SMB mount, a second filesystem) fall back to check-then-rename,
    which the library lock makes safe against every other media-stage."""
    try:
        os.link(src, dst)
    except FileExistsError:
        raise
    except OSError:
        if os.path.lexists(dst):
            raise FileExistsError(dst)
        try:
            os.rename(src, dst)
        except OSError:
            shutil.move(src, dst)
        return
    os.unlink(src)


class CaseIndex:
    """Finds a target that differs from an existing path only by case. The Mac
    sees the share case-insensitively and desk's disk does not, so
    `The Wire (2002)` and `The wire (2002)` would be two folders on one host
    and one on the other."""

    def __init__(self, library):
        self.library, self.cache = Path(library), {}

    def clash(self, rel):
        cur = self.library
        for part in Path(rel).parts:
            if cur not in self.cache:
                try:
                    self.cache[cur] = {n.casefold(): n for n in os.listdir(cur)}
                except (FileNotFoundError, NotADirectoryError):
                    return None
            hit = self.cache[cur].get(part.casefold())
            if hit is None:
                return None
            if hit != part:
                return str((cur / hit).relative_to(self.library))
            cur = cur / hit
        return None


def load_manifest(staging):
    manifest, _, _ = sidecar_paths(staging)
    if not manifest.exists():
        return None
    recs = [json.loads(l) for l in manifest.read_text().splitlines() if l.strip()]
    return {r["path"]: r for r in recs}


def validate(staging, library):
    """(errors, rows to move, counts). Errors are strings; empty means go."""
    _, table, _ = sidecar_paths(staging)
    if not table.exists():
        return [f"no table at {table}; run draft first"], [], {}
    rows = read_table(table)
    files, _ = walk(staging)
    present = set(files)
    manifest = load_manifest(staging) or {}
    cases = CaseIndex(library)
    filed = FiledIndex(library, staging.parent)
    errors, moves, seen_new = [], [], {}
    counts = {"move": 0, "beets": 0, "skip": 0, "discard": 0, "trash": 0, "done": 0}
    seen_fold = {}
    listed = set()
    for n, old, new in rows:
        where = f"line {n} ({old})"
        if old in listed:
            errors.append(f"{where}: listed twice")
        listed.add(old)
        if not new:
            errors.append(f"{where}: `new` is blank — classify it, or write `skip`")
            continue
        if new in ("beets", "skip", "discard", "trash"):
            if new == "beets" and kind_of(old) != "audio":
                errors.append(f"{where}: `beets` is for audio only")
            if old not in present:
                if new in ("discard", "trash"):
                    counts["done"] += 1  # set aside by an earlier apply
                    continue
                errors.append(f"{where}: not in staging")
            if new == "trash" and (trash_dir(staging) / old).exists():
                errors.append(f"{where}: already in {trash_dir(staging)}")
            if new in ("discard", "trash"):
                moves.append((old, new))
            counts[new] += 1
            continue
        if ext_of(old) != ext_of(new):
            errors.append(f"{where}: extension changes to .{ext_of(new)}")
        why = layout_error(new)
        if why:
            errors.append(f"{where}: {new}: {why}")
        if new in seen_new:
            errors.append(f"{where}: same target as line {seen_new[new]}: {new}")
        elif new.casefold() in seen_fold:
            errors.append(f"{where}: differs only in case from line {seen_fold[new.casefold()]}: {new}")
        seen_new[new] = n
        seen_fold.setdefault(new.casefold(), n)
        target = library / new
        if old not in present:
            if target.exists():
                counts["done"] += 1  # moved by an earlier apply
            else:
                errors.append(f"{where}: not in staging")
            continue
        if target.exists():
            same = target.stat().st_size == (staging / old).stat().st_size and sha256(target) == sha256(staging / old)
            errors.append(f"{where}: target exists{' with identical content — use `skip`' if same else ''}: {new}")
            continue
        clash = cases.clash(new)
        if clash:
            errors.append(f"{where}: differs only in case from existing {clash}")
        # A file that changed since the scan was still being copied (Finder
        # writes under the final name) or has been edited: its manifest, and
        # so the review, are about a different file.
        rec = manifest.get(old)
        st = (staging / old).stat()
        if rec is None:
            errors.append(f"{where}: not in the manifest — scan again")
        elif rec["size"] != st.st_size or abs(rec.get("mtime_epoch", st.st_mtime) - st.st_mtime) > 2:
            errors.append(f"{where}: changed since scan (still copying?) — scan again")
        elif rec.get("sha256") and kind_of(old) != "audio":
            hit = filed.find(ext_of(old), rec["size"], rec["sha256"])
            if hit:
                errors.append(f"{where}: already filed as {hit} — use `discard`")
        moves.append((old, new))
        counts["move"] += 1
    for f in sorted(present - listed):
        errors.append(f"not in the table: {f}")
    # Two files numbering one volume of a series, in the batch or with one
    # already filed.
    targets = [new for _, new in moves if new not in ("discard", "trash")]
    beside = [str(f.relative_to(library)) for d in sorted({(library / t).parent for t in targets})
              if d.is_dir() for f in sorted(d.iterdir()) if f.is_file()]
    for clash in volume_clashes(beside + targets):
        if clash.split(": ", 1)[0] in targets:
            errors.append(clash)
    return errors, moves, counts


def cmd_check(a):
    staging, library = Path(a.staging), Path(a.library) if a.library else default_library()
    errors, moves, counts = validate(staging, library)
    for e in errors:
        print("ERROR", e)
    print(f"{len(errors)} errors; to move {counts.get('move', 0)}, beets {counts.get('beets', 0)}, "
          f"skip {counts.get('skip', 0)}, discard {counts.get('discard', 0)}, trash {counts.get('trash', 0)}, "
          f"already done {counts.get('done', 0)}")
    sys.exit(1 if errors else 0)


def cmd_apply(a):
    staging, library = Path(a.staging), Path(a.library) if a.library else default_library()
    if a.dry_run:
        return apply_locked(a, staging, library)
    # Batch first, then library: every caller takes them in this order.
    with batch_lock(staging, f"apply {staging.name}"), library_lock(library, f"apply {staging.name}"):
        apply_locked(a, staging, library)


def apply_locked(a, staging, library):
    # Validated under the locks: what check saw may have changed since.
    errors, moves, counts = validate(staging, library)
    if errors:
        for e in errors:
            print("ERROR", e)
        sys.exit(f"{len(errors)} errors; nothing moved")
    _, _, log = sidecar_paths(staging)
    manifest = load_manifest(staging) or {}
    originals = restaged_sources(staging)
    for old, new in moves:
        src = staging / old
        dst = trash_dir(staging) / old if new == "trash" else None if new == "discard" else library / new
        if a.dry_run:
            print(f"would {'delete' if new == 'discard' else 'move'} {old}" + (f" -> {dst}" if dst else ""))
            continue
        # The source's own hash, before tagging rewrites it: how a later batch
        # recognises this content as filed, and the record of what was deleted.
        rec = manifest.get(old, {})
        digest = rec.get("sha256") if rec.get("size") == src.stat().st_size else None
        digest = digest or sha256(src)
        if new == "discard":
            src.unlink()
            changes = []
        else:
            dst.parent.mkdir(parents=True, exist_ok=True)
            try:
                move_noclobber(src, dst)
            except FileExistsError:
                sys.exit(f"appeared since check, not replaced: {dst}\n  (earlier rows are moved; rerun apply after resolving it)")
            changes = [] if a.no_tag or new == "trash" else tag_file(library, new, source=originals.get(old, digest))
        with open(log, "a") as f:
            f.write(json.dumps({"old": old, "new": new, "sha256": digest, "size": rec.get("size"),
                                "metadata": changes,
                                "at": datetime.datetime.now().isoformat(timespec="seconds")}, ensure_ascii=False) + "\n")
        print(f"{old} -> {'deleted' if new == 'discard' else dst.relative_to(library) if new != 'trash' else dst}"
              + (f"  [{'; '.join(changes)}]" if changes else ""))
    if not a.dry_run:
        for dirpath, _, _ in sorted(os.walk(staging), key=lambda t: -len(t[0])):
            if Path(dirpath) != staging:
                try:
                    os.rmdir(dirpath)
                except OSError:
                    pass
    left, _ = walk(staging)
    print(f"moved {counts['move']}, discarded {counts['discard']}, trashed {counts['trash']}; left in staging: {len(left)}"
          + (f" (beets {counts['beets']}: `beet import {staging}`)" if counts.get("beets") else ""))


# --------------------------------------------------------------------------
# Standard metadata, derived from a library path

def strip_variants(stem):
    """'Foo (pages, v1.3)' -> 'Foo'; 'Foo (1999)' is left alone."""
    while True:
        m = re.match(r"^(.*\S)\s+\((?!\d{4}\))[^()]*\)$", stem)
        if not m:
            return stem
        stem = m.group(1)


def shelf_meta(rel):
    """What Kavita should read from a books/ or rpg/ file: its folder is the
    series; "<series> Vol. <N>[ - <title>]" names a volume. A volume's title
    is the name's; anything else is titled by its whole name, variant and
    all, so that pages and spreads tell apart; an unnumbered EPUB by its
    series, which Kavita takes from its title."""
    p = Path(rel)
    stem, series = p.stem, p.parts[-2]
    base, variant = split_variant(stem)
    m = VOL_NAME.match(base)
    want = {"series": series, "volume": num(m["n"]) if m else "",
            "title": (m["title"] or stem) + variant if m else stem}
    if not m and ext_of(rel) == "epub":
        want["title"] = series
    if p.parts[0] == "books":
        want["author"] = p.parts[1]
    return want


SHELF_KINDS = ("pdf", "epub", "cbz")


def standard(rel):
    """The metadata a library path implies: {'title':..., 'author':...}. Empty if none."""
    p = Path(rel)
    top, stem = p.parts[0], p.name[: -len(p.suffix)] if p.suffix else p.name
    if top in ("books", "rpg") and len(p.parts) > 2:
        return shelf_meta(rel)
    if top == "movies":
        stem = re.sub(r" \{tmdb-\d+\}", "", stem)
        return {"title": stem if "extras" not in p.parts else strip_variants(stem)}
    if top == "tv":
        show = re.sub(r" \(\d{4}\)( \{tmdb-\d+\})?$", "", p.parts[1])
        m = re.match(r"^.+? - (S\d{2}E\d{2,3}(?:-E\d{2,3})?)(?: - (.+))?$", stem)
        if m:
            return {"title": f"{show} - {m.group(1)}" + (f" - {m.group(2)}" if m.group(2) else "")}
    if top == "youtube":
        m = re.match(r"^\d{4}-\d{2}-\d{2} - (.+) \[[A-Za-z0-9_-]+\]$", stem)
        if m:
            return {"title": m.group(1), "author": p.parts[1]}
    return {}


def current_meta(path):
    k = kind_of(path)
    if k == "pdf":
        return pdf_meta(path)
    if k == "epub":
        m = epub_meta(path)
        # Kavita takes a series only with its volume number; else the title.
        series, volume = (m.get("series"), m.get("volume")) if m.get("series") and m.get("volume") else ("", "")
        return {"title": m.get("title", ""), "author": (m.get("creators") or [""])[0],
                "series": series or m.get("title", ""), "volume": volume, "source": m.get("source", ""),
                **({"error": m["error"]} if "error" in m else {})}
    if k == "cbz":
        return cbz_meta(path)
    if k == "video":
        t = lower_tags(ffprobe(path).get("format", {}).get("tags"))
        return {"title": t.get("title", ""), "author": t.get("artist", "")}
    if k == "audio":
        return lower_tags(ffprobe(path).get("format", {}).get("tags"))
    return {}


def shelf_todo(rel, have):
    """What a books/ or rpg/ file's metadata lacks for Kavita: {field: value}.
    An EPUB's author is the publisher's when it has one."""
    want, k = shelf_meta(rel), kind_of(rel)
    todo = {x: v for x, v in want.items()
            if (num(have.get(x)) if x == "volume" else have.get(x) or "") != v
            and not (x == "author" and k == "epub" and have.get("author"))}
    if k == "pdf" and not have.get("plain", True) and not have.get("encrypted"):
        todo["structure"] = "plain"  # see pdf_plain
    return todo


def tag_file(library, rel, dry_run=False, source=None):
    """Write the standard metadata for one library file. Returns what changed.
    `source`: the sha256 of the file as it came, kept in a book's or RPG's
    metadata (only the first time: it is the original's)."""
    path = library / rel
    want, k = standard(rel), kind_of(rel)
    shelf = rel.split("/")[0] in ("books", "rpg")
    if not want or k not in (("pdf", "epub", "cbz") if shelf else ("video",)):
        return []
    have = current_meta(path)
    if "error" in have:
        return [f"unreadable: {have['error']}"]
    if shelf:
        todo = shelf_todo(rel, have)
        if not have.get("source"):
            todo["source"] = source or "(original's sha256)"
        if not todo or dry_run:
            return [f"{x}={v}" for x, v in todo.items()] if dry_run else []
        if not have.get("source") and not source:
            source = pdf_original_sha256(path) if k == "pdf" else sha256(path)
        err = {"pdf": pdf_write, "epub": epub_write, "cbz": cbz_write}[k](path, want, source)
        if err:
            return [err]
        todo["source"] = source[:12] + "…" if "source" in todo else None
        return [f"{x}={v}" for x, v in todo.items() if v]
    todo = {x: v for x, v in want.items() if v and have.get(x) != v and x != "author"}
    if not todo or dry_run:
        return [f"{x}={v}" for x, v in todo.items()] if dry_run else []
    if k == "video" and "title" in todo:
        e = ext_of(rel)
        if e in ("mkv", "webm"):
            r = run(["mkvpropedit", "-q", str(path), "--edit", "info", "--set", f"title={todo['title']}"])
        elif e in ("mp4", "m4v", "mov"):
            tmp = path.with_name(f".tagging.{socket.gethostname()}.{os.getpid()}.{path.name}")
            r = run(["ffmpeg", "-v", "error", "-y", "-i", str(path), "-map", "0", "-c", "copy",
                     "-map_metadata", "0", "-metadata", f"title={todo['title']}", str(tmp)])
            if r.returncode == 0:
                os.replace(tmp, path)
            elif tmp.exists():
                tmp.unlink()
        else:
            return [f"title not written: .{e} has no title tag we write"]
        if r.returncode:
            return [f"title not written: {r.stderr.strip()[:200]}"]
    return [f"{x}={v}" for x, v in todo.items()]


def cmd_tag(a):
    library = Path(a.library) if a.library else default_library()
    if a.dry_run:
        return tag_paths(a, library)
    with library_lock(library, "tag"):
        tag_paths(a, library)


def tag_paths(a, library):
    for p in a.paths:
        rel = os.path.relpath(Path(p).resolve(), library.resolve())
        changes = tag_file(library, rel, a.dry_run)
        print(f"{rel}: {'; '.join(changes) if changes else 'ok'}")


# --------------------------------------------------------------------------
# close: the batch's records go only once the batch is filed and audited.
# The manifest is the one record of what each file said it was before beets
# renamed it: an audio batch keeps it until `beet stage-audit` passes.

def cmd_close(a):
    with batch_lock(a.staging, "close"):
        close(a)


def close(a):
    staging = Path(a.staging)
    manifest, _, applied = sidecar_paths(staging)
    recs = load_manifest(staging) or {}
    lock = Path(str(staging).rstrip("/") + ".lock")
    audit = Path(str(staging).rstrip("/") + ".audit.json")
    if any(r["kind"] == "audio" for r in recs.values()):
        state = json.loads(audit.read_text()) if audit.exists() else {}
        if not state.get("passed"):
            sys.exit(f"{staging.name}: not audited — run `beet stage-audit {staging}` and settle what it flags; "
                     f"{manifest.name} is the only record of what each file said it was")
    left, ignored = walk(staging) if staging.exists() else ([], [])
    left += [d for d in ignored if d.endswith("/")]  # a dot-folder may hold anything
    if left:
        print(f"{staging.name}: {len(left)} files still in staging:")
        for rel in left[:20]:
            print(f"  {rel}")
        sys.exit("file them, delete them, or move them to a new batch; the records stay until then")
    gone = []
    for p in sorted(staging.parent.glob(glob_escape(staging.name) + "*")):
        # <batch>.* only: <batch>-2 may be another batch. The lock is ours.
        if p in (applied, staging, lock) or not p.name.startswith(staging.name + "."):
            continue
        shutil.rmtree(p) if p.is_dir() else p.unlink()
        gone.append(p.name)
    if staging.exists():
        shutil.rmtree(staging)  # only OS junk is left
        gone.append(staging.name + "/")
    print(f"closed {staging.name}: removed {', '.join(gone) or 'nothing'}"
          + (f"; kept {applied.name}, the record of what was filed" if applied.exists() else ""))


# --------------------------------------------------------------------------
# restage: library files back into a batch, to be filed again under other
# names (a layout change). They keep their library paths inside the batch, so
# its table reads old name -> new name; then scan, draft, check and apply as
# for any batch.

def cmd_restage(a):
    staging, library = Path(a.staging), Path(a.library) if a.library else default_library()
    staging.parent.mkdir(parents=True, exist_ok=True)
    with batch_lock(staging, f"restage {staging.name}"), library_lock(library, f"restage {staging.name}"):
        restage(a, staging, library)


def restage(a, staging, library):
    files = []
    for arg in a.paths:
        p = Path(arg) if Path(arg).is_absolute() else library / arg
        rel = os.path.relpath(p, library)
        top = rel.split("/")[0]
        if top not in LIBRARY_DIRS or rel.startswith(".."):
            sys.exit(f"not in the library: {arg}")
        if top == "music":
            sys.exit(f"{arg}: music is beets' to move")
        if p.is_dir():
            files += sorted(f for f in p.rglob("*") if f.is_file() and not f.name.startswith("."))
        elif p.is_file():
            files.append(p)
        else:
            sys.exit(f"no such file: {arg}")
    moved = 0
    log = restaged_path(staging)
    for f in files:
        rel = str(f.relative_to(library))
        # The original's hash goes with the file (apply sees only this copy),
        # for a book or RPG file that has no record of it yet.
        if rel.split("/")[0] in ("books", "rpg") and kind_of(rel) in SHELF_KINDS \
                and not current_meta(f).get("source"):
            src = pdf_original_sha256(f) if kind_of(rel) == "pdf" else sha256(f)
            with open(log, "a") as out:
                out.write(json.dumps({"path": rel, "source": src}, ensure_ascii=False) + "\n")
        dst = staging / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        move_noclobber(f, dst)
        moved += 1
        d = f.parent
        while d != library and d.parent != library and not any(d.iterdir()):
            d.rmdir()
            d = d.parent
    print(f"restaged {moved} files -> {staging}\n"
          f"next: scan --hash, draft, fill the table's `new` column, check, apply")


def restaged_path(staging):
    return Path(str(staging).rstrip("/") + ".restaged.jsonl")


def restaged_sources(staging):
    log = restaged_path(staging)
    if not log.exists():
        return {}
    return {e["path"]: e["source"] for e in map(json.loads, log.read_text().splitlines()) if e.get("source")}


def glob_escape(s):
    return re.sub(r"([*?\[])", r"[\1]", s)


# --------------------------------------------------------------------------
# lint

AUDIO_REQUIRED = ("artist", "album", "title", "track")


def cmd_lint(a):
    library = Path(a.library) if a.library else default_library()
    if not a.fix:
        sys.exit(lint(a, library))
    with library_lock(library, "lint --fix"):
        code = lint(a, library)
    sys.exit(code)


def lint(a, library):
    roots = [Path(d) for d in a.dirs] or [library / d for d in LIBRARY_DIRS]
    problems = 0
    for root in roots:
        if not root.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            folded = {}
            for n in dirnames + filenames:
                folded.setdefault(n.casefold(), []).append(n)
            for group in folded.values():
                if len(group) > 1:
                    problems += 1
                    print(f"CASE   {os.path.relpath(dirpath, library)}: {' / '.join(group)} "
                          "(one entry on the Mac, several on desk)")
            rels = [os.path.relpath(Path(dirpath) / f, library) for f in sorted(filenames)
                    if f not in IGNORED_NAMES and not f.startswith(".")]
            for clash in volume_clashes(rels):
                problems += 1
                print(f"LAYOUT {clash}")
            for rel in rels:
                path = library / rel
                why = layout_error(rel)
                if why:
                    problems += 1
                    print(f"LAYOUT {rel}: {why}")
                    continue
                k = kind_of(rel)
                if rel.split("/")[0] in ("books", "rpg") and k in SHELF_KINDS:
                    have = current_meta(path)
                    if have.get("encrypted"):
                        print(f"NOTE   {rel}: encrypted; Kavita reads only its name")
                        continue
                    todo = {"unreadable": have["error"]} if "error" in have else shelf_todo(rel, have)
                    if not have.get("source") and "error" not in have:
                        todo["source"] = "none"
                    if todo and a.fix and "error" not in have:
                        print(f"FIXED  {rel}: {'; '.join(tag_file(library, rel))}")
                    elif todo:
                        problems += 1
                        print(f"META   {rel}: " + ", ".join(
                            f"{x} is {have.get(x)!r}, not {v!r}" if x in ("title", "series", "volume", "author")
                            else "earlier revisions or object streams (Kavita cannot follow them)" if x == "structure"
                            else "no record of the original's sha256" if x == "source"
                            else f"{x}: {v}" for x, v in todo.items()))
                    continue
                if k == "audio":
                    tags = current_meta(path)
                    missing = [t for t in AUDIO_REQUIRED if not tags.get(t)]
                    if not (tags.get("album_artist") or tags.get("albumartist")):
                        missing.append("album_artist")
                    if missing:
                        problems += 1
                        print(f"META   {rel}: missing {', '.join(missing)}")
                elif k == "video":
                    want, have = standard(rel), current_meta(path)
                    bad = [x for x, v in want.items() if v and have.get(x) != v and x != "author"]
                    if bad:
                        if a.fix:
                            changes = tag_file(library, rel)
                            print(f"FIXED  {rel}: {'; '.join(changes)}")
                        else:
                            problems += 1
                            print(f"META   {rel}: " + ", ".join(f"{x} is {have.get(x)!r}" for x in bad))
    print(f"{problems} problems")
    return 1 if problems else 0


# --------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(prog="media-stage", description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 1)[1])
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--library", help="library root (default: $MEDIA_LIBRARY, else /srv/media, else /Volumes/media)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    _add = sub.add_parser
    sub.add_parser = lambda *x, **kw: _add(*x, parents=[common], **kw)
    s = sub.add_parser("scan", help="read metadata into STAGING.manifest.jsonl")
    s.add_argument("staging")
    s.add_argument("--hash", action="store_true", help="sha256 every file (reports identical content)")
    s.set_defaults(fn=cmd_scan)
    s = sub.add_parser("draft", help="propose library paths into STAGING.tsv")
    s.add_argument("staging")
    s.add_argument("--force", action="store_true",
                   help="rewrite the table from scratch (default: keep its rows, add new files)")
    s.add_argument("--lookup", action="store_true",
                   help="films and shows: title, year, TMDB id and original language from Wikidata (network)")
    s.set_defaults(fn=cmd_draft)
    s = sub.add_parser("group", help="move audio into one folder per album, by its tags (then rescans)")
    s.add_argument("staging")
    s.set_defaults(fn=cmd_group)
    s = sub.add_parser("review", help="export the rows a person must decide; import their answers")
    s.add_argument("action", choices=["export", "import"])
    s.add_argument("staging")
    s.add_argument("--answers", help="import: exported answer documents (a file or a directory)")
    s.set_defaults(fn=cmd_review)
    s = sub.add_parser("check", help="validate STAGING.tsv")
    s.add_argument("staging")
    s.set_defaults(fn=cmd_check)
    s = sub.add_parser("apply", help="move files into the library and write their metadata")
    s.add_argument("staging")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--no-tag", action="store_true", help="move only; leave metadata alone")
    s.set_defaults(fn=cmd_apply)
    s = sub.add_parser("tag", help="write standard metadata for library files")
    s.add_argument("paths", nargs="+")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_tag)
    s = sub.add_parser("close", help="remove a filed batch's records (audio: once `beet stage-audit` passes)")
    s.add_argument("staging")
    s.set_defaults(fn=cmd_close)
    s = sub.add_parser("restage", help="move library files back into a new batch, to file them again")
    s.add_argument("staging")
    s.add_argument("paths", nargs="+", help="library files or folders (relative to the library, or absolute)")
    s.set_defaults(fn=cmd_restage)
    s = sub.add_parser("lint", help="audit layout and metadata of the library")
    s.add_argument("dirs", nargs="*", help="limit to these directories")
    s.add_argument("--fix", action="store_true", help="write standard metadata where it differs (not audio)")
    s.set_defaults(fn=cmd_lint)
    a = ap.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
