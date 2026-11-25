#!/usr/bin/env python3
"""Collect exact engine sources, recipes, license notices and build evidence.

Run after build-engine.py succeeds. Does not change the app or legacy binaries.
Creates .tools/source-build/MediaForge-engine-source-9.0.tar.gz and a separate
EngineSource engine manifest for explicit adoption by the app packager.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.tools' / 'source-build'
RECORDS = ROOT / 'ThirdParty' / 'EngineSource'
MANIFEST = RECORDS / 'source-manifest.json'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    pins = json.loads(MANIFEST.read_text())
    tools = {}
    for name in ('ffmpeg', 'ffprobe'):
        path = WORK / 'prefix' / 'bin' / name
        arch = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).strip()
        if arch != 'arm64':
            raise ValueError(f'Unexpected architecture: {arch}')
        linkage = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
        deps = [line.strip().split(' (', 1)[0] for line in linkage.splitlines()[1:]]
        if any(not dep.startswith(('/System/Library/', '/usr/lib/')) for dep in deps):
            raise ValueError('Non-system dylib in ' + name)
        version = subprocess.check_output([str(path), '-version'], text=True, stderr=subprocess.STDOUT)
        if not version.startswith(name + ' version 9.0'):
            raise ValueError('Unexpected FFmpeg version')
        if '--enable-gpl' not in version or '--enable-version3' not in version or '--disable-autodetect' not in version:
            raise ValueError('Unexpected build configuration')
        if '--enable-libvmaf' in version or '--enable-libass' in version or '--enable-nonfree' in version:
            raise ValueError('Unexpected external/nonfree configuration')
        (RECORDS / (name + '-version.txt')).write_text(version)
        (RECORDS / (name + '-linkage.txt')).write_text(linkage)
        license_output = subprocess.check_output([str(path), '-L'], text=True, stderr=subprocess.STDOUT)
        (RECORDS / (name + '-license-output.txt')).write_text(license_output)
        tools[name] = {'version': '9.0', 'binary_sha256': sha(path), 'provenance': 'Built locally from the pinned complete source inputs and build-engine.py recipe',
                       'source_manifest_sha256': sha(MANIFEST), 'dependencies': deps}
    engine_manifest = {'schema': 1, 'platform': 'Darwin', 'architecture': 'arm64',
                       'distribution_status': 'Source-built GPL-3.0-or-later engine; distribute with the matching engine-source archive and notices. Not a legal or patent clearance certification.',
                       'tools': tools}
    (RECORDS / 'engine-manifest.json').write_text(json.dumps(engine_manifest, indent=2) + '\n')
    ffmpeg = WORK / 'prefix' / 'bin' / 'ffmpeg'
    for kind in ('encoders', 'decoders'):
        output = subprocess.check_output([str(ffmpeg), '-hide_banner', '-' + kind], text=True, stderr=subprocess.STDOUT)
        (RECORDS / ('ffmpeg-' + kind + '.txt')).write_text(output)
    license_index = []
    for item in pins['inputs']:
        archive = WORK / 'downloads' / item['archive']
        if sha(archive) != item['sha256']:
            raise ValueError('Source archive no longer matches pin: ' + str(archive))
        source_root = WORK / 'sources' / item['name'] / item['source_root']
        # Preserve all standalone copyright/license/patent notices, including
        # in-tree third-party notices (some apply only to disabled test tools).
        for path in sorted(source_root.rglob('*')):
            upper = path.name.upper()
            if not path.is_file() or not any(upper.startswith(k) for k in ('COPYING','LICENSE','PATENTS','COPYRIGHT','NOTICE')):
                continue
            relative = path.relative_to(source_root)
            target = RECORDS / 'licenses' / item['name'] / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            license_index.append({'component': item['name'], 'file': str(target.relative_to(RECORDS)), 'sha256': sha(target)})
    (RECORDS / 'license-index.json').write_text(json.dumps(license_index, indent=2) + '\n')
    shutil.copyfile(WORK / 'build-environment.json', RECORDS / 'build-environment.json')
    commands = {}
    for item in pins['inputs']:
        stamp = WORK / 'build' / item['name'] / '.mediaforge-built.json'
        if item['role'] != 'build-tool-binary':
            if not stamp.is_file():
                raise ValueError('Missing completed build record: ' + item['name'])
            commands[item['name']] = json.loads(stamp.read_text())
            for config_name in ('CMakeCache.txt','config.h','config.mak','config_components.h','ffbuild/config.mak'):
                config = WORK / 'build' / item['name'] / config_name
                if config.is_file():
                    target = RECORDS / 'build-configurations' / item['name'] / config_name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(config, target)
    (RECORDS / 'build-commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    archive = WORK / 'MediaForge-engine-source-9.0.tar.gz'
    base = 'MediaForge-engine-source-9.0'
    # The source archive excludes the CMake binary (an ordinary build tool,
    # obtainable at its pinned URL), but includes pkgconf tool source and all
    # exact source tarballs for all statically linked non-system libraries.
    with tarfile.open(archive, 'w:gz') as tar:
        for item in pins['inputs']:
            if item['role'] != 'build-tool-binary':
                tar.add(WORK / 'downloads' / item['archive'], arcname=base + '/.tools/source-build/downloads/' + item['archive'])
        for name in ('build-engine.py','fetch-engine.py','package-engine-source.py','check-source-engine.py','verify-helpers.py'):
            tar.add(ROOT / 'scripts' / name, arcname=base + '/scripts/' + name)
        tar.add(RECORDS, arcname=base + '/ThirdParty/EngineSource', filter=lambda info: None if info.name.endswith(('/source-archive.json','/SOURCE-DELIVERY.md')) else info)
        tar.add(WORK / 'logs', arcname=base + '/.tools/source-build/logs')
    checksum = sha(archive)
    (WORK / (archive.name + '.sha256')).write_text(checksum + '  ' + archive.name + '\n')
    source_record = {'filename': archive.name, 'sha256': checksum, 'size': archive.stat().st_size,
                     'source_manifest_sha256': sha(MANIFEST), 'recipe_sha256': sha(ROOT / 'scripts' / 'build-engine.py'),
                     'binary_sha256': {name: item['binary_sha256'] for name, item in tools.items()}}
    (RECORDS / 'source-archive.json').write_text(json.dumps(source_record, indent=2) + '\n')
    (RECORDS / 'SOURCE-DELIVERY.md').write_text('# Matching engine corresponding-source delivery\n\n'
        + 'This app uses the source-built FFmpeg/ffprobe 9.0 pair. The matching source archive supplied alongside the app is:\n\n'
        + '`' + archive.name + '`\n\nSHA-256: `' + checksum + '`\n\n'
        + 'Distributors must keep this matching archive accessible with the app and preserve the license notices. It contains all pinned engine/library source tarballs, build recipes and build records. See README.md and the GPL texts for obligations; this record is not a blanket legal or patent clearance.\n')
    print(json.dumps({'source_archive': str(archive), 'sha256': checksum, 'size': archive.stat().st_size,
                      'license_files': len(license_index), 'engine_manifest': str(RECORDS / 'engine-manifest.json')}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit(str(error))
