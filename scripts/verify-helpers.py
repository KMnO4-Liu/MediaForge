#!/usr/bin/env python3
"""Check reviewed helper hashes, architecture and system-only dylib dependencies."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifest", required=True, type=Path)
    p.add_argument("--ffmpeg", required=True, type=Path)
    p.add_argument("--ffprobe", type=Path)
    p.add_argument("--app-binary", type=Path)
    p.add_argument("--report", type=Path)
    p.add_argument("--source-archive", type=Path)
    p.add_argument("--source-record", type=Path)
    args = p.parse_args()
    manifest = json.loads(args.manifest.read_text())
    expected_arch = manifest["architecture"]
    app_archs = set(subprocess.check_output(["/usr/bin/lipo", "-archs", str(args.app_binary)], text=True).split()) if args.app_binary else {expected_arch}
    report = {"manifest": str(args.manifest.resolve()), "distribution_status": manifest.get("distribution_status", "not reviewed"), "tools": {}}
    for name, path in (("ffmpeg", args.ffmpeg), ("ffprobe", args.ffprobe)):
        if path is None:
            continue
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        pin = manifest["tools"][name]
        if sha != pin["binary_sha256"]:
            raise ValueError(f"{name}: unreviewed SHA256 {sha}; supply an audited manifest and corresponding notices, not an arbitrary executable")
        archs = set(subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split())
        if expected_arch not in archs or not app_archs.issubset(archs):
            raise ValueError(f"{name}: helper architectures {archs} do not cover app {app_archs}")
        output = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
        deps = [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:]]
        forbidden = [d for d in deps if not d.startswith(("/usr/lib/", "/System/Library/"))]
        if forbidden:
            raise ValueError(f"{name}: third-party/unresolved dylib dependencies: {forbidden}")
        report["tools"][name] = {"input": str(path.resolve()), "version": pin["version"], "input_sha256": sha, "architectures": sorted(archs), "dependencies": deps}
    if bool(args.source_archive) != bool(args.source_record):
        raise ValueError("Both source archive and its audited record are required")
    if args.source_archive:
        source_record = json.loads(args.source_record.read_text())
        if args.source_archive.name != source_record["filename"] or hashlib.sha256(args.source_archive.read_bytes()).hexdigest() != source_record["sha256"]:
            raise ValueError("Matching source archive filename/SHA256 check failed")
        for name, info in report["tools"].items():
            if source_record["binary_sha256"][name] != info["input_sha256"]:
                raise ValueError(f"Source archive does not correspond to {name}")
        report["corresponding_source"] = source_record
    result = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.write_text(result)
    print(result, end="")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"Helper audit failed: {error}")
