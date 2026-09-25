"""Tests for media-stage. Run by the package's checkPhase (`nix build .#media-stage`,
`nix flake check`), where ffmpeg, poppler, exiftool and mkvtoolnix are on PATH.

The pipeline test builds a small batch of real files — generated video, audio,
a hand-written PDF and EPUB — and takes it through scan, draft, check, apply
and lint, the way a real batch goes."""

import io
import json
import os
import subprocess
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path

import media_stage as ms


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
                "fields": {"new": "books/Someone/Unsure.pdf"}, "note": "it is a novel"}}))
            (ans / "b.json").write_text(json.dumps({
                "batch": "print", "item": by["blank.pdf"]["id"], "choice": "skip"}))
            (ans / "other.json").write_text(json.dumps({
                "batch": "audio", "item": by["blank.pdf"]["id"], "choice": "option", "value": "path:x"}))
            code, out = run_cli("review", "import", str(st), "--answers", str(ans), "--library", d)
            self.assertEqual(code, 0, out)
            table = (lib / "staging" / "print.tsv").read_text()
            self.assertIn("unsure.pdf\tbooks/Someone/Unsure.pdf\treviewed\tcheck: guessed from text · reviewer: it is a novel", table)
            self.assertIn("blank.pdf\tskip\treviewed", table)
            self.assertEqual(run_cli("review", "export", str(st), "--library", d)[0], 0)
            self.assertEqual(json.loads((lib / "staging" / "print.review.json").read_text())["items"], [])
            code, out = run_cli("check", str(st), "--library", d)
            self.assertEqual(code, 0, out)


class Layout(unittest.TestCase):
    good = [
        "music/Julian Bream/Nocturnal (1993)/1-01 Britten - Nocturnal.mp3",
        "books/Albert Camus/The Stranger.epub",
        "rpg/Blades in the Dark/Blades in the Dark (v8.2).pdf",
        "movies/Heat (1995)/Heat (1995).mkv",
        "movies/Heat (1995)/Heat (1995) - Director's Cut.mkv",
        "movies/Heat (1995)/Heat (1995).en.srt",
        "movies/Heat (1995)/Heat (1995).en.forced.srt",
        "movies/Heat (1995)/extras/Making of.mp4",
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
        ("tv/The Wire (2002)/Season 1/The Wire (2002) - S01E01.mkv", "tv/ layout"),
        ("tv/The Wire (2002)/Season 02/The Wire (2002) - S01E01.mkv", "tv/ layout"),
        ("rpg/Game/What?.pdf", "SMB"),
        ("books/Author /Title.epub", "trailing space"),
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

    def test_standard(self):
        self.assertEqual(ms.standard("books/Plato/Republic (tr. Reeve).epub"), {"title": "Republic", "author": "Plato"})
        self.assertEqual(ms.standard("movies/Heat (1995)/Heat (1995).mkv"), {"title": "Heat (1995)"})
        self.assertEqual(ms.standard("tv/The Wire (2002)/Season 01/The Wire (2002) - S01E01 - The Target.mkv"),
                         {"title": "The Wire - S01E01 - The Target"})
        self.assertEqual(ms.standard("youtube/Chan/2024-05-01 - Hello [abc123]/".rstrip("/") + ".mp4"),
                         {"title": "Hello", "author": "Chan"})

    def test_ep_code(self):
        self.assertEqual(ms.ep_code(1, 2), "S01E02")
        self.assertEqual(ms.ep_code(1, [2, 3]), "S01E02-E03")


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

            code, out = run_cli("draft", str(st))
            self.assertEqual(code, 0, out)
            table = Path(str(st) + ".tsv")
            rows = {l.split("\t")[0]: l.rstrip("\n").split("\t") for l in table.read_text().splitlines()[1:]}
            self.assertEqual(rows["The.Matrix.1999.1080p.BluRay.x264.mkv"][1], "movies/The Matrix (1999)/The Matrix (1999).mkv")
            self.assertEqual(rows["The.Matrix.1999.1080p.BluRay.x264.en.srt"][1], "movies/The Matrix (1999)/The Matrix (1999).en.srt")
            self.assertTrue(rows["sub/Breaking.Bad.2008.S01E02.720p.mp4"][1].startswith(
                "tv/Breaking Bad (2008)/Season 01/Breaking Bad (2008) - S01E02"), rows["sub/Breaking.Bad.2008.S01E02.720p.mp4"])
            self.assertEqual(rows["clip.mp4"][1], "youtube/Guitar Chan/2024-05-01 - How to tune a guitar [abc123XYZ_-].mp4")
            self.assertEqual(rows["clip.info.json"][1], "youtube/Guitar Chan/2024-05-01 - How to tune a guitar [abc123XYZ_-].info.json")
            self.assertEqual(rows["stranger.epub"][1], "books/Albert Camus/The Stranger.epub")
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
                "untitled.epub": "books/Nobody/Untitled.epub",
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
            self.assertEqual(meta(lib / "rpg/Test Game/Test Game - Rules (pages).pdf")["title"], "Test Game - Rules")
            self.assertEqual(ms.epub_meta(lib / "books/Nobody/Untitled.epub")["title"], "Untitled")
            self.assertEqual(ms.epub_meta(lib / "books/Nobody/Untitled.epub")["creators"], ["Nobody"])
            # A publisher's title is kept, not replaced by the file name's.
            self.assertEqual(ms.epub_meta(lib / "books/Albert Camus/The Stranger.epub")["title"], "The Stranger: A Novel")
            with zipfile.ZipFile(lib / "books/Nobody/Untitled.epub") as z:
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


if __name__ == "__main__":
    unittest.main()
