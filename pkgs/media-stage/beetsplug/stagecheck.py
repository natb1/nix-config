"""stagecheck: the evidence behind `beet stage-review` and `beet stage-audit`.

No beets imports, so the build's tests cover it (test_media_stage.py). Every
check here answers one question about a file, from the file itself rather
than from what beets or MusicBrainz made of it:

- fingerprint / similarity: is this the same recording as that one?
  Chromaprint's raw fingerprint, compared by bit error rate at the best of a
  few alignments. Copies of one recording score >= 0.9 (re-encodes, other
  rips); different recordings, even of the same piece, score <= 0.6.
- number_clash: do two titles name different numbered works or movements
  ("Prelude No. 3" / "Prelude No. 5", "BWV 998" / "BWV 999", "II." / "III.")?
  Translations and spellings differ harmlessly; numbers don't.
- name_conflict: does a file's name say something else than its own tags?
- length_off: is a file a different length than the release slot it fills?
"""

import array
import base64
import difflib
import json
import os
import re
import shutil
import subprocess

SAME_RECORDING = 0.8

# "Artist - Album - 04 Title.mp3", "Artist - Album (2000) - 04 - Title.mp3"
NAME = re.compile(r"^(?P<artist>.+?) - (?P<album>.+) - (?P<track>\d{1,3})(?: - |\.? )(?P<title>.+)\.[^.]+$")
# "04 Title.mp3", "1-04 - Title.mp3", "04. Title.mp3"
SHORT_NAME = re.compile(r"^(?:\d{1,2}-)?(?P<track>\d{1,3})(?:\s*[-.]\s*|\s+)(?P<title>.+)\.[^.]+$")


def from_name(filename):
    """What a file's name says: track and title, and artist and album when
    the name carries them. {} when it says nothing parseable."""
    m = NAME.match(filename) or SHORT_NAME.match(filename)
    return {k: v.strip() for k, v in m.groupdict().items()} if m else {}


def track_no(value):
    m = re.match(r"\s*(\d+)", str(value or ""))
    return int(m.group(1)) if m else None


# -- same recording

def fingerprint(path, seconds=120):
    """Chromaprint's raw fingerprint of the first `seconds`, or None when
    fpcalc is missing or can't read the file."""
    fpcalc = shutil.which("fpcalc")
    if not fpcalc:
        return None
    r = subprocess.run([fpcalc, "-raw", "-json", "-length", str(seconds), os.fsdecode(path)],
                       capture_output=True, text=True)
    if r.returncode:
        return None
    return [x & 0xFFFFFFFF for x in json.loads(r.stdout)["fingerprint"]]


def pack(fp):
    return base64.b64encode(array.array("I", fp).tobytes()).decode()


def unpack(s):
    a = array.array("I")
    a.frombytes(base64.b64decode(s))
    return list(a)


def similarity(a, b, shift=12, min_overlap=50):
    """1 - bit error rate at the best alignment within +-`shift` frames
    (about +-1.5 s): 1.0 identical, ~0.5 unrelated."""
    best = 0.0
    for off in range(-shift, shift + 1):
        lo, hi = max(0, -off), min(len(a), len(b) - off)
        n = hi - lo
        if n < min_overlap:
            continue
        err = sum((a[i] ^ b[i + off]).bit_count() for i in range(lo, hi))
        best = max(best, 1 - err / (32 * n))
    return best


# -- titles

_ROMAN = r"(?:X{0,3})(?:IX|IV|V?I{0,3})"
_NUMBERED = [
    ("No.", re.compile(r"\b(?:no|nr|n\.?[º°o])\.?\s*(\d+)", re.I)),
    ("Op.", re.compile(r"\bop(?:us)?\.?\s*(\d+)", re.I)),
    ("BWV", re.compile(r"\bbwv\s*(\d+)", re.I)),
    ("K.", re.compile(r"\bkv?\.\s*(\d+)", re.I)),
    ("HWV", re.compile(r"\bhwv\s*(\d+)", re.I)),
    ("Hob.", re.compile(r"\bhob\.?\s*([IVXL]+:\s*\d+)", re.I)),
    ("RV", re.compile(r"\brv\s*(\d+)", re.I)),
    ("WoO", re.compile(r"\bwoo\s*(\d+)", re.I)),
    ("D.", re.compile(r"\bD\.\s*(\d+)")),
    ("L.", re.compile(r"\bL\.\s*(\d+)")),
    # A movement: "III. Allegro", "II - Andante", "Sonatina: I. Allegretto"
    ("movement", re.compile(rf"(?:^|[:,;–—-]\s*|\s)({_ROMAN})(?:\.|\s+[-–—:])\s+\S")),
]


def numbers(title):
    out = {}
    for kind, pat in _NUMBERED:
        found = {re.sub(r"\s+", "", m.upper()) for m in pat.findall(title or "") if m}
        if found:
            out[kind] = found
    return out


def number_clash(a, b):
    """'No. 3 ≠ No. 5' when two titles name different numbers of one kind,
    else ''. Only kinds both titles name count: a translation that drops
    'Op. 36' is no clash."""
    na, nb = numbers(a), numbers(b)
    for kind in na.keys() & nb.keys():
        if na[kind] != nb[kind]:
            fmt = (lambda s: " ".join(sorted(s))) if kind == "movement" else \
                  (lambda s, k=kind: " ".join(f"{k} {n}" for n in sorted(s)))
            return f"{fmt(na[kind])} ≠ {fmt(nb[kind])}"
    return ""


def _norm(s):
    return re.sub(r"[\W_]+", " ", (s or "").casefold()).strip()


def title_similarity(a, b):
    a, b = _norm(a), _norm(b)
    if not a or not b:
        return 1.0
    if a in b or b in a:
        return 1.0
    return difflib.SequenceMatcher(None, a, b).ratio()


def name_conflict(filename, tags):
    """How a file's name disagrees with its own tags ('' when it doesn't):
    another track number, or another title. A file named for one track and
    tagged as another is wrong in one of the two, and beets believes the tags."""
    name = from_name(filename)
    if not name:
        return ""
    bits = []
    nt, tt = track_no(name.get("track")), track_no(tags.get("track"))
    if nt and tt and nt != tt:
        bits.append(f"track {nt} in the name, {tt} in the tags")
    title = tags.get("title", "")
    clash = number_clash(name.get("title", ""), title)
    if clash:
        bits.append(f"{clash} (name / tags)")
    elif title and title_similarity(name.get("title", ""), title) < 0.4:
        bits.append(f"titled “{name['title']}” in the name, “{title}” in the tags")
    return "; ".join(bits)


# -- lengths

def length_off(real, slot):
    """Seconds a file is off its release slot, when that is more than a
    rip's or a pressing's drift (7 s, or 4% of long tracks); else 0."""
    if not real or not slot:
        return 0
    d = real - slot
    return d if abs(d) > max(7.0, 0.04 * slot) else 0


def mmss(s):
    s = int(round(s or 0))
    return f"{s // 60}:{s % 60:02d}"
