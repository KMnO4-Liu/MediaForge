# MediaForge source-built FFmpeg 9.0 engine

This directory records the locally source-built replacement for the earlier third-party precompiled engine. It is **not** a claim that the old imageio/OSXExperts executables have corresponding source. Those executables are preserved separately for regression tests and are not the default release inputs after this source-built engine is adopted.

## Exact inputs and source delivery

[source-manifest.json](<source-manifest.json>) pins each release URL, archive SHA-256, version/revision and archive root. The complete pristine tarballs are retained in the workspace and included in the separate delivery **`MediaForge-engine-source-9.0.tar.gz`**. That archive contains:

- The exact FFmpeg 9.0 release source and every non-system library source linked into these helpers: x264, x265, libvpx, libwebp, Opus, LAME, libogg, libvorbis and libaom (including their in-tree third-party sources and notices).
- pkgconf source used as a build tool.
- The complete local build and source-packaging recipes, fixed input manifest, generated build-command/environment records, configuration/version/linkage reports and standalone license/patent notices.
- Build logs, including recovered configuration attempts; final successful commands are identified by the generated build records.

No patches to upstream source were required. The same official FFmpeg 9.0 source revision builds **both** ffmpeg and ffprobe. x264 is pinned to commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`; libaom 3.12.1 is pinned to commit `10aece4157eb79315da205f39e19bf6ab3ee30d0`. The remaining source inputs use versioned upstream release URLs and SHA-256.

The CMake 3.31.8 macOS universal **build-tool binary** is not included in the source archive. Its fixed official Kitware URL and SHA-256 are in the manifest, and the recipe obtains it only when missing. Its checksum was checked against Kitware's published release checksum list. The CMake distribution's license notices are retained in the license collection. CMake, Python, the Apple compiler/SDK and operating-system libraries are ordinary build tools/system components, not additional statically incorporated codec libraries. The source archive does not redistribute Apple's proprietary SDK/toolchain.

## Rebuild

Unpack the source archive into a writable directory on an Apple Silicon Mac with macOS 14+ and Apple's Command Line Tools installed, then run from its top directory:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/python3 scripts/build-engine.py --jobs 2
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/python3 scripts/package-engine-source.py
```

The recipe never installs into system directories, accepts an Xcode license, invokes brew/pip, changes PATH, or executes a downloaded remote installer. It validates each archive **before** extraction and uses the source projects' local configure/CMake/make recipes with workspace prefixes. Downloads use HTTPS and exact hashes; hash pinning is integrity/repeatability evidence, not a publisher signature attestation. CMake FetchContent is disconnected and optional remote ML/test dependencies are disabled.

Outputs are `.tools/source-build/prefix/bin/ffmpeg` and `ffprobe`; the prior `.tools/ffmpeg` and `.tools/ffprobe` are untouched. `--prepare` downloads/checks/extracts without compiling. `--through NAME` stops after a selected dependency. Build markers allow interrupted builds to resume without recompiling completed dependencies. For an independent clean rebuild, unpack the source archive into a different directory. Reproducible here means fixed auditable inputs and instructions—not a guarantee of byte-identical output across SDK/compiler versions, host paths or signing steps.

The current recipe uses macOS deployment target 14.0, two parallel jobs and only static third-party libraries. x264/x265 external assembly paths are disabled; system VideoToolbox encoding remains available. x265 is an 8-bit build. Native FFmpeg handles ProRes, PNG/APNG, GIF, FLAC, AAC and PCM; the requested external codecs use only the libraries listed above. Network/system integration and additional native FFmpeg features retain their source-defined licenses. No libvmaf, libass, OpenSSL or `--enable-nonfree` components are enabled.

## Licenses and release obligations

The combined helpers are built with `--enable-gpl --enable-version3` and report **GPL version 3 or later**. x264/x265 are used under their GPL grants; other libraries retain their own included notices, including LGPL, BSD and patent terms. See the generated `licenses` tree and `license-index.json`. FFmpeg is based in part on the work of the Independent JPEG Group. MediaForge uses LAME; its project is https://lame.sourceforge.io/ (historical attribution URL https://www.mp3dev.org/).

Distribute the exact matching source archive alongside the app with equivalent accessible download availability, preserve the licenses/notices, and make any later engine modifications and their corresponding source available as required. Do not ship only the binary while withholding this archive. A public distributor must review GPL distribution requirements for its actual delivery method (including installation information where applicable), the app/helper relationship, compatible EULA terms, codec patents by jurisdiction, and signing/notarization. Providing actual source addresses the earlier specific missing-source problem; it is **not** a blanket legal or patent clearance certificate. No vague written source offer is substituted for the archive.

Ad-hoc signing changes executable bytes; the engine manifest identifies the original locally built inputs before app-bundle signing. Build recipes/configuration are unchanged by signing. Both helpers must be present in `Contents/Helpers`; the app does not rely on system-installed fallback tools.
