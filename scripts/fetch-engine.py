#!/usr/bin/env python3
"""Fetch hash-pinned sources and build the audited local FFmpeg/ffprobe pair.

Default: fetch/build both tools, collect notices and matching source archive.
--prepare: only download, verify and safely extract pinned inputs.
--check: offline verification of built tools and their matching source archive.
No system installation, PATH changes or remote installation scripts.
Legacy third-party binaries are opt-in via fetch-legacy-engine.py, never used here.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--prepare', action='store_true')
    mode.add_argument('--check', action='store_true')
    parser.add_argument('--jobs', type=int, choices=(1,2), default=2)
    args = parser.parse_args()
    env = os.environ.copy()
    env['DEVELOPER_DIR'] = '/Library/Developer/CommandLineTools'
    scripts = ROOT / 'scripts'
    work = ROOT / '.tools' / 'source-build'
    records = ROOT / 'ThirdParty' / 'EngineSource'
    if args.check:
        commands = [[sys.executable, str(scripts / 'verify-helpers.py'),
                     '--manifest', str(records / 'engine-manifest.json'),
                     '--ffmpeg', str(work / 'prefix/bin/ffmpeg'),
                     '--ffprobe', str(work / 'prefix/bin/ffprobe'),
                     '--source-archive', str(work / 'MediaForge-engine-source-9.0.tar.gz'),
                     '--source-record', str(records / 'source-archive.json')]]
    else:
        commands = [[sys.executable, str(scripts / 'build-engine.py'), '--jobs', str(args.jobs)] + (['--prepare'] if args.prepare else [])]
        if not args.prepare:
            commands += [[sys.executable, str(scripts / 'check-source-engine.py')],
                         [sys.executable, str(scripts / 'package-engine-source.py')]]
    for command in commands:
        subprocess.run(command, cwd=ROOT, env=env, check=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'Engine fetch/build/check failed: {error}')
