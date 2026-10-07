#!/usr/bin/env python3
"""Estimate a date for each undated photo of a Flickr export, as XMP sidecars.

    nix shell nixpkgs#exiftool -c python3 scripts/flickr-date-estimate.py /srv/media/flickr

The export (/srv/media/flickr/Flickr <years>[ part N]/) came without
Flickr's account data, so about a quarter of its files have no date of their
own, and Immich would put them all on the day they were unpacked. This
writes `<file>.xmp` beside each one, with an estimated DateTimeOriginal and
the tag "Flickr/date estimated", which Immich reads from an external library
without the original being touched. Every estimate is also listed in
<root>/dates-estimated.tsv.

The estimate: Flickr's photo id (in every filename) rises with upload order,
and the export was uploaded close to the order it was taken in. Of the
dated photos, 92% share their year with the next one by id. So an undated
photo gets the date in between its dated neighbours by id, across all
folders, weighted by how close its id is to each.

A folder's years bound its estimates only when the folder's own dated photos
agree with its name (95% or more): "Flickr 2015 part N" holds mostly
2010–2014 photos (the 2015 bulk upload) and bounds nothing.

Files that already have a sidecar are left alone, so a rerun only adds; pass
--force to rewrite them.
"""

import argparse
import bisect
import csv
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

TAG = "Flickr/date estimated"
MEDIA = {".jpg", ".jpeg", ".png", ".gif", ".mov", ".mp4"}
AGREE = 0.95

XMP = """<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:exif="http://ns.adobe.com/exif/1.0/"
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
    xmlns:digiKam="http://www.digikam.org/ns/1.0/"
    exif:DateTimeOriginal="{date}"
    xmp:CreateDate="{date}"
    photoshop:DateCreated="{date}">
   <lr:hierarchicalSubject><rdf:Bag><rdf:li>{tag}</rdf:li></rdf:Bag></lr:hierarchicalSubject>
   <digiKam:TagsList><rdf:Seq><rdf:li>{tag}</rdf:li></rdf:Seq></digiKam:TagsList>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
"""


def photo_id(name):
    """Flickr's id: `<id>_<secret>_o.jpg`, or `<title>_<id>[_o].jpg`."""
    m = re.match(r"(\d{9,12})_[0-9a-f]{10}(?:_o)?\.\w+$", name) or re.search(
        r"_(\d{9,12})(?:_o)?\.\w+$", name
    )
    return int(m[1]) if m else None


def own_date(meta):
    for key in ("DateTimeOriginal", "CreateDate"):
        v = str(meta.get(key) or "")
        if v and not v.startswith("0000"):
            try:
                return datetime.strptime(v[:19], "%Y:%m:%d %H:%M:%S")
            except ValueError:
                pass
    return None


def folder_years(folder):
    m = re.search(r"Flickr (\d{4})(?:-(\d{4}))?", folder.name)
    return (int(m[1]), int(m[2] or m[1])) if m else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root", type=Path)
    ap.add_argument("--force", action="store_true", help="rewrite existing sidecars")
    ap.add_argument("--dry-run", action="store_true", help="list estimates, write nothing")
    args = ap.parse_args()

    files = sorted(
        p for p in args.root.glob("Flickr */*") if p.is_file() and p.suffix.lower() in MEDIA
    )
    out = subprocess.run(
        ["exiftool", "-q", "-json", "-api", "QuickTimeUTC=0",
         "-DateTimeOriginal", "-CreateDate", "-@", "-"],
        input="\n".join(map(str, files)), capture_output=True, text=True, check=True,
    ).stdout
    meta = {Path(m["SourceFile"]): m for m in json.loads(out)}

    anchors, undated = [], []
    for p in files:
        i = photo_id(p.name)
        if i is None:
            sys.exit(f"no Flickr id in {p}")
        d = own_date(meta.get(p, {}))
        (anchors if d else undated).append((i, d, p))
    anchors.sort(key=lambda a: a[0])
    ids = [a[0] for a in anchors]

    # Which folders' names their dated photos bear out.
    bounds = {}
    for folder in {p.parent for p in files}:
        years = folder_years(folder)
        dated = [d for _, d, p in anchors if p.parent == folder]
        if years and dated and sum(years[0] <= d.year <= years[1] for d in dated) >= AGREE * len(dated):
            bounds[folder] = years

    rows, written = [], 0
    for i, _, p in sorted(undated, key=lambda u: u[0]):
        k = bisect.bisect(ids, i)
        lo = anchors[k - 1] if k else None
        hi = anchors[k] if k < len(anchors) else None
        if lo and hi:
            f = (i - lo[0]) / (hi[0] - lo[0])
            est = datetime.fromtimestamp(lo[1].timestamp() + f * (hi[1].timestamp() - lo[1].timestamp()))
        else:
            est = (lo or hi)[1]
        how = "between neighbours"
        b = bounds.get(p.parent)
        if b and not b[0] <= est.year <= b[1]:
            est = datetime(b[0], 1, 1) if est.year < b[0] else datetime(b[1], 12, 31, 12)
            how = "neighbours outside folder years; clamped"
        est = est.replace(microsecond=0)
        rows.append([p.relative_to(args.root), est.isoformat(sep=" "), how,
                     lo[1].isoformat(sep=" ") if lo else "", lo[2].name if lo else "",
                     hi[1].isoformat(sep=" ") if hi else "", hi[2].name if hi else ""])
        sidecar = p.with_name(p.name + ".xmp")
        if args.dry_run or (sidecar.exists() and not args.force):
            continue
        sidecar.write_text(XMP.format(date=est.isoformat(), tag=TAG), encoding="utf-8")
        written += 1

    report = sys.stdout if args.dry_run else open(args.root / "dates-estimated.tsv", "w", newline="")
    w = csv.writer(report, delimiter="\t", lineterminator="\n")
    w.writerow(["file", "estimate", "how", "before", "before file", "after", "after file"])
    w.writerows(rows)
    print(f"{len(files)} files, {len(undated)} undated, {written} sidecars written; "
          f"folders bounding their estimates: {', '.join(sorted(f.name for f in bounds))}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
