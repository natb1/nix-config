"""Tests for media-stage. Run by the package's checkPhase (`nix build .#media-stage`,
`nix flake check`), where ffmpeg, poppler, exiftool and mkvtoolnix are on PATH,
and, on Linux, beets for the beets plugin.

The pipeline test builds a small batch of real files — generated video, audio,
a hand-written PDF and EPUB — and takes it through scan, draft, check, apply
and lint, the way a real batch goes."""

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import media_stage as ms

sys.path.insert(0, str(Path(__file__).parent / "beetsplug"))
import stagecheck as sc  # noqa: E402

try:  # beets is in the check on Linux only (default.nix)
    from beets import config as beets_config
    from beets import logging as beets_logging
    from beets.library import Item, Library
    import beetsplug.stagereview as sr
except ImportError:
    sr = None


def setUpModule():
    # Never desk's own Kavita: these tests run there too, beside a real key.
    unittest.enterModuleContext(mock.patch.object(ms, "KAVITA_KEY", "/nonexistent/kavita-api-key"))


def run_cli(*args):
    out = io.StringIO()
    code = 0
    with redirect_stdout(out):
        try:
            ms.main(list(args))
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
            if isinstance(e.code, str):
                out.write(e.code)
    return code, out.getvalue()


def case_sensitive_tmp():
    with tempfile.TemporaryDirectory() as d:
        Path(d, "a").touch()
        return not Path(d, "A").exists()


def make_pdf(path, title=None):
    """A one-page PDF with correct xref offsets, so every tool accepts it."""
    info = f"<< /Title ({title}) >>" if title else "<< >>"
    objs = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        "/Resources << /Font << /F1 5 0 R >> >> >>",
        None,  # content stream, below
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        info,
    ]
    content = b"BT /F1 12 Tf 72 720 Td (Test Game rules) Tj ET"
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        if o is None:
            out += f"{i} 0 obj\n<< /Length {len(content)} >>\nstream\n".encode() + content + b"\nendstream\nendobj\n"
        else:
            out += f"{i} 0 obj\n{o}\nendobj\n".encode()
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R /Info 6 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    Path(path).write_bytes(bytes(out))


def make_epub(path, title, creator):
    md = ""
    if title:
        md += f"<dc:title>{title}</dc:title>"
    if creator:
        md += f"<dc:creator>{creator}</dc:creator>"
    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">x</dc:identifier>{md}<dc:language>en</dc:language></metadata>
  <manifest/><spine/>
</package>"""
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
        z.writestr("META-INF/container.xml", """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
        z.writestr("OEBPS/content.opf", opf)


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True)


def make_video(path):
    ffmpeg("-f", "lavfi", "-i", "testsrc=size=64x48:rate=5", "-f", "lavfi", "-i", "sine=f=440",
           "-t", "1", "-c:v", "mpeg4", "-c:a", "aac", "-shortest", str(path))


def make_mp3(path, **tags):
    meta = [x for k, v in tags.items() for x in ("-metadata", f"{k}={v}")]
    ffmpeg("-f", "lavfi", "-i", "sine=f=440", "-t", "1", *meta, str(path))


class Review(unittest.TestCase):
    """group, and review export -> answers -> review import."""

    def test_group_audio_by_album(self):
        with tempfile.TemporaryDirectory() as d:
            st = Path(d) / "staging" / "audio"
            st.mkdir(parents=True)
            make_mp3(st / "a1.mp3", album="Nocturnal", title="One", track="1")
            make_mp3(st / "a2.mp3", album="Nocturnal", title="Two", track="2")
            make_mp3(st / "Runehammer Games - Daisy Crown - 01 Endless Wind.mp3")
            make_mp3(st / "stray.mp3")
            self.assertEqual(run_cli("scan", str(st), "--library", d)[0], 0)
            self.assertEqual(run_cli("group", str(st), "--library", d)[0], 0)
            self.assertEqual(sorted(p.relative_to(st).as_posix() for p in st.rglob("*.mp3")), [
                "Daisy Crown/Runehammer Games - Daisy Crown - 01 Endless Wind.mp3",
                "Nocturnal/a1.mp3", "Nocturnal/a2.mp3", "_loose/stray.mp3"])
            manifest = (Path(d) / "staging" / "audio.manifest.jsonl").read_text()
            self.assertIn("Nocturnal/a1.mp3", manifest)  # rescanned

    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            st = lib / "staging" / "print"
            st.mkdir(parents=True)
            for n in ("sure.pdf", "unsure.pdf", "blank.pdf"):
                make_pdf(st / n, title=n)
            self.assertEqual(run_cli("scan", str(st), "--library", d)[0], 0)
            (lib / "staging" / "print.tsv").write_text(
                "old\tnew\tnote\n"
                "sure.pdf\trpg/Cairn/Sure.pdf\t\n"
                "unsure.pdf\trpg/Cairn/Unsure.pdf\tcheck: guessed from text\n"
                "blank.pdf\t\t\n")
            self.assertEqual(run_cli("review", "export", str(st), "--library", d)[0], 0)
            review = json.loads((lib / "staging" / "print.review.json").read_text())
            by = {i["key"]: i for i in review["items"]}
            self.assertEqual(sorted(by), ["blank.pdf", "unsure.pdf"])
            self.assertEqual(by["unsure.pdf"]["options"][0]["value"], "path:rpg/Cairn/Unsure.pdf")
            ans = lib / "answers"
            ans.mkdir()
            (ans / "a.json").write_text(json.dumps({"data": {  # wrapped, as an export may be
                "batch": "print", "item": by["unsure.pdf"]["id"], "choice": "custom",
                "fields": {"new": "books/Someone/Unsure/Unsure.pdf"}, "note": "it is a novel"}}))
            (ans / "b.json").write_text(json.dumps({
                "batch": "print", "item": by["blank.pdf"]["id"], "choice": "skip"}))
            (ans / "other.json").write_text(json.dumps({
                "batch": "audio", "item": by["blank.pdf"]["id"], "choice": "option", "value": "path:x"}))
            code, out = run_cli("review", "import", str(st), "--answers", str(ans), "--library", d)
            self.assertEqual(code, 0, out)
            table = (lib / "staging" / "print.tsv").read_text()
            self.assertIn("unsure.pdf\tbooks/Someone/Unsure/Unsure.pdf\treviewed\tcheck: guessed from text · reviewer: it is a novel", table)
            self.assertIn("blank.pdf\tskip\treviewed", table)
            self.assertEqual(run_cli("review", "export", str(st), "--library", d)[0], 0)
            self.assertEqual(json.loads((lib / "staging" / "print.review.json").read_text())["items"], [])
            code, out = run_cli("check", str(st), "--library", d)
            self.assertEqual(code, 0, out)

    def test_video_evidence_is_what_scan_read(self):
        # scan_file keeps the picture as meta["video"] and the container's
        # title among meta["tags"]: what a reviewer compares copies by.
        rec = {"path": "Heat.1995.mkv", "kind": "video", "size": 7e9, "guess": ms.guess("Heat.1995.mkv"),
               "meta": {"duration": 7200.0, "bit_rate": 8000000, "tags": {"title": "Heat.1995.x264-GRP"},
                        "video": "h264 1920x1080", "audio_langs": ["eng"], "sub_langs": ["eng", "fre"]}}
        ev = {e["label"]: e["value"] for e in ms.evidence(rec)}
        self.assertEqual((ev["Video"], ev["Title"]), ("h264 1920x1080", "Heat.1995.x264-GRP"))
        self.assertEqual((ev["Audio"], ev["Subtitles"]), ("eng", "eng, fre"))

    def test_export_keeps_stage_reviews_albums(self):
        # Music with a booklet: `beet stage-review` wrote its albums first;
        # the table's rows join them in the batch's one review.
        with tempfile.TemporaryDirectory() as d:
            st = Path(d) / "b"
            st.mkdir()
            (Path(d) / "b.tsv").write_text("old\tnew\tconfidence\tnote\n"
                                           "A/01.flac\tbeets\thigh\t\nA/booklet.pdf\t\t\t\n")
            album = {"id": "a1b2c3d4e5f6", "key": "A", "kind": "album", "twin": 42, "options": []}
            review = Path(d) / "b.review.json"
            review.write_text(json.dumps({"batch": "b", "kind": "audio", "source": "beets", "items": [album]}))
            for _ in range(2):  # again: the table's rows are replaced, the album kept once
                run_cli("review", "export", str(st))
                items = json.loads(review.read_text())["items"]
                self.assertEqual([i["key"] for i in items], ["A", "A/booklet.pdf"])
                self.assertEqual(items[0], album)


class Layout(unittest.TestCase):
    good = [
        "music/Julian Bream/Nocturnal (1993)/1-01 Britten - Nocturnal.mp3",
        "books/Albert Camus/The Stranger/The Stranger.epub",
        "books/Plato/Republic/Republic (tr. Grube, rev. Reeve).epub",
        "books/Terry Pratchett/Discworld/Discworld Vol. 3 - Equal Rites.epub",
        "books/Terry Pratchett/Discworld/Discworld Vol. 4.epub",
        "books/Aristotle/Nicomachean Ethics/Nicomachean Ethics (tr. Irwin, 3rd ed).pdf",
        "books/Someone/Some Series/A Companion.pdf",  # a PDF names its series in its metadata
        "rpg/Blades in the Dark/Blades in the Dark (version 8.2).pdf",
        "rpg/Dungeon Age/Saving Saxham (Cairn, version 1).pdf",
        "rpg/Stonetop/Stonetop - Book II - The Wider World (spreads).pdf",
        "rpg/A Thousand Thousand Islands/A Thousand Thousand Islands 3 - Upper Heleng.pdf",
        "rpg/Partizan/Partizan - One-Page Character Sheet (2026-04-25).pdf",
        "rpg/Mothership/Warped Beyond Recognition - Maps.zip",  # its series is its folder's name
        "rpg/Mothership/extras/Warped Beyond Recognition - Remote Desktop (Windows).zip",
        "rpg/Mothership/extras/Tokens (v2).zip",  # Kavita passes over extras/: no volume to misread
        "movies/Heat (1995)/Heat (1995).mkv",
        "movies/Heat (1995)/Heat (1995) - Director's Cut.mkv",
        "movies/Heat (1995)/Heat (1995).en.srt",
        "movies/Heat (1995)/Heat (1995).en.forced.srt",
        "movies/Heat (1995)/extras/Making of.mp4",
        "movies/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv",
        "movies/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.en.srt",
        "tv/The Wire (2002) {tmdb-1438}/Season 01/The Wire (2002) - S01E01 - The Target.mkv",
        "tv/The Wire (2002)/Season 01/The Wire (2002) - S01E01 - The Target.mkv",
        "tv/The Wire (2002)/Season 01/The Wire (2002) - S01E01-E02.mkv",
        "tv/The Wire (2002)/Season 00/The Wire (2002) - S00E01.en.srt",
        "youtube/Some Channel/2024-05-01 - A video title [dQw4w9WgXcQ].webm",
        "youtube/Some Channel/2024-05-01 - A video title [dQw4w9WgXcQ].info.json",
    ]
    bad = [
        ("videos/x.mp4", "top directory"),
        ("movies/Heat/Heat.mkv", "movies/ layout"),
        ("movies/Heat (1995)/Heat.mkv", "movies/ layout"),
        ("movies/Heat (1995) {tmdb-949}/Heat (1995).mkv", "movies/ layout"),  # Infuse reads the file's id
        ("movies/Heat (1995) {imdb-tt0113277}/Heat (1995) {imdb-tt0113277}.mkv", "movies/ layout"),
        ("tv/The Wire (2002) {tmdb-1438}/Season 01/The Wire (2002) {tmdb-1438} - S01E01.mkv", "tv/ layout"),
        ("tv/The Wire (2002)/Season 1/The Wire (2002) - S01E01.mkv", "tv/ layout"),
        ("tv/The Wire (2002)/Season 02/The Wire (2002) - S01E01.mkv", "tv/ layout"),
        ("rpg/Game/What?.pdf", "SMB"),
        ("books/Author /Title/Title.epub", "trailing space"),
        # Kavita: the folder is the series, and a name says a volume only as "<series> Vol. <N>"
        ("books/Albert Camus/The Stranger.epub", "books/ layout"),
        ("rpg/Blades in the Dark/Blades in the Dark (v8.2).pdf", "version 1.1"),
        ("rpg/Dungeon Age/Imperial Vault 19 (5e, v2).pdf", "volume 2"),
        ("rpg/Tower/Tower S01 Map.pdf", "volume 01"),
        ("books/Terry Pratchett/Discworld/Equal Rites.epub", "series of its own"),
        ("books/Terry Pratchett/Discworld/Mort Vol. 4.epub", "named for its folder"),
        # extras/ is a game's, one level deep
        ("rpg/Mothership/extras/Maps/Deck 1.png", "rpg/ layout"),
        ("books/Someone/Some Book/extras/Notes.pdf", "books/ layout"),
        # Kavita reads no ComicInfo.xml from a .zip, so no series: a comic is a .cbz
        ("books/Someone/Some Comic/Some Comic Vol. 1.zip", "books/ layout"),
        # ... and makes a series of a zip's name with a number in it (Kavita 0.9.1, sandbox scan)
        ("rpg/Mothership/Tokens (version 2).zip", "a zip's name takes no digits"),
        ("rpg/Mothership/Warped Beyond Recognition - Maps (1999).zip", "a zip's name takes no digits"),
        ("rpg/Mothership/Tokens (version two).zip", None),
        ("rpg/Game/Title..pdf", None),  # legal: the dot is not trailing on the component
        # Hidden: Jellyfin ignores it, lint and the filed index pass over it.
        ("movies/...And Justice for All (1979)/...And Justice for All (1979).mkv", "leading dot"),
    ]

    def test_good(self):
        for p in self.good:
            self.assertIsNone(ms.layout_error(p), p)

    def test_bad(self):
        for p, why in self.bad:
            err = ms.layout_error(p)
            if why is None:
                self.assertIsNone(err, p)
            else:
                self.assertIsNotNone(err, p)
                self.assertIn(why, err, p)


class Helpers(unittest.TestCase):
    def test_pdfinfo_pdfx_subtype_title(self):
        # pdfinfo on a PDF/X file: the subtype block repeats "Title".
        out = ("Title:           Witches of Frostwyck - Map - Area\n"
               "PDF subtype:     PDF/X-1:2001\n"
               "    Title:         ISO 15930 - Electronic document file format for prepress digital data exchange (PDF/X)\n"
               "    Abbreviation:  PDF/X-1:2001\n"
               "Pages:           1\n")
        info = ms.parse_pdfinfo(out)
        self.assertEqual(info["Title"], "Witches of Frostwyck - Map - Area")
        self.assertEqual(info["Pages"], "1")

    def test_strip_variants(self):
        self.assertEqual(ms.strip_variants("Saving Saxham (Cairn, v1)"), "Saving Saxham")
        self.assertEqual(ms.strip_variants("Republic (tr. Grube, rev. Reeve)"), "Republic")
        self.assertEqual(ms.strip_variants("Classical Guitar Technique (2019)"), "Classical Guitar Technique (2019)")

    def test_person(self):
        self.assertEqual(ms.person("Camus, Albert"), "Albert Camus")
        self.assertEqual(ms.person("Albert Camus"), "Albert Camus")

    def test_kavita_volume(self):
        # What Kavita 0.9 made of each name, in a Book library (sandbox scan).
        seen = {"X (v8.2)": "8.2", "X {v8.2}": "8.2", "X (5e, v2)": "2", "X (v01)": "1", "X (Cairn, v1)": "1",
                "X Vol. 2 - Second": "2", "X Vol. 3": "3",
                "X (version 8.2)": None, "X (rev 8.2)": None, "X (8.2)": None, "X (2nd ed)": None,
                "X (2026-04-25)": None, "X (11x17)": None, "X (landscape, A4)": None, "X 2e - Sheet": None,
                "X - Book II - Y (spreads)": None, "Tales of Old England 1 - A Spark": None, "X SP01 Bonus": None}
        for name, vol in seen.items():
            got = ms.kavita_volume(name)
            self.assertEqual(ms.num(got) if got else None, vol, name)

    def test_standard(self):
        self.assertEqual(ms.standard("books/Plato/Republic/Republic (tr. Reeve).epub"),
                         {"series": "Republic", "volume": "", "title": "Republic", "author": "Plato"})
        self.assertEqual(ms.standard("books/Terry Pratchett/Discworld/Discworld Vol. 3 - Equal Rites (tr. X).epub"),
                         {"series": "Discworld", "volume": "3", "title": "Equal Rites (tr. X)", "author": "Terry Pratchett"})
        self.assertEqual(ms.standard("rpg/Cairn/The Drops of St Jerome (pages).pdf"),
                         {"series": "Cairn", "volume": "", "title": "The Drops of St Jerome (pages)"})
        self.assertEqual(ms.standard("rpg/Game/Game Vol. 2 (spreads).pdf"),
                         {"series": "Game", "volume": "2", "title": "Game Vol. 2 (spreads)"})
        self.assertEqual(ms.standard("rpg/Game/extras/Remote Desktop (Windows).zip"), {})
        self.assertEqual(ms.standard("movies/Heat (1995)/Heat (1995).mkv"), {"title": "Heat (1995)"})
        self.assertEqual(ms.standard("movies/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv"), {"title": "Heat (1995)"})
        self.assertEqual(ms.standard("tv/The Wire (2002) {tmdb-1438}/Season 01/The Wire (2002) - S01E01.mkv"),
                         {"title": "The Wire - S01E01"})
        self.assertEqual(ms.standard("tv/The Wire (2002)/Season 01/The Wire (2002) - S01E01 - The Target.mkv"),
                         {"title": "The Wire - S01E01 - The Target"})
        self.assertEqual(ms.standard("youtube/Chan/2024-05-01 - Hello [abc123]/".rstrip("/") + ".mp4"),
                         {"title": "Hello", "author": "Chan"})

    def test_title_clean(self):
        self.assertEqual(ms.title_clean("Alien: Covenant"), "Alien - Covenant")
        self.assertEqual(ms.title_clean("...And Justice for All"), "And Justice for All")  # not a hidden name
        self.assertEqual(ms.clean(".hack//Sign ."), "hack--Sign")
        self.assertEqual(ms.norm_title("Aguirre, the Wrath of God"), ms.norm_title("Aguirre The Wrath Of God"))
        self.assertEqual(ms.norm_title("Big Sick, The"), ms.norm_title("The Big Sick"))

    def test_year_from_embedded_title_or_folder(self):
        rec = {"path": "The Dark Crystal (1982)/The Dark Crystal - Bluray-1080p.mkv",
               "guess": ms.guess("The Dark Crystal - Bluray-1080p.mkv"),
               "meta": {"tags": {"title": "The Dark Crystal (1982) RM4K"}}}
        t = ms.video_target(rec)
        self.assertEqual(t["stem"], "movies/The Dark Crystal (1982)/The Dark Crystal (1982)")
        self.assertIn("year from embedded title", t["note"])
        rec["meta"] = {}
        t = ms.video_target(rec)
        self.assertEqual(t["stem"], "movies/The Dark Crystal (1982)/The Dark Crystal (1982)")
        self.assertIn("year from folder", t["note"])
        # A folder that names another film says nothing about this one.
        rec["path"] = "Labyrinth (1986)/The Dark Crystal - Bluray-1080p.mkv"
        self.assertIsNone(ms.video_target(rec)["stem"])

    def test_ep_code(self):
        self.assertEqual(ms.ep_code(1, 2), "S01E02")
        self.assertEqual(ms.ep_code(1, [2, 3]), "S01E02-E03")

    def test_episode_across_seasons_is_left_blank(self):
        # A finale and the next premiere in one file: no one SxxEyy names it,
        # and the rest of the batch still drafts.
        name = "Show.2010.S01E24-S02E01.720p.mkv"
        t = ms.video_target({"path": name, "guess": ms.guess(name)})
        self.assertIsNone(t["stem"])
        self.assertIn("spans seasons", t["note"])


class Group(unittest.TestCase):
    """group: albums by the files' own tags, wherever they sit."""

    def test_discs_merged_by_tags_and_logged(self):
        with tempfile.TemporaryDirectory() as d:
            st = Path(d) / "staging" / "audio"
            for sub in ("Ballads CD1", "Ballads CD2", "Other CD1"):
                (st / sub).mkdir(parents=True)
            make_mp3(st / "Ballads CD1" / "01 Rain.mp3", album="Ballads (Disc 1)", title="Rain", track="1")
            make_mp3(st / "Ballads CD2" / "01 Snow.mp3", album="Ballads (Disc 2)", title="Snow", track="1")
            # Named like the next disc of Ballads, tagged as its own album:
            # beets would have joined it to Ballads by the folder name.
            make_mp3(st / "Other CD1" / "01 Wind.mp3", album="Other", title="Wind", track="1")
            self.assertEqual(run_cli("scan", str(st), "--library", d)[0], 0)
            code, out = run_cli("group", str(st), "--library", d)
            self.assertEqual(code, 0, out)
            self.assertEqual(sorted(p.relative_to(st).as_posix() for p in st.rglob("*.mp3")), [
                "Ballads/1-01 Rain.mp3", "Ballads/2-01 Snow.mp3", "Other/01 Wind.mp3"])
            self.assertEqual(sorted(p.name for p in st.iterdir()), ["Ballads", "Other"])  # emptied folders gone
            log = json.loads((Path(d) / "staging" / "audio.group.json").read_text())
            self.assertEqual(log, {"Ballads": {"from": ["Ballads CD1", "Ballads CD2"], "discs": [1, 2]}})
            self.assertIn("1 made from more than one folder", out)

    def test_same_album_name_other_artist(self):
        with tempfile.TemporaryDirectory() as d:
            st = Path(d) / "staging" / "audio"
            st.mkdir(parents=True)
            make_mp3(st / "a.mp3", album="Greatest Hits", album_artist="Queen", title="A", track="1")
            make_mp3(st / "b.mp3", album="Greatest Hits", album_artist="ABBA", title="B", track="1")
            run_cli("scan", str(st), "--library", d)
            self.assertEqual(run_cli("group", str(st), "--library", d)[0], 0)
            self.assertEqual(sorted(p.relative_to(st).as_posix() for p in st.rglob("*.mp3")), [
                "Greatest Hits (Queen)/a.mp3", "Greatest Hits/b.mp3"])

    def test_table_follows_and_filed_audio_is_done(self):
        # A mixed batch, drafted before group: the table follows the audio
        # into its album folder, and once beets has filed it (moved it out
        # of staging) its row is done, so the rest of the batch can be filed.
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            st = lib / "staging" / "mix"
            st.mkdir(parents=True)
            make_mp3(st / "a1.mp3", album="Nocturnal", title="One", track="1")
            make_pdf(st / "rules.pdf", title="x")
            run_cli("scan", str(st), "--hash", "--library", d)
            run_cli("draft", str(st), "--library", d)
            table = Path(str(st) + ".tsv")
            table.write_text(table.read_text().replace("\t\t\tclassify", "\trpg/Game/Rules.pdf\thigh\tclassify"))
            self.assertEqual(run_cli("group", str(st), "--library", d)[0], 0)
            self.assertIn("Nocturnal/a1.mp3\tbeets\t", table.read_text())
            self.assertFalse(any(r.get("gone") for r in ms.load_manifest(st).values()))  # moved, not gone
            code, out = run_cli("check", str(st), "--library", d)
            self.assertEqual(code, 0, out)
            (st / "Nocturnal" / "a1.mp3").unlink()  # beets filed it
            (st / "Nocturnal").rmdir()
            code, out = run_cli("check", str(st), "--library", d)
            self.assertEqual(code, 0, out)
            self.assertIn("already done 1", out)
            code, out = run_cli("apply", str(st), "--library", d)
            self.assertEqual(code, 0, out)
            self.assertTrue((lib / "rpg/Game/Rules.pdf").exists())

    def test_rescan_keeps_the_hashes(self):
        # group rescans without reading every byte again: the files it
        # didn't change keep their hashes, and with them check's refusal to
        # file content that is already filed.
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            (lib / "rpg/Game").mkdir(parents=True)
            make_pdf(lib / "rpg/Game/Rules.pdf", title="x")
            st = lib / "staging" / "mix"
            st.mkdir(parents=True)
            (st / "rules.pdf").write_bytes((lib / "rpg/Game/Rules.pdf").read_bytes())
            make_mp3(st / "a1.mp3", album="Nocturnal", title="One", track="1")
            run_cli("scan", str(st), "--hash", "--library", d)
            self.assertEqual(run_cli("group", str(st), "--library", d)[0], 0)
            recs = ms.load_manifest(st)
            self.assertEqual(sorted(p for p, r in recs.items() if r.get("sha256")), ["Nocturnal/a1.mp3", "rules.pdf"])
            Path(str(st) + ".tsv").write_text("old\tnew\nNocturnal/a1.mp3\tbeets\nrules.pdf\trpg/Game/Rules again.pdf\n")
            code, out = run_cli("check", str(st), "--library", d)
            self.assertEqual(code, 1)
            self.assertIn("already filed as rpg/Game/Rules.pdf", out)

    def test_split_disc(self):
        self.assertEqual(ms.split_disc("Ballads CD2"), ("Ballads", 2))
        self.assertEqual(ms.split_disc("Ballads (Disc 1)"), ("Ballads", 1))
        self.assertEqual(ms.split_disc("CD2"), ("", 2))
        self.assertEqual(ms.split_disc("Discovery 2"), ("Discovery 2", None))


class Close(unittest.TestCase):
    def test_audio_batch_waits_for_the_audit(self):
        with tempfile.TemporaryDirectory() as d:
            staging = Path(d) / "staging"
            st = staging / "audio"
            st.mkdir(parents=True)
            make_mp3(st / "a.mp3", album="X", title="A", track="1")
            run_cli("scan", str(st), "--library", d)
            (staging / "audio.review.json").write_text("{}")
            (staging / "audio.applied.jsonl").write_text("")
            (staging / "audio-2.tsv").write_text("another batch\n")
            code, out = run_cli("close", str(st), "--library", d)
            self.assertNotEqual(code, 0)
            self.assertIn("not audited", out)
            (staging / "audio.audit.json").write_text(json.dumps({"passed": "2026-09-25"}))
            code, out = run_cli("close", str(st), "--library", d)
            self.assertNotEqual(code, 0)
            self.assertIn("a.mp3", out)  # still in staging
            (st / "a.mp3").unlink()
            (st / ".DS_Store").write_text("")
            code, out = run_cli("close", str(st), "--library", d)
            self.assertEqual(code, 0, out)
            self.assertEqual(sorted(p.name for p in staging.iterdir()), ["audio-2.tsv", "audio.applied.jsonl"])

    def test_rescan_keeps_what_beets_filed(self):
        # beets moves what it files out of staging. A rescan after that keeps
        # those files' records, the only ones of what they said they were:
        # the audit checks against them, and close still waits for it.
        with tempfile.TemporaryDirectory() as d:
            st = Path(d) / "staging" / "mix"
            (st / "Album").mkdir(parents=True)
            make_mp3(st / "Album" / "01.mp3", album="Album", title="No. 3", track="1")
            make_pdf(st / "doc.pdf")
            run_cli("scan", str(st), "--library", d)
            (st / "Album" / "01.mp3").unlink()  # filed by beets
            for _ in range(2):
                code, out = run_cli("scan", str(st), "--library", d)
                self.assertEqual(code, 0, out)
                rec = ms.load_manifest(st).get("Album/01.mp3", {})
                self.assertEqual((rec.get("meta", {}).get("tags", {}).get("title"), rec.get("gone")), ("No. 3", True))
            self.assertEqual(run_cli("group", str(st), "--library", d)[0], 0)  # passes it over
            (st / "doc.pdf").unlink()
            code, out = run_cli("close", str(st), "--library", d)
            self.assertNotEqual(code, 0)
            self.assertIn("not audited", out)

    def test_hidden_folder_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            st = Path(d) / "staging" / "print"
            (st / ".originals").mkdir(parents=True)
            code, out = run_cli("close", str(st), "--library", d)
            self.assertNotEqual(code, 0)
            self.assertIn(".originals/", out)

    def test_dot_named_file_blocks(self):
        # Left out of the batch like junk, but it may be media, and the only copy.
        with tempfile.TemporaryDirectory() as d:
            st = Path(d) / "staging" / "print"
            st.mkdir(parents=True)
            book = st / "...And Ladies of the Club.pdf"
            book.write_bytes(b"%PDF-1.4\n")
            (st / "._x.pdf").write_bytes(b"")  # the Mac's AppleDouble: junk
            code, out = run_cli("close", str(st), "--library", d)
            self.assertNotEqual(code, 0)
            self.assertIn(book.name, out)
            self.assertTrue(book.exists())
            code, out = run_cli("scan", str(st), "--library", d)
            self.assertIn("dot-named, so not in the batch", out)
            book.unlink()
            code, out = run_cli("close", str(st), "--library", d)
            self.assertEqual(code, 0, out)
            self.assertFalse(st.exists())


class Checks(unittest.TestCase):
    """beetsplug/stagecheck.py: the evidence stage-review and stage-audit use."""

    def test_number_clash(self):
        self.assertEqual(sc.number_clash("Prelude No. 3 in A minor", "Prelude No. 5 in D major"), "No. 3 ≠ No. 5")
        self.assertTrue(sc.number_clash("Prelude in C minor, BWV 999", "Prelude, BWV 998"))
        self.assertTrue(sc.number_clash("Sonatina: II. Andante", "Sonatina: III. Allegro"))
        self.assertEqual(sc.number_clash("Fandanguillo, Op. 36", "Fandanguillo"), "")  # a dropped number
        self.assertEqual(sc.number_clash("Preludio n.º 1", "Prelude No. 1 in E minor"), "")
        self.assertTrue(sc.number_clash("Preludio n.º 1", "Prelude No. 2"))
        self.assertEqual(sc.number_clash("Sonata in C", "Sonata in A"), "")  # keys aren't movements

    def test_name_conflict(self):
        self.assertEqual(sc.name_conflict("05 Prelude No. 3.mp3", {"track": "5", "title": "Prelude No. 3"}), "")
        self.assertIn("track 5 in the name, 1 in the tags",
                      sc.name_conflict("05 Prelude No. 3.mp3", {"track": "1/12", "title": "Prelude No. 3"}))
        self.assertIn("No. 3 ≠ No. 5", sc.name_conflict("Bream - Villa-Lobos - 05 Prelude No. 3.mp3",
                                                        {"track": "5", "title": "Prelude No. 5"}))
        self.assertIn("in the tags", sc.name_conflict("03 Greensleeves.mp3", {"track": "3", "title": "Fantasia"}))
        self.assertEqual(sc.name_conflict("track.mp3", {"track": "3", "title": "Fantasia"}), "")
        # "<disc>-<track>" set off by underscores, behind the disc `group` adds:
        # the track is the 02, not the leading disc.
        grouped = "1-Kendrick Lamar_Mr. Morale & the Big Steppers_01-02_N95.flac"
        self.assertEqual(sc.from_name(grouped), {"disc": "01", "artist": "Kendrick Lamar", "track": "02",
                                                  "album": "Mr. Morale & the Big Steppers", "title": "N95"})
        self.assertEqual(sc.name_conflict(grouped, {"track": "2", "title": "N95"}), "")
        self.assertIn("track 2 in the name, 3 in the tags", sc.name_conflict(grouped, {"track": "3", "title": "N95"}))
        self.assertEqual(sc.from_name("2-Artist - Album - 03 Title.flac")["track"], "03")
        self.assertEqual(sc.from_name("1-Intro.mp3"), {"track": "1", "title": "Intro"})  # no disc: a track

    def test_name_layout(self):
        vinyl = [f"Animals as Leaders - The Joy of Motion [12 Vinyl 0{d}] - 0{t} T{d}{t}.flac"
                 for d in (1, 2) for t in range(1, 7)]
        layout = sc.name_layout(vinyl)
        self.assertEqual(layout, {"format": "Vinyl", "discs": [6, 6]})
        # Side two's "01" is track 7 across the release: no conflict.
        self.assertEqual(sc.name_offset(vinyl[6], layout), 6)
        self.assertEqual(sc.name_conflict(vinyl[6], {"track": "7", "title": "T21"}, 6), "")
        self.assertIn("track 1 in the name, 8 in the tags",
                      sc.name_conflict(vinyl[6], {"track": "8", "title": "T21"}, 6))
        self.assertTrue(sc.layout_fits(layout, '12" Vinyl', [6, 6]))
        self.assertFalse(sc.layout_fits(layout, "CD", [12]))
        self.assertFalse(sc.layout_fits(layout, "CD", [6, 6]))  # the format too
        self.assertEqual(sc.name_layout([f"1-0{t} T.flac" for t in (1, 2)] + [f"2-0{t} T.flac" for t in (1, 2, 3)]),
                         {"format": None, "discs": [2, 3]})
        self.assertIsNone(sc.name_layout([f"0{t} T.flac" for t in (1, 2)]))  # no discs
        self.assertIsNone(sc.name_layout(["1-01 T.flac", "1-02 T.flac"]))  # one disc, no format
        self.assertIsNone(sc.name_layout(["1-01 T.flac", "2-02 T.flac"]))  # a gap

    def test_length_off(self):
        self.assertEqual(sc.length_off(242, 240), 0)
        self.assertEqual(sc.length_off(256, 140), 116)
        self.assertEqual(sc.length_off(610, 596), 0)  # within 3% of a long track
        self.assertEqual(sc.length_off(0, 140), 0)

    def test_pack_round_trip(self):
        fp = [0, 1, 0xFFFFFFFF, 123456789]
        self.assertEqual(sc.unpack(sc.pack(fp)), fp)

    def test_same_recording(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            # Two tunes; the first also encoded again, as another rip would be.
            for n, e in (("a", "sin(2*PI*(220*pow(2,floor(mod(t*3,7))/12))*t)+0.5*sin(2*PI*110*pow(2,floor(mod(t,5))/7)*t)"),
                         ("b", "sin(2*PI*(330*pow(2,floor(mod(t*2,5))/12))*t)+0.5*sin(2*PI*165*pow(2,floor(mod(t*1.5,3))/5)*t)")):
                ffmpeg("-f", "lavfi", "-i", f"aevalsrc='{e}':d=20", str(d / f"{n}.flac"))
            ffmpeg("-i", str(d / "a.flac"), "-b:a", "96k", str(d / "a.mp3"))
            a, a2, b = (sc.fingerprint(d / n) for n in ("a.flac", "a.mp3", "b.flac"))
            self.assertIsNotNone(a)
            self.assertGreaterEqual(sc.similarity(a, a2), sc.SAME_RECORDING)
            self.assertLess(sc.similarity(a, b), sc.SAME_RECORDING)


@unittest.skipIf(sr is None, "beets is in the check on Linux only")
class Plugin(unittest.TestCase):
    """beetsplug/stagereview.py, on a scratch beets library: stage-review's
    decisions and answers, and stage-audit."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.d = Path(tmp.name)
        # beets' defaults only, never the config of whoever runs the tests.
        self.enterContext(mock.patch.dict(os.environ, BEETSDIR=str(self.d / "beets")))
        beets_config.clear()
        beets_config.read(user=False)
        # A file, not ":memory:": beets backs a new library up beside it (in
        # the working directory, for ":memory:") as it migrates it, and says so.
        with redirect_stdout(io.StringIO()):
            self.lib = Library(str(self.d / "library.db"), str(self.d / "music"))
        self.addCleanup(self.lib._close)
        self.staging = self.d / "staging" / "audio"
        self.staging.mkdir(parents=True)

    def album(self, tracks, files=False):
        """"A – Album", filed from the batch: (track, title, slot length)
        each. Its files exist when `files`."""
        items = []
        for n, title, length in tracks:
            path = self.d / "music" / "A" / "Album" / f"{n:02d} {title}.mp3"
            if files:
                path.parent.mkdir(parents=True, exist_ok=True)
                make_mp3(path)
            items.append(Item(path=os.fsencode(path), disc=1, track=n, title=title, length=length,
                              artist="A", albumartist="A", album="Album", mb_trackid=f"mb{n}",
                              stage_source=f"audio/Album/{n:02d} {title}.mp3"))
        self.lib.add_album(items)
        return items

    def manifest(self, records):
        """The batch's manifest: (original path, real length, title in its tags) each."""
        Path(f"{self.staging}.manifest.jsonl").write_text("".join(
            json.dumps({"path": p, "kind": "audio", "meta": {"duration": real, "tags": {"title": title}}}) + "\n"
            for p, real, title in records))

    def audit(self):
        return sr.audit(self.lib, str(self.staging))[0]

    def test_album_filed_earlier_in_the_run_is_filed(self):
        # One recording on a best-of and, ripped again, on its studio album.
        for folder in ("Best Of", "Studio"):
            (self.staging / folder).mkdir()
        tune = "sin(2*PI*(220*pow(2,floor(mod(t*3,7))/12))*t)+0.5*sin(2*PI*110*pow(2,floor(mod(t,5))/7)*t)"
        ffmpeg("-f", "lavfi", "-i", f"aevalsrc='{tune}':d=20", str(self.staging / "Best Of" / "a.flac"))
        ffmpeg("-i", str(self.staging / "Best Of" / "a.flac"), "-b:a", "96k", str(self.staging / "Studio" / "a.mp3"))
        session = sr.StageSession(self.lib, None, [], None, str(self.staging))

        def task(folder, name):
            path = next((self.staging / folder).iterdir())
            info = SimpleNamespace(album_id=name, artist="A", album=name, label=None, country=None, media="CD",
                                   year=None, tracks=[None], albumdisambig=None, data_url=None)
            return SimpleNamespace(
                paths=[os.fsencode(self.staging / folder)], rec=sr.Recommendation.strong,
                items=[Item(path=os.fsencode(path), track=1, title="Tune", length=20.0,
                            artist="A", albumartist="A", album=name)],
                candidates=[SimpleNamespace(distance=0.0, info=info, extra_items=[], extra_tracks=[])])

        best = task("Best Of", "Best Of")
        self.assertIs(session.choose_match(best), best.candidates[0])
        self.lib.add_album(best.items)  # as beets does, before it asks about the next album
        studio = task("Studio", "Studio")
        self.assertEqual(session.choose_match(studio), sr.Action.SKIP)
        self.assertEqual(session.review[0]["why"], "same recordings as 1 of these 1 files already filed")

    def test_dup_answer_names_the_library_album(self):
        twin = self.album([(1, "One", 60.0)])[0].get_album()
        session = sr.StageSession(self.lib, None, [], None, str(self.staging), answers={})
        [merge] = [o for o in session.dup_options(twin, 1) if o["value"].startswith("dup:merge")]
        # Answered without the page, as the media-share skill says: the item
        # is taken out of the review JSON.
        folder = self.staging / "Album (more)"
        item = Item(path=os.fsencode(folder / "02 Two.mp3"), track=2, title="Two")
        task = SimpleNamespace(paths=[os.fsencode(folder)], items=[item])
        session.answers[sr.item_id("Album (more)")] = {"choice": "option", "value": merge["value"]}
        self.assertEqual(session.answered(task), sr.Action.RETAG)
        self.assertEqual((item.albumartist, item.album), ("A", "Album"))
        self.assertEqual(session.get_duplicate_action(task, [twin]), sr.DuplicateAction.MERGE)

    def test_release_named_like_a_filed_album(self):
        twin = self.album([(1, "One", 60.0)])[0].get_album()
        twin.mb_albumid = "e1"
        twin.store()
        session = sr.StageSession(self.lib, None, [], None, str(self.staging))
        # The edition filed, a second edition of "A – Album", and a live album.
        first, edition, live = (SimpleNamespace(info=SimpleNamespace(album_id=r, artist="A", album=name))
                                for r, name in (("e1", "Album"), ("e2", "Album"), ("live", "Album (Live)")))
        offered = session.against_filed(
            [{"value": "mb:e1", "label": "A – Album (2000)", "detail": "", "recommended": False},
             {"value": "mb:e2", "label": "A – Album (2020)", "detail": "CD", "recommended": True},
             {"value": "mb:live", "label": "A – Album (Live)", "detail": "", "recommended": False}],
            [first, edition, live], twin)
        self.assertEqual([o["value"] for o in offered], ["mb:e2+remove", "mb:e2+keep", "mb:live"])
        self.assertFalse(any(o["recommended"] for o in offered))

        session = sr.StageSession(self.lib, None, [], None, str(self.staging), answers={})
        task = SimpleNamespace(paths=[os.fsencode(self.staging / "Album")], items=[], candidates=[])
        task.lookup_candidates = lambda ids: setattr(task, "candidates", [edition] if ids == ["e2"] else [])
        session.answers[sr.item_id("Album")] = {"choice": "option", "value": "mb:e2+keep"}
        self.assertIs(session.answered(task), edition)
        self.assertEqual(session.get_duplicate_action(task, [twin]), sr.DuplicateAction.KEEP)
        # Chosen bare, it waits in staging, and says why.
        session.dupmode.clear()
        session.answers[sr.item_id("Album")] = {"choice": "option", "value": "mb:e2"}
        self.assertIs(session.answered(task), edition)
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(session.get_duplicate_action(task, [twin]), sr.DuplicateAction.SKIP)
        self.assertIn("A – Album is already filed; left in staging", out.getvalue())
        # Tagged by hand like it: no release to offer again, so it says what the answer needs.
        session.answers[sr.item_id("Album")] = {"choice": "custom", "fields": {"albumartist": "A", "album": "Album"}}
        self.assertEqual(session.answered(task), sr.Action.RETAG)
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(session.get_duplicate_action(task, [twin]), sr.DuplicateAction.SKIP)
        self.assertIn('"on_duplicate"', out.getvalue())

    def test_import_log_is_written(self):
        log = self.d / "import.log"
        beets_config["import"]["log"] = str(log)
        beets_log = beets_logging.getLogger("beets")
        beets_log.set_global_level(beets_logging.INFO)  # as the `beet` command sets it
        self.addCleanup(beets_log.set_global_level, beets_logging.NOTSET)
        with redirect_stdout(io.StringIO()):
            sr.StageReview().run(self.lib, SimpleNamespace(answers=None, batch=None), [str(self.staging)])
        self.assertIn("import started", log.read_text())

    def test_audit_flags_what_it_could_not_compare(self):
        self.album([(1, "One", 60.0), (2, "Two", 90.0)])
        # Rescanned after filing: the manifest has only what is still in staging.
        self.manifest([("Leftover/x.mp3", 30, "x")])
        review = self.audit()
        self.assertEqual([r["title"] for r in review], ["1 One", "2 Two"])
        self.assertIn("not checked", review[0]["why"])
        self.assertEqual([o["value"] for o in review[0]["options"]], ["audit:ok"])
        sr.apply_audit_answers(self.lib, str(self.staging), {review[0]["id"]: {"choice": "option",
                                                                            "value": "audit:ok"}}, review)
        self.assertEqual([r["title"] for r in self.audit()], ["2 Two"])

    def test_audit_answer_for_an_item_out_of_the_review(self):
        self.album([(1, "One", 60.0), (2, "Two", 90.0)])
        self.manifest([("Album/01 One.mp3", 60, "One"), ("Album/02 Two.mp3", 200, "Two")])
        plugin = sr.StageReview()
        with redirect_stdout(io.StringIO()):
            plugin.run_audit(self.lib, SimpleNamespace(answers=None), [str(self.staging)])
        out = Path(f"{self.staging}.audit.review.json")
        doc = json.loads(out.read_text())
        [flagged] = doc["items"]
        # Settled without the page: an answer file, and the item out of the review JSON.
        out.write_text(json.dumps({**doc, "items": []}))
        answers = self.d / "audio.answers"
        answers.mkdir()
        (answers / f"{flagged['id']}.json").write_text(json.dumps(
            {"batch": "audio-audit", "item": flagged["id"], "choice": "option", "value": "audit:ok"}))
        with redirect_stdout(io.StringIO()):
            plugin.run_audit(self.lib, SimpleNamespace(answers=str(answers)), [str(self.staging)])
        self.assertTrue(json.loads(Path(f"{self.staging}.audit.json").read_text())["passed"])

    def test_audit_answer_outlives_a_rescan(self):
        items = self.album([(1, "One", 60.0), (2, "Two No. 5", 90.0)], files=True)
        self.manifest([("Album/01 One.mp3", 60, "One"), ("Album/02 Two No. 5.mp3", 90, "Two No. 3")])
        plugin = sr.StageReview()
        with redirect_stdout(io.StringIO()):
            plugin.run_audit(self.lib, SimpleNamespace(answers=None), [str(self.staging)])
        [two] = json.loads(Path(f"{self.staging}.audit.review.json").read_text())["items"]
        answers = self.d / "audio.answers"
        answers.mkdir()
        # Titled as the original was, from the page; and track 1 the same,
        # by hand, though the page never showed what its original was.
        for iid in (two["id"], sr.item_id(items[0]["stage_source"])):
            (answers / f"{iid}.json").write_text(json.dumps(
                {"batch": "audio-audit", "item": iid, "choice": "option", "value": "audit:original"}))
        # Rescanned before the answers are applied: the filed tracks' records are gone.
        self.manifest([("Leftover/x.mp3", 30, "x")])
        out = io.StringIO()
        with redirect_stdout(out):
            plugin.run_audit(self.lib, SimpleNamespace(answers=str(answers)), [str(self.staging)])
        for i in items:
            i.load()
        self.assertEqual(items[1].title, "Two No. 3")
        self.assertTrue(items[1].path.endswith(b"02 Two No. 3.mp3"))
        self.assertEqual(items[0].title, "One")
        self.assertIn("1 One: its original title went with its manifest record; still flagged", out.getvalue())
        self.assertEqual([r["title"] for r in self.audit()], ["1 One"])

    def test_audit_never_leaves_two_tracks_in_one_slot(self):
        items = self.album([(1, "One", 60.0), (2, "Two", 90.0), (3, "Three", 130.0), (4, "Four", 180.0),
                            (5, "Five", 245.0)], files=True)
        # Track 3's file is really 4:02, as long as slot 5; so is slot 5's own file.
        self.manifest([(f"Album/{i.track:02d} {i.title}.mp3", real, i.title)
                       for i, real in zip(items, (60, 90, 242, 180, 246))])
        [three] = self.audit()
        [slot5] = [o for o in three["options"] if o["value"] == "audit:slot:1-5"]
        self.assertFalse(slot5["recommended"])
        self.assertIn("the file there fits it too", slot5["detail"])
        # Chosen all the same, with slot 5's file accepted before: it is
        # flagged again, as sharing its slot, and its answer from then, still
        # among the batch's, doesn't accept it again, round after round.
        items[4]["stage_audit"] = "ok"
        items[4].store()
        answers = self.d / "audio.answers"
        answers.mkdir()
        for iid, value in ((three["id"], "audit:slot:1-5"), (sr.item_id(items[4]["stage_source"]), "audit:ok")):
            (answers / f"{iid}.json").write_text(json.dumps(
                {"batch": "audio-audit", "item": iid, "choice": "option", "value": value}))
        plugin = sr.StageReview()
        for _ in range(2):
            with redirect_stdout(io.StringIO()):
                plugin.run_audit(self.lib, SimpleNamespace(answers=str(answers)), [str(self.staging)])
            [five] = json.loads(Path(f"{self.staging}.audit.review.json").read_text())["items"]
            self.assertEqual(five["key"], "audio/Album/05 Five.mp3")
            self.assertIn("shares track 5 with “Five”", five["why"])
            self.assertIsNone(json.loads(Path(f"{self.staging}.audit.json").read_text())["passed"])

    def test_audit_flags_a_track_moved_onto_a_file_it_cant_check(self):
        items = self.album([(1, "One", 60.0), (2, "Two", 90.0), (3, "Three", 180.0)], files=True)
        # Track 3 was filed from another batch; track 2's file is really 3:01.
        del items[2]["stage_source"]
        items[2].store()
        self.manifest([("Album/01 One.mp3", 60, "One"), ("Album/02 Two.mp3", 181, "Two")])
        [two] = self.audit()
        [slot3] = [o for o in two["options"] if o["value"] == "audit:slot:1-3"]
        self.assertFalse(slot3["recommended"])
        self.assertIn("the file there can't be checked here", slot3["detail"])
        with redirect_stdout(io.StringIO()):
            sr.apply_audit_answers(self.lib, str(self.staging), {two["id"]: {"choice": "option",
                                                                              "value": "audit:slot:1-3"}}, [two])
        [moved] = self.audit()
        self.assertEqual((moved["key"], moved["title"]), ("audio/Album/02 Two.mp3", "3 Three"))
        self.assertIn("shares track 3 with “Three”", moved["why"])
        self.assertNotEqual(moved["id"], two["id"])


class Pipeline(unittest.TestCase):
    def test_batch(self):
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            st = lib / "staging" / "batch"
            (st / "sub").mkdir(parents=True)
            make_video(st / "The.Matrix.1999.1080p.BluRay.x264.mkv")
            (st / "The.Matrix.1999.1080p.BluRay.x264.en.srt").write_text("1\n00:00:00,000 --> 00:00:01,000\nhi\n")
            make_video(st / "sub" / "Breaking.Bad.2008.S01E02.720p.mp4")
            make_video(st / "clip.mp4")
            (st / "clip.info.json").write_text(json.dumps(
                {"id": "abc123XYZ_-", "title": "How to: tune a guitar?", "channel": "Guitar Chan",
                 "upload_date": "20240501"}))
            make_video(st / "IMG_4211.mov")
            make_epub(st / "stranger.epub", "The Stranger: A Novel", "Camus, Albert")
            make_epub(st / "untitled.epub", None, None)
            make_pdf(st / "rules_final_v2.pdf", title="document")
            ffmpeg("-f", "lavfi", "-i", "sine=f=220", "-t", "1", "-metadata", "artist=A", str(st / "song.mp3"))
            (st / ".DS_Store").write_bytes(b"junk")
            (st / ".commons-print").mkdir()
            (st / ".commons-print" / "index.json").write_text("{}")

            code, out = run_cli("scan", str(st), "--hash", "--library", str(lib))
            self.assertEqual(code, 0, out)
            self.assertIn("10 files", out)
            self.assertIn("ignored", out)

            code, out = run_cli("draft", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            table = Path(str(st) + ".tsv")
            rows = {l.split("\t")[0]: l.rstrip("\n").split("\t") for l in table.read_text().splitlines()[1:]}
            self.assertEqual(rows["The.Matrix.1999.1080p.BluRay.x264.mkv"][1], "movies/The Matrix (1999)/The Matrix (1999).mkv")
            self.assertEqual(rows["The.Matrix.1999.1080p.BluRay.x264.en.srt"][1], "movies/The Matrix (1999)/The Matrix (1999).en.srt")
            self.assertTrue(rows["sub/Breaking.Bad.2008.S01E02.720p.mp4"][1].startswith(
                "tv/Breaking Bad (2008)/Season 01/Breaking Bad (2008) - S01E02"), rows["sub/Breaking.Bad.2008.S01E02.720p.mp4"])
            self.assertEqual(rows["clip.mp4"][1], "youtube/Guitar Chan/2024-05-01 - How to tune a guitar [abc123XYZ_-].mp4")
            self.assertEqual(rows["clip.info.json"][1], "youtube/Guitar Chan/2024-05-01 - How to tune a guitar [abc123XYZ_-].info.json")
            self.assertEqual(rows["stranger.epub"][1], "books/Albert Camus/The Stranger/The Stranger.epub")
            self.assertEqual(rows["song.mp3"][1], "beets")
            self.assertEqual(rows["IMG_4211.mov"][1], "")
            self.assertEqual(rows["rules_final_v2.pdf"][1], "")
            self.assertIn("Title=document", rows["rules_final_v2.pdf"][3])

            # Blank rows block the batch.
            code, out = run_cli("check", str(st), "--library", str(lib))
            self.assertEqual(code, 1)
            self.assertIn("is blank", out)

            # Review: fill the blanks, as a person or Claude would.
            text = table.read_text().splitlines()
            fill = {
                "IMG_4211.mov": "skip",
                "rules_final_v2.pdf": "rpg/Test Game/Test Game - Rules (pages).pdf",
                "untitled.epub": "books/Nobody/Untitled/Untitled.epub",
            }
            text = [l if l.split("\t")[0] not in fill else
                    "\t".join([l.split("\t")[0], fill[l.split("\t")[0]]] + l.split("\t")[2:]) for l in text]
            table.write_text("\n".join(text) + "\n")

            code, out = run_cli("check", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)

            code, out = run_cli("apply", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            self.assertTrue((lib / "movies/The Matrix (1999)/The Matrix (1999).mkv").exists())
            self.assertTrue((st / "song.mp3").exists())      # beets' job
            self.assertIn(f"then `beet stage-review {st}`", out)
            self.assertNotIn("beet import", out)
            self.assertTrue((st / "IMG_4211.mov").exists())  # skipped
            self.assertFalse((st / "sub").exists())          # emptied dirs are removed

            # Standard metadata written.
            meta = ms.current_meta
            self.assertEqual(meta(lib / "movies/The Matrix (1999)/The Matrix (1999).mkv")["title"], "The Matrix (1999)")
            yt = next((lib / "youtube/Guitar Chan").glob("*.mp4"))
            self.assertEqual(meta(yt)["title"], "How to tune a guitar")
            # Books and RPGs: what Kavita groups by — the folder is the series.
            rules = meta(lib / "rpg/Test Game/Test Game - Rules (pages).pdf")
            self.assertEqual({k: rules[k] for k in ("title", "series", "volume", "plain")},
                             {"title": "Test Game - Rules (pages)", "series": "Test Game", "volume": "", "plain": True})
            self.assertEqual(rules["source"], json.loads(next(
                l for l in Path(str(st) + ".applied.jsonl").read_text().splitlines() if "rules_final" in l))["sha256"])
            untitled = lib / "books/Nobody/Untitled/Untitled.epub"
            self.assertEqual(ms.epub_meta(untitled)["title"], "Untitled")
            self.assertEqual(ms.epub_meta(untitled)["creators"], ["Nobody"])
            # An unnumbered EPUB is its own series, named by its (first) title:
            # ours goes first; the publisher's is kept after it.
            stranger = lib / "books/Albert Camus/The Stranger/The Stranger.epub"
            self.assertEqual(ms.epub_meta(stranger)["title"], "The Stranger")
            with zipfile.ZipFile(stranger) as z:
                self.assertIn(b"The Stranger: A Novel", z.read("OEBPS/content.opf"))
            with zipfile.ZipFile(untitled) as z:
                first = z.infolist()[0]
                self.assertEqual((first.filename, first.compress_type), ("mimetype", zipfile.ZIP_STORED))

            # The library lints clean, and a second apply is a no-op.
            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 0, out)
            code, out = run_cli("apply", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            self.assertIn("moved 0", out)

            # lint notices a file dropped in by hand.
            (lib / "movies" / "loose.mp4").write_bytes(b"")
            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 1)
            self.assertIn("LAYOUT movies/loose.mp4", out)


class Concurrency(unittest.TestCase):
    """Two hosts, one library: the guards in validate, apply and the locks."""

    def batch(self, d):
        lib = Path(d)
        st = lib / "staging" / "b"
        st.mkdir(parents=True)
        make_video(st / "Heat.1995.mkv")
        self.assertEqual(run_cli("scan", str(st), "--library", str(lib))[0], 0)
        self.assertEqual(run_cli("draft", str(st), "--library", str(lib))[0], 0)
        return lib, st

    def test_library_lock_from_another_host_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            lib, st = self.batch(d)
            (lib / ".media-stage.lock").write_text("mba 123 apply other 2026-09-25T20:00:00\n")
            code, out = run_cli("apply", str(st), "--library", str(lib))
            self.assertNotEqual(code, 0)
            self.assertTrue((st / "Heat.1995.mkv").exists())
            self.assertTrue((lib / ".media-stage.lock").exists())  # not ours to remove

    @unittest.skipIf(os.geteuid() == 0, "root writes through 0555")
    def test_read_only_library_says_run_on_desk(self):
        # The Mac: staging on its own share, the library read-only.
        with tempfile.TemporaryDirectory() as d:
            lib, st = Path(d) / "media", Path(d) / "media-staging" / "b"
            (lib / "movies").mkdir(parents=True)
            st.mkdir(parents=True)
            make_video(st / "Heat.1995.mkv")
            for cmd in ("scan", "draft", "check"):
                self.assertEqual(run_cli(cmd, str(st), "--library", str(lib))[0], 0)
            lib.chmod(0o555)
            try:
                code, out = run_cli("apply", str(st), "--library", str(lib))
            finally:
                lib.chmod(0o755)
            self.assertNotEqual(code, 0)
            self.assertIn("ssh desk media-stage apply", out)
            self.assertTrue((st / "Heat.1995.mkv").exists())

    def test_stale_lock_on_this_host_is_cleared(self):
        with tempfile.TemporaryDirectory() as d:
            lib, st = self.batch(d)
            p = subprocess.Popen(["true"])
            p.wait()  # a pid that is certainly gone
            (lib / ".media-stage.lock").write_text(f"{ms.socket.gethostname()} {p.pid} apply x\n")
            code, out = run_cli("apply", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            self.assertFalse((lib / ".media-stage.lock").exists())
            self.assertFalse(Path(str(st) + ".lock").exists())

    def test_staging_given_as_dot(self):
        # From inside the batch: its sidecars, lock and trash still go beside it.
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            st = lib / "staging" / "b"
            st.mkdir(parents=True)
            make_pdf(st / "c.pdf")
            cwd = os.getcwd()
            os.chdir(st)
            try:
                for cmd in ("scan", "draft"):
                    code, out = run_cli(cmd, ".", "--library", str(lib))
                    self.assertEqual(code, 0, out)
                self.assertEqual(sorted(p.name for p in st.parent.iterdir()), ["b", "b.manifest.jsonl", "b.tsv"])
                Path(str(st) + ".tsv").write_text("old\tnew\nc.pdf\ttrash\n")
                code, out = run_cli("apply", ".", "--library", str(lib))
                self.assertEqual(code, 0, out)
            finally:
                os.chdir(cwd)
            self.assertTrue((lib / "staging/trash/b/c.pdf").exists())
            self.assertTrue(Path(str(st) + ".applied.jsonl").exists())
            self.assertEqual(list(st.iterdir()), [])

    def test_file_changed_since_scan_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            lib, st = self.batch(d)
            with open(st / "Heat.1995.mkv", "ab") as f:
                f.write(b"\0" * 10)  # still being copied
            code, out = run_cli("check", str(st), "--library", str(lib))
            self.assertEqual(code, 1)
            self.assertIn("changed since scan", out)

    def test_discard_changed_since_scan_is_refused(self):
        # A copy drafted as the worse one while it was still being copied:
        # apply deletes a `discard` row, so it is held to its scan too.
        for new in ("discard", "trash"):
            with tempfile.TemporaryDirectory() as d:
                lib, st = self.batch(d)
                Path(str(st) + ".tsv").write_text(f"old\tnew\nHeat.1995.mkv\t{new}\n")
                with open(st / "Heat.1995.mkv", "ab") as f:
                    f.write(b"\0" * 10)
                code, out = run_cli("apply", str(st), "--library", str(lib))
                self.assertEqual(code, 1, new)
                self.assertIn("changed since scan", out)
                self.assertTrue((st / "Heat.1995.mkv").exists())

    def test_case_clash_with_library_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            lib, st = self.batch(d)
            (lib / "movies" / "HEAT (1995)").mkdir(parents=True)
            code, out = run_cli("check", str(st), "--library", str(lib))
            self.assertEqual(code, 1)
            self.assertIn("only in case", out)

    @unittest.skipUnless(case_sensitive_tmp(), "case-insensitive filesystem (macOS default)")
    def test_lint_reports_case_siblings(self):
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            (lib / "rpg" / "Cairn").mkdir(parents=True)
            (lib / "rpg" / "cairn").mkdir(parents=True)
            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 1)
            self.assertIn("CASE", out)

    def test_move_never_replaces(self):
        with tempfile.TemporaryDirectory() as d:
            a, b = Path(d, "a"), Path(d, "b")
            a.write_text("new")
            b.write_text("existing")
            with self.assertRaises(FileExistsError):
                ms.move_noclobber(a, b)
            self.assertEqual((a.read_text(), b.read_text()), ("new", "existing"))

    def test_draft_keeps_review_and_adds_new_files(self):
        with tempfile.TemporaryDirectory() as d:
            lib, st = self.batch(d)
            table = Path(str(st) + ".tsv")
            reviewed = table.read_text().replace("movies/Heat (1995)/Heat (1995).mkv", "movies/Heat (1995)/Heat (1995) - Reviewed.mkv")
            table.write_text(reviewed)
            make_video(st / "Alien.1979.mkv")
            run_cli("scan", str(st), "--library", str(lib))
            code, out = run_cli("draft", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            self.assertIn("kept 1 rows, added 1", out)
            text = table.read_text()
            self.assertIn("Heat (1995) - Reviewed.mkv", text)
            self.assertIn("movies/Alien (1979)/Alien (1979).mkv", text)

    def test_sidecar_added_later_follows_the_reviewed_row(self):
        with tempfile.TemporaryDirectory() as d:
            lib, st = self.batch(d)
            table = Path(str(st) + ".tsv")
            reviewed = "movies/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}"
            table.write_text(table.read_text().replace("movies/Heat (1995)/Heat (1995)", reviewed))
            (st / "Heat.1995.en.srt").write_text("1\n00:00:00,000 --> 00:00:01,000\nhi\n")
            run_cli("scan", str(st), "--library", str(lib))
            code, out = run_cli("draft", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            rows = {l.split("\t")[0]: l.split("\t")[1] for l in table.read_text().splitlines()[1:]}
            self.assertEqual(rows["Heat.1995.en.srt"], reviewed + ".en.srt")
            # A video set aside keeps its subtitle with it.
            table.write_text("".join(l.replace(reviewed + ".mkv", "skip") + "\n" for l in table.read_text().splitlines()
                                     if not l.startswith("Heat.1995.en.srt")))
            code, out = run_cli("draft", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            rows = {l.split("\t")[0]: l.split("\t")[1] for l in table.read_text().splitlines()[1:]}
            self.assertEqual(rows["Heat.1995.en.srt"], "skip")


def fake_wikidata(entities):
    """A Wikidata API stand-in: `entities` is {qid: (label, prop, tmdb, year, lang_qid)}."""
    def claim(v):
        return {"mainsnak": {"datavalue": {"value": v}}}

    def fetch(params):
        if params["action"] == "query":
            prop = params["srsearch"].rsplit("haswbstatement:", 1)[1]
            return {"query": {"search": [{"title": q} for q, e in entities.items() if e[1] == prop]}}
        out = {}
        for q in params["ids"].split("|"):
            if q.startswith("L"):  # a language item: L1 German, L2 English
                de = q == "L1"
                out[q] = {"claims": {"P218": [claim("de" if de else "en")], "P219": [claim("ger" if de else "eng")]}}
                continue
            label, prop, tmdb, year, lang = entities[q]
            date = "P577" if prop == "P4947" else "P580"
            claims = {prop: [claim(tmdb)], date: [claim({"time": f"+{year}-01-01T00:00:00Z"})]}
            if lang:  # the original is preferred over the languages it was released in
                claims["P364"] = [claim({"id": "L2"}), {**claim({"id": lang}), "rank": "preferred"}]
            out[q] = {"labels": {"en": {"value": label}}, "claims": claims}
        return {"entities": out}
    return fetch


def video_rec(path, video="h264 1280x720", audio=("eng",), duration=60.0):
    """A video's manifest record, as scan_file writes one."""
    return {"path": path, "size": 1, "kind": "video", "ext": ms.ext_of(path), "guess": ms.guess(Path(path).name),
            "meta": {"duration": duration, "bit_rate": 0, "tags": {}, "video": video,
                     "audio_langs": list(audio), "sub_langs": []}}


def draft_rows(d, recs, lookup=None):
    """draft on a manifest of `recs` (batch staging/b, library `d`): {old: [new, confidence, note]}."""
    st = Path(d) / "staging" / "b"
    st.mkdir(parents=True, exist_ok=True)
    Path(str(st) + ".manifest.jsonl").write_text(
        "".join(json.dumps(r) + "\n" for r in sorted(recs, key=lambda r: r["path"])))  # walk's order
    ns = type("A", (), {"staging": str(st), "library": d, "force": False, "lookup": False})
    with redirect_stdout(io.StringIO()):
        ms.draft(ns, lookup=lookup)
    return {l.split("\t")[0]: l.split("\t")[1:] for l in Path(str(st) + ".tsv").read_text().splitlines()[1:]}


class Copies(unittest.TestCase):
    """Duplicates: content already filed, and several copies of one film."""

    def test_filed_pdf_is_recognised_after_its_metadata_was_rewritten(self):
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            st = lib / "staging" / "one"
            st.mkdir(parents=True)
            make_pdf(st / "Game_Rules_OEF2025.pdf", title="x")
            original = (st / "Game_Rules_OEF2025.pdf").read_bytes()
            run_cli("scan", str(st), "--hash", "--library", str(lib))
            run_cli("draft", str(st), "--library", str(lib))
            table = Path(str(st) + ".tsv")
            table.write_text(table.read_text().replace("\t\t\tclassify", "\trpg/Game/Rules.pdf\thigh\tclassify"))
            code, out = run_cli("apply", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            filed = lib / "rpg/Game/Rules.pdf"
            self.assertNotEqual(filed.read_bytes(), original)  # rewritten whole, with its metadata
            log = Path(str(st) + ".applied.jsonl").read_text()
            import hashlib
            self.assertEqual(json.loads(log)["sha256"], hashlib.sha256(original).hexdigest())
            self.assertEqual(ms.pdf_meta(filed)["source"], hashlib.sha256(original).hexdigest())

            for with_log in (True, False):
                if not with_log:  # a closed batch: the file's own record is enough
                    Path(str(st) + ".applied.jsonl").unlink()
                again = lib / "staging" / f"two{with_log}"
                again.mkdir()
                (again / "rules.pdf").write_bytes(original)
                run_cli("scan", str(again), "--hash", "--library", str(lib))
                code, out = run_cli("draft", str(again), "--library", str(lib))
                self.assertIn("1 copies set aside", out)
                row = Path(str(again) + ".tsv").read_text().splitlines()[1].split("\t")
                self.assertEqual(row[1:3], ["discard", "high"])
                self.assertIn("already filed as rpg/Game/Rules.pdf", row[3])
                # check refuses to file it again under another name.
                t = Path(str(again) + ".tsv")
                t.write_text(t.read_text().replace("\tdiscard\t", "\trpg/Game/Rules again.pdf\t"))
                code, out = run_cli("check", str(again), "--library", str(lib))
                self.assertEqual(code, 1)
                self.assertIn("already filed as rpg/Game/Rules.pdf", out)

    def test_pdf_titled_by_exiftool_is_recognised_and_cleaned(self):
        # How apply wrote PDF titles before: an incremental update, which
        # Kavita reads with the rest and may choke on.
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            old = lib / "rpg/Game/Game - Rules (v2).pdf"
            old.parent.mkdir(parents=True)
            make_pdf(old, title="document")
            original = old.read_bytes()
            subprocess.run(["exiftool", "-q", "-overwrite_original", "-Title=Game - Rules", str(old)], check=True)
            self.assertTrue(old.read_bytes().startswith(original))
            self.assertFalse(ms.pdf_meta(old)["plain"])
            import hashlib
            digest = hashlib.sha256(original).hexdigest()
            self.assertEqual(ms.pdf_original_sha256(old), digest)
            self.assertEqual(ms.FiledIndex(lib).find("pdf", len(original), digest), "rpg/Game/Game - Rules (v2).pdf")

            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 1)
            self.assertIn("Kavita reads 'Game - Rules (v2)' as volume 2", out)
            # Renamed through a batch: restage, then file it as any other.
            st = lib / "staging" / "kavita"
            code, out = run_cli("restage", str(st), "rpg/Game", "--library", str(lib))
            self.assertEqual(code, 0, out)
            self.assertFalse((lib / "rpg/Game").exists())
            run_cli("scan", str(st), "--hash", "--library", str(lib))
            run_cli("draft", str(st), "--library", str(lib))
            table = Path(str(st) + ".tsv")
            table.write_text(table.read_text().replace(
                "\t\t\tclassify", "\trpg/Game/Game - Rules (version 2).pdf\thigh\tclassify"))
            code, out = run_cli("apply", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            new = lib / "rpg/Game/Game - Rules (version 2).pdf"
            got = ms.pdf_meta(new)
            self.assertEqual((got["title"], got["series"], got["plain"], got["source"]),
                             ("Game - Rules (version 2)", "Game", True, digest))
            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 0, out)
            # The download, staged again, is known.
            self.assertEqual(ms.FiledIndex(lib).find("pdf", len(original), digest), "rpg/Game/Game - Rules (version 2).pdf")

    def test_pdf_with_object_streams_is_written_plain(self):
        # Kavita cannot reach a catalog kept in an object stream, and with it
        # the XMP: its series came out as the folder's name, parsed.
        import pikepdf
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            pdf = lib / "rpg/D&D 5e/Monster Manual.pdf"
            pdf.parent.mkdir(parents=True)
            make_pdf(lib / "plain.pdf", title="Monster Manual")
            with pikepdf.open(lib / "plain.pdf") as p:
                p.save(pdf, object_stream_mode=pikepdf.ObjectStreamMode.generate)
            (lib / "plain.pdf").unlink()
            self.assertFalse(ms.pdf_meta(pdf)["plain"])
            code, out = run_cli("lint", "--library", str(lib))
            self.assertIn("object streams", out)
            run_cli("lint", "--fix", "--library", str(lib))
            got = ms.pdf_meta(pdf)
            self.assertEqual((got["plain"], got["series"]), (True, "D&D 5e"))
            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 0, out)

    def test_epub_and_cbz_carry_their_series(self):
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            book = lib / "books/Terry Pratchett/Discworld/Discworld Vol. 3 - Equal Rites.epub"
            book.parent.mkdir(parents=True)
            make_epub(book, "Equal Rites: A Discworld Novel", "Pratchett, Terry")
            # A publisher's collection names another series: ours replaces it.
            with zipfile.ZipFile(book) as z:
                opf = z.read("OEBPS/content.opf").decode().replace("</metadata>",
                    '<meta property="belongs-to-collection" id="c1">Witches</meta>'
                    '<meta refines="#c1" property="group-position">1</meta></metadata>')
            ms.rewrite_zip(book, {"OEBPS/content.opf": opf.encode()})
            self.assertEqual(ms.epub_meta(book)["series"], "Witches")
            maps = lib / "rpg/Silveraxe/Silveraxe - Maps.cbz"
            maps.parent.mkdir(parents=True)
            with zipfile.ZipFile(maps, "w") as z:
                z.writestr("01.jpg", b"not really")
            code, out = run_cli("lint", "--fix", "--library", str(lib))
            self.assertEqual(code, 0, out)
            m = ms.epub_meta(book)
            self.assertEqual((m["title"], m["series"], m["volume"], m["creators"]),
                             ("Equal Rites", "Discworld", "3", ["Pratchett, Terry"]))
            with zipfile.ZipFile(book) as z:
                self.assertNotIn(b"group-position", z.read("OEBPS/content.opf"))
                self.assertEqual(z.infolist()[0].filename, "mimetype")
            c = ms.cbz_meta(maps)
            self.assertEqual((c["title"], c["series"], c["volume"]), ("Silveraxe - Maps", "Silveraxe", ""))
            self.assertEqual(len(c["source"]), 64)
            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 0, out)

    def test_zip_is_filed_as_it_came_and_extras_are_left_alone(self):
        # A module's zips, as itch.io has them. Kavita shows a zip's images
        # and reads nothing else from it (its series is its folder's name,
        # while its name has no digits), so the maps go beside the books as
        # they came. An app has no images: it goes in the game's extras/,
        # which Kavita passes over. A soundtrack is for beets.
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            st = lib / "staging" / "zips"
            st.mkdir(parents=True)
            with zipfile.ZipFile(st / "Maps.zip", "w") as z:
                z.writestr("Maps/deck-1.png", b"not really")
                z.writestr("Maps/deck-2.png", b"not really")
            with zipfile.ZipFile(st / "App WIN.zip", "w") as z:
                z.writestr("App/App.exe", b"MZ")
                z.writestr("App/readme.txt", b"run it")
            with zipfile.ZipFile(st / "Soundtrack.zip", "w") as z:
                z.writestr("OST/01 Intro.mp3", b"not really")
                z.writestr("OST/02 Outro.mp3", b"not really")
            make_pdf(st / "handout.pdf", title="x")
            maps, app, handout = ((st / n).read_bytes() for n in ("Maps.zip", "App WIN.zip", "handout.pdf"))
            run_cli("scan", str(st), "--hash", "--library", str(lib))
            run_cli("draft", str(st), "--library", str(lib))
            table = Path(str(st) + ".tsv")
            notes = {r.split("\t")[0]: r.split("\t")[3] for r in table.read_text().splitlines()[1:]}
            self.assertIn("archive of images (2 png)", notes["Maps.zip"])
            self.assertIn("archive with no images (1 exe, 1 txt)", notes["App WIN.zip"])
            self.assertIn("archive of audio (2 mp3): unpack it into a batch of its own for beets", notes["Soundtrack.zip"])
            # Beside the books, an archive with no images is refused.
            rows = {"Maps.zip": "rpg/Game/Game - Maps.zip", "App WIN.zip": "rpg/Game/App (Windows).zip",
                    "Soundtrack.zip": "skip", "handout.pdf": "rpg/Game/extras/Handout (v2).pdf"}
            write = lambda: table.write_text("old\tnew\n" + "".join(f"{o}\t{n}\n" for o, n in rows.items()))
            write()
            code, out = run_cli("check", str(st), "--library", str(lib))
            self.assertEqual(code, 1, out)
            self.assertIn("rpg/Game/App (Windows).zip: no images in it, so nothing for Kavita to show: "
                          "a game's other files go in rpg/Game/extras/", out)
            rows["App WIN.zip"] = "rpg/Game/extras/App (Windows).zip"
            write()
            code, out = run_cli("apply", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            # All as they came: nothing is written into a zip, or into extras/.
            self.assertEqual((lib / "rpg/Game/Game - Maps.zip").read_bytes(), maps)
            self.assertEqual((lib / "rpg/Game/extras/App (Windows).zip").read_bytes(), app)
            self.assertEqual((lib / "rpg/Game/extras/Handout (v2).pdf").read_bytes(), handout)
            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 0, out)
            # The maps, downloaded again: the same bytes as the filed zip's.
            Path(str(st) + ".applied.jsonl").unlink()
            again = lib / "staging" / "again"
            again.mkdir()
            (again / "maps.zip").write_bytes(maps)
            run_cli("scan", str(again), "--hash", "--library", str(lib))
            run_cli("draft", str(again), "--library", str(lib))
            row = Path(str(again) + ".tsv").read_text().splitlines()[1].split("\t")
            self.assertEqual(row[1], "discard")
            self.assertIn("already filed as rpg/Game/Game - Maps.zip", row[3])
            # One with no images, beside the books all the same: lint says where it goes.
            with zipfile.ZipFile(lib / "rpg/Game/Stray.zip", "w") as z:
                z.writestr("notes.txt", b"x")
            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 1, out)
            self.assertIn("LAYOUT rpg/Game/Stray.zip: no images in it", out)

    def test_damaged_book_is_filed_and_logged(self):
        # Its OPF reads, one chapter doesn't (a bad CRC-32): apply files and
        # logs it with the error and goes on; lint --fix reports it.
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            st = lib / "staging" / "b"
            st.mkdir(parents=True)
            make_epub(st / "a.epub", "Alpha", "Author, Ann")
            with zipfile.ZipFile(st / "a.epub", "a") as z:
                z.writestr("OEBPS/ch1.xhtml", "<html>chapter one</html>")
            (st / "a.epub").write_bytes((st / "a.epub").read_bytes().replace(b"chapter one", b"chapter 0ne"))
            make_pdf(st / "b.pdf", title="b")
            run_cli("scan", str(st), "--library", str(lib))
            Path(str(st) + ".tsv").write_text("old\tnew\na.epub\tbooks/Ann Author/Alpha/Alpha.epub\n"
                                              "b.pdf\trpg/Game/Beta.pdf\n")
            code, out = run_cli("apply", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            log = {e["old"]: e for e in map(json.loads, Path(str(st) + ".applied.jsonl").read_text().splitlines())}
            self.assertEqual(sorted(log), ["a.epub", "b.pdf"])
            self.assertIn("Bad CRC-32", log["a.epub"]["metadata"][0])
            self.assertEqual(ms.pdf_meta(lib / "rpg/Game/Beta.pdf")["title"], "Beta")
            code, out = run_cli("lint", "--fix", "--library", str(lib))
            self.assertEqual(code, 1, out)
            self.assertIn("FAILED books/Ann Author/Alpha/Alpha.epub: not written: Bad CRC-32", out)

    def test_epub2_keeps_its_opf_attributes(self):
        # calibre's EPUB2 OPF: the author's sort name and role, and the
        # identifier's scheme, are attributes in the OPF namespace.
        with tempfile.TemporaryDirectory() as d:
            book = Path(d) / "stranger.epub"
            make_epub(book, "The Stranger", None)
            ms.rewrite_zip(book, {"OEBPS/content.opf": b"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uuid_id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>The Stranger</dc:title>
    <dc:creator opf:file-as="Camus, Albert" opf:role="aut">Albert Camus</dc:creator>
    <dc:identifier id="uuid_id" opf:scheme="ISBN">9780679720201</dc:identifier>
  </metadata>
  <manifest/><spine/>
</package>"""})
            ms.epub_write(book, {"title": "The Stranger", "series": "Absurd", "volume": "1"}, source="0" * 64)
            with zipfile.ZipFile(book) as z:
                md = ms.ET.fromstring(z.read("OEBPS/content.opf")).find("opf:metadata", ms.NS)
            opf = "{%s}" % ms.NS["opf"]
            creator, ident = md.find("dc:creator", ms.NS), md.find("dc:identifier", ms.NS)
            self.assertEqual((creator.get(opf + "file-as"), creator.get(opf + "role"), ident.get(opf + "scheme")),
                             ("Camus, Albert", "aut", "ISBN"))
            m = ms.epub_meta(book)
            self.assertEqual((m["title"], m["series"], m["volume"], m["source"]), ("The Stranger", "Absurd", "1", "0" * 64))

    def test_epub2_written_bare_is_mended(self):
        # As the ElementTree version left a book: the attributes bare, no
        # opf: prefix declared, and its sha256 already in a dc:source, so
        # nothing else about it would make `tag` write it.
        with tempfile.TemporaryDirectory() as d:
            book = Path(d) / "stranger.epub"
            make_epub(book, "The Stranger", None)
            ms.rewrite_zip(book, {"OEBPS/content.opf": ("""<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" unique-identifier="PrimaryID" version="2.0">
  <metadata>
    <dc:identifier id="PrimaryID" scheme="ISBN">978-0-307-82766-1</dc:identifier>
    <dc:creator file-as="Camus, Albert" role="aut">Albert Camus</dc:creator>
    <dc:date event="publication">2012-07-18</dc:date>
    <meta content="cover-image" name="cover" />
  <dc:title>The Stranger</dc:title><dc:source>sha256:%s</dc:source></metadata>
  <manifest/><spine/>
</package>""" % ("0" * 64)).encode()})
            rel = "books/Albert Camus/The Stranger/The Stranger.epub"
            self.assertEqual(ms.shelf_todo(rel, ms.current_meta(book)).get("opf"), "event,file-as,role,scheme")
            ms.epub_write(book, {"title": "The Stranger", "author": "Albert Camus"}, source="0" * 64)
            self.assertNotIn("opf", ms.shelf_todo(rel, ms.current_meta(book)))
            with zipfile.ZipFile(book) as z:
                raw = z.read("OEBPS/content.opf")
            md = ms.ET.fromstring(raw).find("opf:metadata", ms.NS)
            opf = "{%s}" % ms.NS["opf"]
            creator, ident, date = (md.find(f"dc:{t}", ms.NS) for t in ("creator", "identifier", "date"))
            self.assertEqual((creator.get(opf + "file-as"), creator.get(opf + "role"),
                              ident.get(opf + "scheme"), date.get(opf + "event")),
                             ("Camus, Albert", "aut", "ISBN", "publication"))
            self.assertNotIn(b' role="', raw)
            self.assertIn(b"opf:role=", raw)
            self.assertEqual(ident.get("id"), "PrimaryID")
            self.assertIsNotNone(md.find("opf:meta[@name='cover']", ms.NS))
            m = ms.epub_meta(book)
            self.assertEqual((m["title"], m["source"]), ("The Stranger", "0" * 64))

    def test_one_file_per_volume(self):
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            st = lib / "staging" / "v"
            st.mkdir(parents=True)
            make_pdf(st / "a.pdf", title="a")
            make_pdf(st / "b.pdf", title="b")
            run_cli("scan", str(st), "--library", str(lib))
            Path(str(st) + ".tsv").write_text(
                "old\tnew\n"
                "a.pdf\tbooks/X/Saga/Saga Vol. 1 - One (pages).pdf\n"
                "b.pdf\tbooks/X/Saga/Saga Vol. 1 - One (spreads).pdf\n")
            code, out = run_cli("check", str(st), "--library", str(lib))
            self.assertEqual(code, 1)
            self.assertIn("the same volume as books/X/Saga/Saga Vol. 1 - One (pages).pdf", out)

    def test_video_titles_are_written(self):
        # A release's global TITLE tag in an MKV, a QuickTime subtitle track
        # that a remux would drop, and AVI's INFO title.
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            clip = ["-f", "lavfi", "-i", "testsrc=size=64x48:rate=5", "-f", "lavfi", "-i", "sine=f=440", "-t", "1",
                    "-c:v", "mpeg4", "-shortest"]
            srt = lib / "s.srt"
            srt.write_text("1\n00:00:00,000 --> 00:00:01,000\nhi\n")
            rels = {e: f"movies/Heat (1995) {{tmdb-949}}/Heat (1995) {{tmdb-949}}.{e}" for e in ("mkv", "m4v", "avi")}
            for e, rel in rels.items():
                (lib / rel).parent.mkdir(parents=True, exist_ok=True)
            ffmpeg(*clip, "-c:a", "aac", str(lib / rels["mkv"]))
            tags = lib / "tags.xml"
            tags.write_text("<Tags><Tag><Targets><TargetTypeValue>50</TargetTypeValue></Targets>"
                            "<Simple><Name>TITLE</Name><String>Heat.1995.x264-GRP</String></Simple></Tag></Tags>")
            subprocess.run(["mkvpropedit", "-q", str(lib / rels["mkv"]), "--tags", f"global:{tags}"], check=True)
            ffmpeg(*clip[:8], "-i", str(srt), "-map", "0", "-map", "1", "-map", "2", "-c:v", "mpeg4", "-c:a", "aac",
                   "-c:s", "mov_text", "-t", "1", "-metadata", "title=Heat.1995.GRP", str(lib / rels["m4v"]))
            ffmpeg(*clip, "-c:a", "mp3", "-metadata", "title=Heat.1995.DVDRip", str(lib / rels["avi"]))
            for e, rel in rels.items():
                streams = len(ms.ffprobe(lib / rel)["streams"])
                self.assertNotEqual(ms.current_meta(lib / rel).get("title"), "Heat (1995)", e)
                self.assertEqual(ms.tag_file(lib, rel), ["title=Heat (1995)"], e)
                self.assertEqual(ms.current_meta(lib / rel).get("title"), "Heat (1995)", e)
                self.assertEqual(len(ms.ffprobe(lib / rel)["streams"]), streams, e)
                self.assertEqual(ms.tag_file(lib, rel), [], e)

    def test_lint_fix_says_what_it_could_not_write(self):
        # MPEG-PS has no title tag we write: --fix says so, and fails.
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            mpg = lib / "movies/Heat (1995)/Heat (1995).mpg"
            mpg.parent.mkdir(parents=True)
            ffmpeg("-f", "lavfi", "-i", "testsrc=size=64x48:rate=25", "-t", "1", "-c:v", "mpeg2video", str(mpg))
            code, out = run_cli("lint", "--fix", "--library", str(lib))
            self.assertEqual(code, 1, out)
            self.assertIn("FAILED movies/Heat (1995)/Heat (1995).mpg: title not written", out)

    def test_lint_and_tag_take_library_paths(self):
        # Relative to the current directory, else to the library (`ssh desk`
        # starts in ~). A path that is neither is an error, never "ok".
        with tempfile.TemporaryDirectory() as d:
            lib, home = Path(d) / "media", Path(d) / "home"
            (lib / "rpg/Game").mkdir(parents=True)
            home.mkdir()
            make_pdf(lib / "rpg/Game/Game (v2).pdf", title="x")
            make_pdf(lib / "rpg/Game/Other - Rules.pdf", title="x")
            cwd = os.getcwd()
            os.chdir(home)
            try:
                code, out = run_cli("lint", "rpg", "--library", str(lib))
                self.assertEqual(code, 1, out)
                self.assertIn("LAYOUT rpg/Game/Game (v2).pdf", out)
                code, out = run_cli("lint", "rgp", "--library", str(lib))
                self.assertEqual(code, 1, out)
                self.assertIn("no such directory: rgp", out)
                code, out = run_cli("tag", "rpg/Game/Other - Rules.pdf", "--library", str(lib))
                self.assertEqual(code, 0, out)
                self.assertEqual(ms.pdf_meta(lib / "rpg/Game/Other - Rules.pdf")["title"], "Other - Rules")
                code, out = run_cli("tag", "rpg/Game/Nothing.pdf", "--library", str(lib))
                self.assertEqual(code, 1, out)
                self.assertIn("no such file: rpg/Game/Nothing.pdf", out)
                (home / "notes.pdf").write_bytes(b"")
                code, out = run_cli("tag", "notes.pdf", "--library", str(lib))
                self.assertEqual(code, 1, out)
                self.assertIn("not in the library: notes.pdf", out)
            finally:
                os.chdir(cwd)

    def test_best_copy_is_kept(self):
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d)
            st = lib / "staging" / "b"
            for sub in ("a", "b", "c"):
                (st / sub).mkdir(parents=True)
            small = ["-f", "lavfi", "-i", "testsrc=size=64x48:rate=5", "-f", "lavfi", "-i", "sine=f=440", "-t", "1",
                     "-c:v", "mpeg4", "-c:a", "aac", "-shortest"]
            big = [x.replace("64x48", "1280x720") for x in small]  # 480 vs 720: classes, not pixels
            ffmpeg(*small, "-metadata:s:a:0", "language=ger", str(st / "a" / "Heat.1995.BluRay.mkv"))
            ffmpeg(*big, "-metadata:s:a:0", "language=ger", str(st / "b" / "Heat.1995.WEB.mkv"))
            ffmpeg(*[x.replace("f=440", "f=660") for x in big], "-metadata:s:a:0", "language=ger",
                   str(st / "c" / "Heat.1995.HDTV.mkv"))
            (st / "c" / "Heat.1995.WEB.copy.mkv").write_bytes((st / "b" / "Heat.1995.WEB.mkv").read_bytes())
            (st / "a" / "Heat.1995.BluRay.en.srt").write_text("1\n00:00:00,000 --> 00:00:01,000\nhi\n")
            ffmpeg(*big, "-metadata:s:a:0", "language=eng", str(st / "c" / "Aguirre.The.Wrath.of.God.1972.BluRay.mkv"))
            ffmpeg(*small, "-metadata:s:a:0", "language=ger", str(st / "a" / "Aguirre.The.Wrath.of.God.1972.WEB.mkv"))
            run_cli("scan", str(st), "--hash", "--library", str(lib))
            wd = fake_wikidata({"Q1": ("Heat", "P4947", "949", 1995, None),
                                "Q2": ("Aguirre, the Wrath of God", "P4947", "14281", 1972, "L1")})
            ns = type("A", (), {"staging": str(st), "library": str(lib), "force": False, "lookup": False})
            with redirect_stdout(io.StringIO()):
                ms.draft(ns, lookup=ms.Wikidata(wd))
            rows = {l.split("\t")[0]: l.split("\t")[1:] for l in Path(str(st) + ".tsv").read_text().splitlines()[1:]}
            # Same resolution, another source: a matter of taste -> trash. Lower resolution -> discard.
            self.assertEqual(rows["b/Heat.1995.WEB.mkv"][0], "movies/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv")
            self.assertEqual(rows["c/Heat.1995.HDTV.mkv"][0], "trash")
            self.assertEqual(rows["c/Heat.1995.WEB.copy.mkv"][:3:2], ["discard", "identical to b/Heat.1995.WEB.mkv"])
            self.assertEqual(rows["a/Heat.1995.BluRay.mkv"][0], "discard")
            # The dropped copy's subtitle runs as long as the kept copy: it goes with it.
            self.assertEqual(rows["a/Heat.1995.BluRay.en.srt"][0], "movies/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.en.srt")
            # Original-language audio beats resolution; the title is Wikidata's.
            self.assertEqual(rows["a/Aguirre.The.Wrath.of.God.1972.WEB.mkv"][0],
                             "movies/Aguirre, the Wrath of God (1972) {tmdb-14281}/Aguirre, the Wrath of God (1972) {tmdb-14281}.mkv")
            self.assertEqual(rows["c/Aguirre.The.Wrath.of.God.1972.BluRay.mkv"][0], "discard")

            # apply: one filed, the trash moved aside, the discards deleted and logged.
            code, out = run_cli("apply", str(st), "--library", str(lib))
            self.assertEqual(code, 0, out)
            self.assertTrue((lib / "staging/trash/b/c/Heat.1995.HDTV.mkv").exists())
            self.assertFalse((st / "a" / "Heat.1995.BluRay.mkv").exists())
            log = [json.loads(l) for l in Path(str(st) + ".applied.jsonl").read_text().splitlines()]
            self.assertEqual({e["new"] for e in log if e["old"] == "a/Heat.1995.BluRay.mkv"}, {"discard"})
            self.assertTrue(all(len(e["sha256"]) == 64 for e in log))
            self.assertEqual(ms.current_meta(lib / "movies/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv")["title"],
                             "Heat (1995)")
            code, out = run_cli("lint", "--library", str(lib))
            self.assertEqual(code, 0, out)

            # A later batch with another copy of a filed film: set aside, not filed twice.
            st2 = lib / "staging" / "c"
            st2.mkdir()
            ffmpeg(*big, str(st2 / "Heat (1995) 2160p.mkv"))
            run_cli("scan", str(st2), "--hash", "--library", str(lib))
            ns.staging = str(st2)
            with redirect_stdout(io.StringIO()):
                ms.draft(ns, lookup=ms.Wikidata(wd))
            row = Path(str(st2) + ".tsv").read_text().splitlines()[1].split("\t")
            self.assertEqual(row[1], "trash")
            self.assertIn("the library already has this", row[3])

    def test_copies_in_one_folder_keep_their_own_subtitles(self):
        sub = lambda p: {"path": p, "size": 1, "kind": "subtitle", "ext": "srt", "guess": ms.guess(Path(p).name)}
        with tempfile.TemporaryDirectory() as d:
            rows = draft_rows(d, [
                # One name, two containers: the subtitle is the kept copy's.
                video_rec("a/Heat.1995.mkv"), video_rec("a/Heat.1995.mp4", video="h264 640x360"), sub("a/Heat.1995.en.srt"),
                # A longer name: the subtitle is its, not the shorter one's.
                video_rec("b/Alien.1979.mkv", video="h264 640x360"), video_rec("b/Alien.1979.remastered.mkv"),
                sub("b/Alien.1979.remastered.en.srt"),
                # ...so the kept copy has none of its own, and takes the dropped one's.
                video_rec("c/Aliens.1986.mkv", video="h264 1920x1080"), video_rec("c/Aliens.1986.remastered.mkv"),
                sub("c/Aliens.1986.remastered.en.srt")])
        self.assertEqual(rows["a/Heat.1995.mp4"][0], "discard")
        self.assertEqual(rows["a/Heat.1995.en.srt"][0], "movies/Heat (1995)/Heat (1995).en.srt")
        self.assertEqual(rows["b/Alien.1979.mkv"][0], "discard")
        self.assertEqual(rows["b/Alien.1979.remastered.en.srt"][0], "movies/Alien (1979)/Alien (1979) - Remastered.en.srt")
        self.assertEqual(rows["c/Aliens.1986.remastered.mkv"][0], "discard")
        self.assertEqual(rows["c/Aliens.1986.remastered.en.srt"][:3:2],
                         ["movies/Aliens (1986)/Aliens (1986).en.srt", "subtitle of a dropped copy of the same length; check: timing"])

    def test_untagged_audio_is_not_the_wrong_language(self):
        # mkvmerge, ffmpeg and many web files leave the audio's language unset.
        wd = ms.Wikidata(fake_wikidata({"Q1": ("Heat", "P4947", "949", 1995, "L2")}))  # English
        with tempfile.TemporaryDirectory() as d:
            rows = draft_rows(d, [video_rec("Heat.1995.2160p.BluRay.mkv", video="hevc 3840x1600", audio=["und"]),
                                  video_rec("Heat.1995.DVDRip.mkv", video="mpeg2video 720x576", audio=["eng"])], lookup=wd)
        self.assertEqual(rows["Heat.1995.2160p.BluRay.mkv"][0], "movies/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv")
        # The one copy known to be in English may yet be wanted: the kept one may be a dub.
        self.assertEqual(rows["Heat.1995.DVDRip.mkv"][0], "trash")
        self.assertIn("the kept copy's audio language is untagged", rows["Heat.1995.DVDRip.mkv"][2])

    def test_shows_of_one_name_from_two_countries_are_not_copies(self):
        with tempfile.TemporaryDirectory() as d:
            rows = draft_rows(d, [video_rec("The.Office.US.S01E01.720p.WEB.mkv"),
                                  video_rec("The.Office.US.2005.S01E02.720p.WEB.mkv"),
                                  video_rec("The.Office.UK.S01E01.576p.DVDRip.mkv", video="mpeg2video 720x576"),
                                  video_rec("The.Office.UK.S01E02.576p.DVDRip.mkv", video="mpeg2video 720x576")])
        self.assertEqual(rows["The.Office.US.S01E01.720p.WEB.mkv"][0],
                         "tv/The Office (2005)/Season 01/The Office (2005) - S01E01.mkv")
        # The UK show's year is not the US show's: left for review, neither discarded nor filed under it.
        for p in ("The.Office.UK.S01E01.576p.DVDRip.mkv", "The.Office.UK.S01E02.576p.DVDRip.mkv"):
            self.assertEqual(rows[p][0], "", rows[p])
            self.assertIn("show year unknown", rows[p][2])

    def test_review_offers_delete_or_trash(self):
        with tempfile.TemporaryDirectory() as d:
            st = Path(d) / "b"
            st.mkdir()
            (Path(d) / "b.tsv").write_text("old\tnew\tconfidence\tnote\nx.mkv\ttrash\tmedium\tother copy of y.mkv\n"
                                           "z.pdf\tdiscard\thigh\talready filed as rpg/G/Z.pdf\n")
            code, out = run_cli("review", "export", str(st))
            items = json.loads((Path(d) / "b.review.json").read_text())["items"]
            self.assertEqual([i["key"] for i in items], ["x.mkv"])  # identical content needs no one
            self.assertEqual([o["value"] for o in items[0]["options"]], ["trash", "discard"])
            (Path(d) / "a.json").write_text(json.dumps({"batch": "b", "item": items[0]["id"], "choice": "option",
                                                        "value": "discard"}))
            run_cli("review", "import", str(st), "--answers", str(Path(d) / "a.json"))
            self.assertIn("x.mkv\tdiscard\treviewed", (Path(d) / "b.tsv").read_text())


class Kavita(unittest.TestCase):
    """Once a command changes books/ or rpg/, Kavita is asked to scan the
    library that holds the change, rather than wait for its folder watcher."""

    def setUp(self):
        d = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.lib = d / "media"
        self.key = d / "api-key"
        self.key.write_text("sekrit\n")
        self.calls, self.down, self.batches = [], None, 0
        self.enterContext(mock.patch.object(ms, "KAVITA_KEY", str(self.key)))
        self.enterContext(mock.patch.object(ms, "kavita_api", self.api))

    def api(self, method, path, token=None, **query):
        if self.down:
            raise self.down
        self.calls.append((method, path, token, query))
        if path == "/api/Plugin/authenticate":
            return {"token": "jwt", "username": "someone"}
        if path == "/api/Library/libraries":
            return [{"id": 1, "name": "RPG", "folders": [str(self.lib / "rpg")]},
                    {"id": 2, "name": "Book", "folders": [f"{self.lib}/books/"]}]
        return None

    def scans(self):
        return [(path, token, query) for _, path, token, query in self.calls if path.startswith("/api/Library/scan")]

    def apply(self, files):
        """File `files` ({library path: maker}) through a batch of their own; apply's output."""
        self.batches += 1
        st = self.lib / "staging" / f"b{self.batches}"
        st.mkdir(parents=True)
        for n, (new, make) in enumerate(files.items()):
            make(st / f"{n}{Path(new).suffix}")
        run_cli("scan", str(st), "--library", str(self.lib))
        Path(str(st) + ".tsv").write_text("old\tnew\n" + "".join(
            f"{n}{Path(new).suffix}\t{new}\n" for n, new in enumerate(files)))
        code, out = run_cli("apply", str(st), "--library", str(self.lib))
        self.assertEqual(code, 0, out)
        return out

    def test_apply_asks_for_a_scan_of_the_library_it_filed_into(self):
        out = self.apply({"rpg/Game/Game - Rules.pdf": make_pdf})
        self.assertEqual(self.calls[0][1:], ("/api/Plugin/authenticate", None,
                                             {"apiKey": "sekrit", "pluginName": "media-stage"}))
        self.assertEqual(self.scans(), [("/api/Library/scan", "jwt", {"libraryId": 1})])
        self.assertIn("Kavita: asked to rescan RPG", out)
        # Books and RPGs at once: one scan of all. Kavita puts a scan asked
        # for while another runs off by three hours.
        self.calls.clear()
        out = self.apply({"rpg/Game/Game - Map.pdf": make_pdf,
                          "books/Someone/Some Book/Some Book.pdf": make_pdf})
        self.assertEqual(self.scans(), [("/api/Library/scan-all", "jwt", {})])
        self.assertIn("Kavita: asked to rescan RPG, Book", out)

    def test_what_kavita_does_not_read_asks_for_nothing(self):
        out = self.apply({"rpg/Game/extras/Handout.pdf": make_pdf})
        self.assertEqual(self.calls, [])
        self.assertNotIn("Kavita", out)
        with redirect_stdout(io.StringIO()) as out:
            ms.kavita_rescan(self.lib, ["movies/Heat (1995)/Heat (1995).mkv", "music/A/B/01 C.mp3"])
        self.assertEqual((self.calls, out.getvalue()), ([], ""))
        # A library Kavita doesn't have.
        with redirect_stdout(io.StringIO()) as out:
            ms.kavita_rescan(Path(self.key.parent) / "elsewhere", ["rpg/Game/Game - Rules.pdf"])
        self.assertEqual(self.scans(), [])
        self.assertIn("none of its libraries holds", out.getvalue())

    def test_tag_lint_fix_and_restage_ask_too(self):
        pdf = self.lib / "rpg/Game/Game - Rules.pdf"
        pdf.parent.mkdir(parents=True)
        make_pdf(pdf, title="x")
        code, out = run_cli("lint", "--library", str(self.lib))
        self.assertEqual((code, self.calls), (1, []))  # only looks
        code, out = run_cli("lint", "--fix", "--library", str(self.lib))
        self.assertEqual(code, 0, out)
        self.assertEqual(self.scans(), [("/api/Library/scan", "jwt", {"libraryId": 1})])
        self.calls.clear()
        code, out = run_cli("tag", str(pdf), "--library", str(self.lib))
        self.assertEqual((code, self.calls), (0, []))  # nothing to write, nothing changed
        code, out = run_cli("restage", str(self.lib / "staging" / "again"), "rpg/Game", "--library", str(self.lib))
        self.assertEqual(code, 0, out)
        self.assertEqual(self.scans(), [("/api/Library/scan", "jwt", {"libraryId": 1})])

    def test_no_key_or_no_kavita_is_a_note(self):
        self.down = OSError("refused apiKey=sekrit")
        out = self.apply({"rpg/Game/Game - Rules.pdf": make_pdf})
        self.assertTrue((self.lib / "rpg/Game/Game - Rules.pdf").exists())
        self.assertIn("Kavita: no rescan (refused apiKey=…); its folder watcher finds the change", out)
        self.assertNotIn("sekrit", out)
        self.key.unlink()
        out = self.apply({"rpg/Game/Game - Map.pdf": make_pdf})
        self.assertIn(f"Kavita: no API key in {self.key}, so no rescan", out)
        # A key that is there but won't read (someone outside the media group) says why.
        self.key.mkdir()
        out = self.apply({"rpg/Game/Game - Deck.pdf": make_pdf})
        self.assertIn("Kavita: no rescan ([Errno 21] Is a directory", out)
        self.assertNotIn("no API key", out)


if __name__ == "__main__":
    unittest.main()
