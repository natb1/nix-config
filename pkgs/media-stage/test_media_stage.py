"""Tests for media-stage. Run by the package's checkPhase (`nix build .#media-stage`,
`nix flake check`), where ffmpeg, poppler, exiftool and mkvtoolnix are on PATH.

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

import media_stage as ms

sys.path.insert(0, str(Path(__file__).parent / "beetsplug"))
import stagecheck as sc  # noqa: E402


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
        ("rpg/Game/Title..pdf", None),  # legal: the dot is not trailing on the component
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
        self.assertEqual(ms.norm_title("Aguirre, the Wrath of God"), ms.norm_title("Aguirre The Wrath Of God"))
        self.assertEqual(ms.norm_title("Big Sick, The"), ms.norm_title("The Big Sick"))

    def test_ep_code(self):
        self.assertEqual(ms.ep_code(1, 2), "S01E02")
        self.assertEqual(ms.ep_code(1, [2, 3]), "S01E02-E03")


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

    def test_hidden_folder_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            st = Path(d) / "staging" / "print"
            (st / ".originals").mkdir(parents=True)
            code, out = run_cli("close", str(st), "--library", d)
            self.assertNotEqual(code, 0)
            self.assertIn(".originals/", out)


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

    def test_file_changed_since_scan_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            lib, st = self.batch(d)
            with open(st / "Heat.1995.mkv", "ab") as f:
                f.write(b"\0" * 10)  # still being copied
            code, out = run_cli("check", str(st), "--library", str(lib))
            self.assertEqual(code, 1)
            self.assertIn("changed since scan", out)

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


if __name__ == "__main__":
    unittest.main()
