#!/usr/bin/env python3
"""Build a pinned, minimal, statically linked FFmpeg+ffprobe entirely in workspace.

Requires existing Apple Command Line Tools and Python 3; never installs system
packages, accepts Xcode licenses, changes PATH or runs remote install scripts.
All downloaded archives are hash checked before safe extraction. Build/install
commands act only on reviewed upstream source with a workspace --prefix.
Use --prepare to fetch/check/extract only; default builds, resuming completed libs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.tools' / 'source-build'
MANIFEST = ROOT / 'ThirdParty' / 'EngineSource' / 'source-manifest.json'
PREFIX = WORK / 'prefix'
TOOLS = WORK / 'tools'
LOGS = WORK / 'logs'
BUILD = WORK / 'build'
SOURCES = WORK / 'sources'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inside(path, root):
    resolved = path.resolve()
    return resolved == root.resolve() or root.resolve() in resolved.parents


def get_source(item):
    archive = WORK / 'downloads' / item['archive']
    if archive.is_symlink():
        raise ValueError(f'Refusing symlink archive {archive}')
    if not archive.exists():
        archive.parent.mkdir(parents=True, exist_ok=True)
        print(f"FETCH {item['name']} {item['url']}", flush=True)
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'MediaForge-source-build/0.2.0'})
        with urllib.request.urlopen(request, timeout=180) as response:
            if not response.url.startswith('https://'):
                raise ValueError('Non-HTTPS redirect')
            data = response.read(200 * 1024 * 1024 + 1)
        if len(data) > 200 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError(f"Download SHA256/size mismatch: {item['name']}")
        with archive.open('xb') as handle:
            handle.write(data)
    if digest(archive) != item['sha256']:
        raise ValueError(f"Archive SHA256 mismatch before extraction: {item['name']}")
    destination = SOURCES / item['name']
    marker = destination / '.mediaforge-extracted-sha256'
    if marker.exists():
        if marker.read_text().strip() != item['sha256']:
            raise ValueError(f'Source pin changed: use a separate clean workspace: {destination}')
        return destination / item['source_root']
    if destination.exists() and any(destination.iterdir()):
        raise ValueError(f'Refusing to overwrite partially extracted source: {destination}')
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            if not inside(destination / member.name, destination):
                raise ValueError(f'Unsafe archive member {member.name}')
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError(f'Special archive member rejected: {member.name}')
            if member.issym() and not inside((destination / member.name).parent / member.linkname, destination):
                raise ValueError(f'Unsafe symbolic link {member.name}')
            if member.islnk() and not inside(destination / member.linkname, destination):
                raise ValueError(f'Unsafe hard link {member.name}')
        tar.extractall(destination)
    marker.write_text(item['sha256'] + '\n')
    print(f"PREPARED {item['name']} {item['version']}", flush=True)
    return destination / item['source_root']


def run(name, argv, cwd, env):
    LOGS.mkdir(parents=True, exist_ok=True)
    with (LOGS / (name + '.log')).open('a') as log:
        log.write('\n$ ' + shlex.join([str(a) for a in argv]) + '\n')
        log.flush()
        result = subprocess.run([str(a) for a in argv], cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'{name}: command exited {result.returncode}; inspect {LOGS / (name + ".log")}')


def build_one(name, source, pin, commands, env):
    work = BUILD / name
    work.mkdir(parents=True, exist_ok=True)
    stamp = work / '.mediaforge-built.json'
    recipe = {'source_sha256': pin['sha256'], 'commands': [[str(a) for a in c] for c in commands],
              'environment': {k: env.get(k) for k in ('CC','CXX','CFLAGS','CXXFLAGS','LDFLAGS','CPPFLAGS','MACOSX_DEPLOYMENT_TARGET','PKG_CONFIG_LIBDIR','SDKROOT')}}
    if stamp.exists() and json.loads(stamp.read_text()) == recipe:
        print('REUSE ' + name, flush=True)
        return
    print('BUILD ' + name, flush=True)
    for command in commands:
        run(name, command, work, env)
    stamp.write_text(json.dumps(recipe, indent=2) + '\n')
    print('DONE ' + name, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--through', help='stop after building this dependency')
    args = parser.parse_args()
    if args.jobs < 1 or args.jobs > 2:
        parser.error('Use one or two build jobs to keep this shared machine responsive')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('This audited recipe targets native macOS arm64 only')
    if not inside(WORK, ROOT) or WORK.is_symlink():
        raise ValueError('Invalid source build workspace')
    manifest = json.loads(MANIFEST.read_text())
    pins = {i['name']: i for i in manifest['inputs']}
    source = {name: get_source(pin) for name, pin in pins.items()}
    if args.prepare:
        return
    env = os.environ.copy()
    # Per-process toolchain selection only. No global xcode-select or PATH edits.
    env['DEVELOPER_DIR'] = '/Library/Developer/CommandLineTools'
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], env=env, text=True).strip()
    cc = '/Library/Developer/CommandLineTools/usr/bin/clang'
    cxx = '/Library/Developer/CommandLineTools/usr/bin/clang++'
    common_flags = f'-O2 -fPIC -mmacosx-version-min=14.0 -isysroot {sdk}'
    env.update(CC=cc, CXX=cxx, CFLAGS=common_flags, CXXFLAGS=common_flags,
               CPPFLAGS=f'-I{PREFIX}/include', LDFLAGS=f'-L{PREFIX}/lib -mmacosx-version-min=14.0 -isysroot {sdk}',
               SDKROOT=sdk, MACOSX_DEPLOYMENT_TARGET='14.0',
               PKG_CONFIG=str(TOOLS / 'bin' / 'pkgconf'), PKG_CONFIG_PATH='',
               PKG_CONFIG_LIBDIR=str(PREFIX / 'lib' / 'pkgconfig'))
    for directory in (PREFIX, TOOLS, BUILD, LOGS):
        directory.mkdir(parents=True, exist_ok=True)
    cmake = source['cmake'] / 'CMake.app' / 'Contents' / 'bin' / 'cmake'
    if not cmake.is_file():
        raise ValueError('Pinned CMake executable missing')
    cmake_arches = subprocess.check_output(['/usr/bin/lipo', '-archs', str(cmake)], env=env, text=True).split()
    if 'arm64' not in cmake_arches:
        raise ValueError('Pinned CMake does not contain native arm64 code')
    # CMake is the sole downloaded executable; its archive hash is also matched
    # to Kitware's published checksum. All other new executables are source-built.
    tool_info = {
        'clang': subprocess.check_output([cc, '--version'], env=env, text=True),
        'cmake': subprocess.check_output([str(cmake), '--version'], env=env, text=True),
        'sdk': sdk, 'macos': platform.mac_ver()[0], 'architecture': platform.machine(),
        'jobs': args.jobs, 'source_manifest_sha256': digest(MANIFEST),
        'recipe_sha256': digest(Path(__file__)),
        'environment': {k: env[k] for k in ('DEVELOPER_DIR','CC','CXX','CFLAGS','CXXFLAGS','CPPFLAGS','LDFLAGS','PKG_CONFIG','PKG_CONFIG_LIBDIR','SDKROOT','MACOSX_DEPLOYMENT_TARGET')},
    }
    (WORK / 'build-environment.json').write_text(json.dumps(tool_info, indent=2) + '\n')
    make = ['/usr/bin/make', '-j' + str(args.jobs)]

    def autotools(name, flags, prefix=PREFIX):
        return [[source[name] / 'configure', '--prefix=' + str(prefix)] + flags, make, ['/usr/bin/make', 'install']]

    def cmake_commands(name, flags, subdir='.'):
        return [[cmake, '-S', source[name] / subdir, '-B', BUILD / name, '-G', 'Unix Makefiles',
                 '-DCMAKE_MAKE_PROGRAM=/usr/bin/make', '-DCMAKE_BUILD_TYPE=Release',
                 '-DCMAKE_INSTALL_PREFIX=' + str(PREFIX), '-DCMAKE_PREFIX_PATH=' + str(PREFIX),
                 '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
                 '-DCMAKE_OSX_SYSROOT=' + sdk, '-DBUILD_SHARED_LIBS=OFF',
                 '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DFETCHCONTENT_FULLY_DISCONNECTED=ON', '-DPKG_CONFIG_EXECUTABLE=' + env['PKG_CONFIG']] + flags,
                [cmake, '--build', BUILD / name, '--parallel', str(args.jobs)],
                [cmake, '--install', BUILD / name]]

    plans = [
        ('pkgconf', autotools('pkgconf', ['--disable-shared','--enable-static','--disable-dependency-tracking'], TOOLS)),
        ('x264', autotools('x264', ['--enable-static','--disable-cli','--disable-opencl','--disable-asm','--enable-pic'])),
        ('x265', cmake_commands('x265', ['-DENABLE_SHARED=OFF','-DENABLE_CLI=OFF','-DENABLE_ASSEMBLY=OFF','-DENABLE_LIBNUMA=OFF','-DENABLE_TESTS=OFF','-DHIGH_BIT_DEPTH=OFF'], 'source')),
        ('vpx', autotools('vpx', ['--target=arm64-darwin24-gcc','--disable-shared','--enable-static','--enable-pic','--disable-examples','--disable-tools','--disable-docs','--disable-unit-tests','--enable-vp9-highbitdepth'])),
        ('webp', cmake_commands('webp', ['-DWEBP_BUILD_ANIM_UTILS=OFF','-DWEBP_BUILD_CWEBP=OFF','-DWEBP_BUILD_DWEBP=OFF','-DWEBP_BUILD_GIF2WEBP=OFF','-DWEBP_BUILD_IMG2WEBP=OFF','-DWEBP_BUILD_VWEBP=OFF','-DWEBP_BUILD_WEBPINFO=OFF','-DWEBP_BUILD_WEBPMUX=OFF','-DWEBP_BUILD_EXTRAS=OFF','-DWEBP_BUILD_LIBWEBPMUX=ON','-DWEBP_BUILD_WEBP_JS=OFF','-DWEBP_BUILD_FUZZTEST=OFF','-DWEBP_LINK_STATIC=ON'])),
        ('ogg', autotools('ogg', ['--disable-shared','--enable-static','--disable-dependency-tracking'])),
        ('vorbis', cmake_commands('vorbis', ['-DBUILD_FRAMEWORK=OFF','-DINSTALL_CMAKE_PACKAGE_MODULE=ON'])),
        ('opus', cmake_commands('opus', ['-DOPUS_BUILD_PROGRAMS=OFF','-DOPUS_BUILD_TESTING=OFF','-DOPUS_INSTALL_PKG_CONFIG_MODULE=ON','-DOPUS_INSTALL_CMAKE_CONFIG_MODULE=ON'])),
        ('lame', autotools('lame', ['--disable-shared','--enable-static','--disable-frontend','--disable-dependency-tracking'])),
        ('aom', cmake_commands('aom', ['-DENABLE_TESTS=OFF','-DENABLE_EXAMPLES=OFF','-DENABLE_TOOLS=OFF','-DENABLE_DOCS=OFF','-DCONFIG_TFLITE=0','-DCONFIG_TUNE_VMAF=0','-DAOM_TARGET_CPU=arm64'])),
        ('ffmpeg', [[source['ffmpeg'] / 'configure', '--prefix=' + str(PREFIX), '--cc=' + cc, '--cxx=' + cxx,
                    '--arch=arm64','--target-os=darwin','--enable-static','--disable-shared','--disable-autodetect',
                    '--enable-gpl','--enable-version3','--disable-doc','--disable-debug','--disable-ffplay',
                    '--enable-ffmpeg','--enable-ffprobe','--enable-videotoolbox','--enable-audiotoolbox',
                    '--enable-libx264','--enable-libx265','--enable-libvpx','--enable-libwebp',
                    '--enable-libopus','--enable-libmp3lame','--enable-libvorbis','--enable-libaom',
                    '--enable-zlib','--enable-bzlib','--enable-iconv',
                    '--pkg-config=' + env['PKG_CONFIG'], '--pkg-config-flags=--static',
                    '--extra-cflags=' + common_flags + ' -I' + str(PREFIX / 'include'),
                    '--extra-ldflags=' + env['LDFLAGS'], '--extra-libs=-lc++ -liconv'], make, ['/usr/bin/make','install']]),
    ]
    if args.through and args.through not in dict(plans):
        parser.error('Unknown --through dependency')
    for name, commands in plans:
        build_one(name, source[name], pins[name], commands, env)
        if args.through == name:
            break
    print('SOURCE BUILD COMPLETE: ' + str(PREFIX / 'bin'), flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit(str(error))
