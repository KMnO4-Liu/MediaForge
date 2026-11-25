#!/usr/bin/env python3
"""Small real encode/probe/decode checks for the source-built engine pair."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / '.tools' / 'source-build'
FFMPEG = WORK / 'prefix' / 'bin' / 'ffmpeg'
FFPROBE = WORK / 'prefix' / 'bin' / 'ffprobe'
OUT = WORK / 'smoke'


def run(argv):
    result = subprocess.run([str(a) for a in argv], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError('Command failed: ' + str(argv) + '\n' + result.stderr)
    return result.stdout


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    video = [FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=128x72:rate=10:duration=0.4', '-an', '-threads', '2']
    audio = [FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=0.4', '-vn', '-threads', '2']
    tests = [
        ('h264', 'h264', 'mp4', video, ['-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p']),
        ('hevc', 'hevc', 'mp4', video, ['-c:v','libx265','-preset','ultrafast','-x265-params','pools=1:frame-threads=1:log-level=error','-pix_fmt','yuv420p']),
        ('vp9', 'vp9', 'webm', video, ['-c:v','libvpx-vp9','-deadline','realtime','-cpu-used','8','-pix_fmt','yuv420p']),
        ('av1', 'av1', 'mkv', video, ['-c:v','libaom-av1','-cpu-used','8','-row-mt','1','-pix_fmt','yuv420p']),
        ('prores', 'prores', 'mov', video, ['-c:v','prores_ks','-pix_fmt','yuv422p10le']),
        ('png', 'png', 'png', video, ['-c:v','png','-frames:v','1','-update','1']),
        ('apng', 'apng', 'apng', video, ['-c:v','apng','-plays','0','-f','apng']),
        ('webp-animation', 'webp_anim', 'webp', video, ['-c:v','libwebp_anim','-loop','0']),
        ('gif', 'gif', 'gif', video, ['-c:v','gif']),
        ('mp3', 'mp3', 'mp3', audio, ['-c:a','libmp3lame']),
        ('opus', 'opus', 'opus', audio, ['-c:a','libopus']),
        ('vorbis', 'vorbis', 'ogg', audio, ['-c:a','libvorbis']),
        ('aac', 'aac', 'm4a', audio, ['-c:a','aac']),
        ('flac', 'flac', 'flac', audio, ['-c:a','flac']),
        ('pcm', 'pcm_s16le', 'wav', audio, ['-c:a','pcm_s16le']),
    ]
    report = []
    for name, expected, ext, base, args in tests:
        path = OUT / (name + '.' + ext)
        command = base + args + [path]
        run(command)
        probe = json.loads(run([FFPROBE, '-v','error','-count_frames','-show_streams','-show_format','-of','json',path]))
        stream = probe['streams'][0]
        if stream['codec_name'] != expected:
            raise ValueError(name + ': unexpected codec ' + stream['codec_name'])
        if name in ('apng','webp-animation','gif') and int(stream.get('nb_read_frames','0')) != 4:
            raise ValueError(name + ': animation frames not preserved: ' + str(stream))
        run([FFMPEG,'-hide_banner','-v','error','-i',path,'-f','null','-'])
        report.append({'name':name,'codec':expected,'bytes':path.stat().st_size,'frames':stream.get('nb_read_frames'),
                       'command':[str(a) for a in command],'result':'encode + JSON probe + decode passed'})
        print('PASS ' + name, flush=True)
    target = ROOT / 'ThirdParty' / 'EngineSource' / 'SMOKE-TESTS.json'
    target.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Passed {len(report)} real-format checks; report: {target}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
