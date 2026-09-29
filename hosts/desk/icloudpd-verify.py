"""icloudpd-verify <instance>: prove every iCloud original is on desk, byte-exact.

The reference is Apple's own per-file checksum (CloudKit's `fileChecksum`),
which icloudpd fetches but never checks. Its format, confirmed against real
downloads on 2026-09-26:

    0x01 || SHA-1("com.apple.XattrObjectSalt\\0com.apple.DataObjectSalt\\0" || bytes)

It was computed on Apple's side, so this check does not trust desk's RAM:
a bit flipped before a file reached the disk makes its hash disagree. A
flip during the check can only produce a false alarm, never a false pass.

Matching is by content, not by name: every original and Live Photo video
icloudpd would download (its defaults, as the unit runs it) must have a
byte-identical file somewhere under /srv/media/icloud/<instance>/. Local
files iCloud no longer has are fine — the backup is add-only.

Assets added to iCloud after the unit's last run began (its ExecStartPre
stamps the time) are counted, not checked: icloudpd pages through the
library by offset, so one that arrives mid-run can land among the pages it
has already read, and is missed. The next run fetches it, and checks it.

Exit 0: everything verified. 1: something missing or corrupt. 2: cannot log
in without a 2FA code (run icloudpd-login <instance>).
"""

import base64
import datetime
import hashlib
import json
import os
import sys

from pyicloud_ipd.base import PyiCloudService
from pyicloud_ipd.utils import get_password_from_keyring
from pyicloud_ipd.version_size import AssetVersionSize, LivePhotoVersionSize

SALT = b"com.apple.XattrObjectSalt\x00com.apple.DataObjectSalt\x00"
# What the unit downloads: icloudpd's default --size and --live-photo-size.
WANTED = (AssetVersionSize.ORIGINAL, LivePhotoVersionSize.ORIGINAL)


def read_env(instance):
    path = os.path.expanduser(f"~/.config/icloudpd/{instance}.env")
    env = {}
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip("'\"")
    return env["APPLE_ID"], env["LIBRARY"]


def run_start(stamp):
    """When the unit's last run began, less a minute for the two clocks
    (desk's stamp, Apple's addedDate); None if it never ran."""
    try:
        mtime = os.stat(stamp).st_mtime
    except OSError:
        return None
    return datetime.datetime.fromtimestamp(mtime - 60, tz=datetime.timezone.utc)


def added_since(asset, cutoff):
    """Whether iCloud got the asset after cutoff. Unknown counts as before,
    so the asset is checked."""
    if cutoff is None:
        return False
    try:
        return asset.added_date > cutoff
    except (KeyError, TypeError, ValueError, OSError):
        return False


def file_digest(path):
    """Apple's checksum of the file as it is on disk, not in the page cache.

    fsync first, so any of icloudpd's writes still in flight are on disk;
    then drop the file's clean cached pages, so the read comes off the SSD.
    """
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        h = hashlib.sha1(SALT)
        while chunk := os.read(fd, 1 << 20):
            h.update(chunk)
        return b"\x01" + h.digest()
    finally:
        os.close(fd)


def local_index(root, cache_path):
    """digest -> path for every file under root.

    A file is hashed once; the result is cached by (size, mtime). That is
    enough: the risk this guards against is corruption on the way *to* disk,
    and after the first verification btrfs checksums and scrub take over.
    """
    try:
        with open(cache_path) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    fresh, index, hashed = {}, {}, 0
    for dirpath, _, names in os.walk(root):
        for name in names:
            if name.endswith(".part"):
                continue  # icloudpd's in-progress download
            path = os.path.join(dirpath, name)
            st = os.stat(path)
            key = [st.st_size, st.st_mtime_ns]
            hit = cache.get(path)
            if hit and hit[:2] == key:
                digest = bytes.fromhex(hit[2])
            else:
                digest = file_digest(path)
                hashed += 1
            fresh[path] = key + [digest.hex()]
            index[digest] = path
    tmp = cache_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(fresh, f)
    os.replace(tmp, cache_path)
    return index, hashed


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: icloudpd-verify <instance>")
    instance = sys.argv[1]
    apple_id, library = read_env(instance)
    state = os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "icloudpd"
    )
    root = f"/srv/media/icloud/{instance}"

    api = PyiCloudService(
        "com",
        apple_id,
        lambda: get_password_from_keyring(apple_id),
        cookie_directory=os.path.join(state, apple_id),
    )
    if api.requires_2fa or api.requires_2sa:
        print(f"{apple_id}: session needs a 2FA code; run icloudpd-login {instance}")
        sys.exit(2)
    photos = api.photos
    lib = photos.private_libraries.get(library) or photos.shared_libraries[library]

    index, hashed = local_index(root, os.path.join(state, f"verify-{instance}.json"))
    cutoff = run_start(os.path.join(state, f"started-{instance}"))

    assets = versions = newer = 0
    missing = []
    for asset in lib.all:
        if added_since(asset, cutoff):
            newer += 1
            continue
        assets += 1
        for size, version in asset.versions.items():
            if size not in WANTED:
                continue
            versions += 1
            expected = base64.b64decode(version.checksum)
            if expected[:1] != b"\x01" or len(expected) != 21:
                missing.append((asset, size, version, "unknown checksum format"))
            elif expected not in index:
                missing.append((asset, size, version, "no byte-exact copy on desk"))

    print(
        f"{instance}: {assets} assets, {versions} files in iCloud "
        f"({newer} more added since the run began, left for the next); "
        f"{len(index)} files on desk ({hashed} newly hashed); {len(missing)} missing"
    )
    for asset, size, version, why in missing:
        print(
            f"  MISSING {asset.filename} [{type(size).__name__}.{size.name}] "
            f"{version.size} bytes, created {asset.created:%Y-%m-%d}: {why}"
        )
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
