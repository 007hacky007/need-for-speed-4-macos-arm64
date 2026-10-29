# NFS IV Native Implementation Plan

> Use superpowers:executing-plans to implement this plan task by task in the current session.

**Goal:** Deliver the requested playable ARM64 port, then a single-command build from the user's own game copy.

**Architecture:** Reuse the sibling NFSV static recompilation tools and native host. Adapt image preparation and the game's Thrash/audio interfaces, compile original game functions locally, and package a Cocoa launcher and native renderer.

**Tech stack:** Python, Capstone, pefile, C, Objective-C, Cocoa, CoreAudio, Vulkan and Metal.

**Spec:** ../specs/2026-10-29-nfsiv-native-design.md and the user's follow-up build/distribution requirements.

## Global constraints

- Preserve supplied disc files, patch archives, existing saves and NFSV.
- No EA code, game assets, generated translations or patch binaries in version control.
- No Wine, Rosetta or runtime x86 emulation in the finished app.
- Original game behavior, working racing, sound/music and fullscreen remain required.
- Use only ASCII hyphens; no personal identifiers or external publication.
- Build accepts extracted folder, ISO, BIN/CUE and the supplied CloneCD image.
- Validate checksums after extraction and download required patches from original sources.
- Do not commit until identity requirements can be satisfied without using unauthorized personal data.

## Review focus

- Malformed image records and archive paths cannot write outside the preparation directory.
- Unsupported game versions must fail before translation with a useful explanation.
- Rebuilding cannot replace writable saves or mutate source data.
- Optional patches must correspond to real behavior and compatible game profiles.
- A clean source checkout must contain everything needed except user-owned assets and fetched dependencies.

### 1. Verified preparation and ARM64 startup

Files: tools/disc.py, tools/prepare.py, tools/lift.py, tools/genall.py, tools/compile.py, runtime/*, third_party/*, tests/test_prepare.py.

- [x] Test zero-VirtualSize PE sections, checksum rejection and module relocation.
- [x] Adapt NFSV native host and lifter with provenance notices.
- [x] Extract supplied DATA/SAVEDATA and the verified VEG 4.50-based executable locally.
- [x] Generate imports, relocations and function seeds for the game and EA sound module.
- [x] Translate, compile and run with bounded diagnostics; fix startup failures at their source.

### 2. Original game rendering, input and audio

Files: runtime/thrash.c, runtime/platform.c, runtime/com.c, runtime/sound.c, runtime/host.m, tools/control.py, tests/runtime checks.

- [x] Verify the NFS IV Thrash ABI against the supplied drivers and actual calls.
- [x] Validate menus, movie playback, a complete race and a second race.
- [x] Validate decoded sound effects, menu/race music and save/load.
- [x] Fix focus, fullscreen and resolution selection against real runtime behavior.
- [x] Exercise career, Hot Pursuit and split-screen; preserve evidence and limitations.

### 3. Vulkan and community patch integration

Files: runtime/vulkan.m, runtime/render.h, runtime/patches.c, launcher/main.m, README.md.

- [x] Integrate a native ARM64 Vulkan runtime and implement the Thrash renderer backend.
- [x] Check real frames, depth, fog, headlights, HUD and multiple resolutions.
- [x] Extract official InstallShield payloads and record exact 4.50 coverage.
- [x] Implement applicable SilentPatch and Vulkan game hooks with selectable behavior.
- [x] Inspect and integrate compatible Stock/Expansion assets as separate profiles.
- [x] Investigate IPLounge/native network compatibility without claiming unsupported Windows software works.

### 4. Launcher, one-command build and source-only distribution

Files: build.sh, tools/build_app.py, tools/downloads.py, tools/game_source.py, tools/package.py, launcher/main.m, README.md, tests/test_build_app.py.

- [x] Test folder, ISO and BIN/CUE inputs including spaces, invalid layouts and checksum failures.
- [x] Fetch pinned patch versions from original sources into an external cache; verify every use.
- [x] Build and locally sign out/NFSIV.app from the single entry script.
- [x] Persist launcher resolution/fullscreen/renderer/patch selections and isolate saves.
- [x] Verify an export of source-only files excludes all EA and generated content.
- [x] Write a short README with prerequisites, commands, accepted game versions, verified features and patch table.
- [x] Explain static translation and its numerical/performance limits at the bottom of the README.

### 5. Completion audit

- [x] Rebuild using the documented command from the supplied copy.
- [x] Verify ARM64 binaries and absence of runtime emulation dependencies.
- [x] Verify requested gameplay, graphics/audio and launcher settings against actual behavior.
- [x] Run relevant tests and audit source-only distribution.
- [x] Complete representative addon runtime checks and report unverified modes in README.md.
