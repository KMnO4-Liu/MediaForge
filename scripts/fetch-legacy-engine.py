#!/usr/bin/env python3
"""Fetch ONLY the reviewed, hash-pinned macOS arm64 helpers (stdlib only).

No pip, brew, PATH changes, remote install scripts or archive-wide extraction.
Existing executables are never replaced. Inspect ThirdParty/NOTICE.md first.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import stat
import struct
import subprocess
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "ThirdParty" / "LegacyPrebuilt" / "engine-manifest.json"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def check_binary(data, pin):
    if digest(data) != pin["binary_sha256"]:
        raise ValueError("executable SHA256 mismatch; refusing unknown executable")
    # Thin 64-bit little-endian Mach-O, CPU_TYPE_ARM64. Do not execute to detect arch.
    if len(data) < 8 or struct.unpack("<II", data[:8]) != (0xFEEDFACF, 0x0100000C):
        raise ValueError("expected a native arm64 Mach-O executable")


def check_linkage(path):
    output = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith(("/System/Library/", "/usr/lib/")):
            raise ValueError(f"non-system dependency rejected: {dependency}")
    print(output, end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", choices=("ffmpeg", "ffprobe"))
    parser.add_argument("--check", action="store_true", help="offline hash/architecture/linkage verification only")
    parser.add_argument("--output", type=Path, default=ROOT / ".tools", help="must remain within this workspace")
    args = parser.parse_args()
    out = args.output.resolve()
    if out != ROOT and ROOT not in out.parents:
        parser.error("--output must be inside the MediaForge workspace")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("pins support macOS arm64 only; no silent architecture fallback")
    manifest = json.loads(MANIFEST.read_text())
    print("NOTICE: development integration, NOT cleared for public distribution. Legacy regression tools only; see ThirdParty/LegacyPrebuilt/NOTICE.md.")
    tools = manifest["tools"]
    for name in ([args.only] if args.only else tools):
        pin = tools[name]
        target = out / name
        if target.is_symlink():
            raise ValueError(f"refusing symlink target: {target}")
        if target.exists():
            check_binary(target.read_bytes(), pin)
            check_linkage(target)
            print(f"Verified existing {target}; left unchanged")
            continue
        if args.check:
            raise FileNotFoundError(target)
        archive_name = pin["url"].rsplit("/", 1)[1]
        cache = ROOT / ".tools" / "downloads" / archive_name
        if cache.is_symlink():
            raise ValueError(f"refusing symlink cache: {cache}")
        if cache.exists():
            data = cache.read_bytes()
        else:
            print(f"Downloading pinned source: {pin['url']}")
            request = urllib.request.Request(pin["url"], headers={"User-Agent": "MediaForge-engine-fetch/0.2.0"})
            with urllib.request.urlopen(request, timeout=120) as response:
                if not response.url.startswith("https://"):
                    raise ValueError("refusing non-HTTPS redirect")
                data = response.read(160 * 1024 * 1024 + 1)
            if len(data) > 160 * 1024 * 1024:
                raise ValueError("archive too large")
        if digest(data) != pin["archive_sha256"]:
            raise ValueError(f"archive SHA256 mismatch: {archive_name}; no extraction performed")
        # Select one exact allowlisted member; no extractall/path traversal or scripts.
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            matching = [i for i in archive.infolist() if i.filename == pin["member"]]
            if len(matching) != 1 or matching[0].file_size > 160 * 1024 * 1024:
                raise ValueError("missing/duplicate/oversized executable member")
            if stat.S_ISLNK(matching[0].external_attr >> 16):
                raise ValueError("archive executable must not be a symlink")
            binary = archive.read(matching[0])
        check_binary(binary, pin)
        out.mkdir(parents=True, exist_ok=True)
        # Exclusive create guarantees that an existing helper cannot be overwritten.
        with target.open("xb") as handle:
            handle.write(binary)
        target.chmod(0o755)
        check_linkage(target)
        cache.parent.mkdir(parents=True, exist_ok=True)
        if not cache.exists():
            with cache.open("xb") as handle:
                handle.write(data)
        print(f"Installed verified {name} {pin['version']}: {target}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        sys.exit(f"Engine verification failed: {error}")
