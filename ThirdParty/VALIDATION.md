# Engine integration validation — 2026-11-24

Scope: the scripts/tooling work did not modify Core, UI, Package.swift, the main README or VERIFICATION files, and did not run SwiftPM. Final application build/end-to-end UI validation is performed separately by the integrating agent.

Environment: Apple Silicon arm64, macOS 15.8. During this session the machine's selected developer directory changed to an Xcode installation with an unaccepted license, causing Apple's python3/otool/lipo shims to return exit 69. Subsequent developer-tool checks used only the process-local `DEVELOPER_DIR=/Library/Developer/CommandLineTools`. No system selection, license acceptance, PATH, package manager or machine configuration was changed by this work.

## Passed

- `bash -n scripts/build-app.sh`.
- Python syntax compilation for `fetch-engine.py` and `verify-helpers.py` (without writing pycache).
- Offline `fetch-engine.py --check`: both exact binary hashes, arm64 Mach-O headers and system-only dylib dependencies.
- Fresh `fetch-engine.py --only ffmpeg --output .tools/repro-check`: fetched the pinned imageio wheel URL, checked the archive SHA before extraction, checked the exact member and binary hash, produced an FFmpeg byte-identical to the original (`cmp` passed). Original FFmpeg hash remains `591260c945d0eef150e3bf82b0ef988bd36a9cecc18ff05d6679617159f0a95e`.
- FFprobe archive and binary hash verification against the pinned records and published distributor binary checksum; native arm64 `-version` and `-L` worked.
- `otool -L`: both binaries reference only `/System/Library/` and `/usr/lib/`; no absolute Homebrew/local third-party dylibs or unresolved runpaths.
- `vtool -show-build`: FFmpeg min macOS 12.0; FFprobe min macOS 13.0.
- Real FFmpeg encoding of a 128×72, 10 fps, 0.4-second test source using `libx264`, followed by FFprobe JSON parsing: codec `h264`, width 128, height 72, positive duration.
- Encoder presence: `libx264`, `libx265`, `libvpx-vp9`, `libwebp_anim`, `aac`, `libmp3lame`, `libopus`, `flac`, `pcm_s16le` (this verifies the listing, not quality/performance for every codec).
- Copied each helper into the workspace validation directory, ad-hoc signed it with `codesign --force --sign -`, and verified it with `codesign --verify --strict`. Re-signed FFprobe successfully probed the sample; re-signed FFmpeg successfully decoded it to null. Original helpers were untouched.
- Negative checks rejected: wrong executable SHA-256; wrong CPU architecture despite a matching artificial test hash; fetch destination outside the workspace; FFprobe passed as FFmpeg; an unreviewed packaging input. The last check stopped before any SwiftPM invocation.

## Packaging implementation, pending integrated app build

The reviewed build script stages a clean 0.2.0 app, verifies both source and staged helper binaries, puts helpers in `Contents/Helpers`, copies all ThirdParty notices/source records to `Contents/Resources/ThirdParty`, emits a helper audit, signs each helper first, signs the app second and verifies the final signature. Custom executable paths still need matching audited manifest hashes. It does not silently fetch or include an unknown executable. The script is syntactically verified; this agent did not execute the full app build while SwiftPM was reserved by the parent.

## Limitations

The licenses/corresponding-source gaps in [NOTICE.md](<NOTICE.md>) remain unresolved. These functional checks do not certify distribution compliance or prove source reproducibility. FFprobe 9.1 is a different version from the deliberately preserved FFmpeg 9.0. Tests covered the current macOS 15.8 machine, not every claimed macOS release. The app uses ad-hoc signing by default and is not notarized by these scripts.
