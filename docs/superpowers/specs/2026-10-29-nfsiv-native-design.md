# NFS IV native Apple Silicon design

Status: historical design and initial inspection. The implementation now runs native ARM64
menus, racing, audio and Vulkan rendering. Current build usage, supported versions
and verified limitations are documented in README.md. Initial inspection statements
below describe the starting state, including tools that were installed later.

## Requested result

Make the supplied PC copy of Need for Speed High Stakes / Road Challenge
playable on Apple Silicon using the same static recompilation approach as
the sibling NFSV project. Include official updates, native Vulkan rendering,
community fixes, a macOS launcher with resolution selection, fullscreen,
sound effects and music. Offer community components as launcher selections
where their behavior can be independently enabled and verified.

## Inspected inputs

- NFS.img is a raw MODE1/2352 single-track ISO9660 image with 2,025 files.
  Its CUE and CCD describe one data track. NFS.sub contains subchannel data;
  it is retained with the original image and is not an audio track.
- The disc has loose DATA and SAVEDATA files. Preparation can read them
  without mounting the disc or running its Windows installer.
- Both official installers, 4.42 and 4.50, are present. 4.50 supersedes 4.42;
  the two are not independent feature toggles.
- The supplied VEG Modern Patch is v0.1.0. Its documentation identifies
  its executable as based on official 4.50. The executable is PE32 x86,
  base 0x400000, entry 0x55a480, with 52,530 relocation records.
  SHA-256: 17a0f96c3bcfb94fc72d31a429ef56e14ec028e4a6ed1f692cdd8efc0b762980.
- The executable's sections use zero VirtualSize fields. Image preparation
  and code discovery must account for raw section sizes rather than treating
  those sections as empty.
- SilentPatch Build 1, the Vulkan driver 2026.10.15.4, Stock Pack, Expansion
  Pack and IPLounge archives are present.
- The Vulkan archive contains Windows x86 DLLs, SPIR-V shaders, configuration
  and documentation. It contains no driver source. Its Windows installation
  labelled Native installation does not mean native macOS or ARM64.
- The Vulkan DLL imports 84 Vulkan functions plus Win32 APIs and exports 48
  entry points. NFSV's native Thrash adapter handles 41 entries. Additional
  exports and NFS IV-specific state handling need examination.
- EACSND.DLL supplies 19 audio entry points and imports DirectSound. It has
  1,064 relocation records and the same preferred image base as the game.
  Translate it at a separate guest address or replace its interface only
  after inspecting the calling conventions and actual audio behavior.
- 7-Zip extracts the official 4.50 installer's outer CAB, but cannot read
  its nested InstallShield data1.cab. A compatible InstallShield extractor
  is needed before claiming to apply its payload. No such extractor is
  currently installed.
- Stock Pack contains an executable installer; Expansion Pack likewise
  wraps NFS_HS_EP_Setup_V4.0_(1.78).exe. Listing the outer ZIP/RAR alone
  does not establish the content or compatibility of either pack.
- NFSV provides a working architecture for static x86-to-C translation,
  ARM64 compilation, guest memory, Win32 services, input, Metal and CoreAudio.
  This is reference code; NFSV files and builds remain untouched.
- There is no git repository in this directory. No publication or use of
  personal git identity is part of this work.

## Implementation choices

These are proposed implementation choices, inferred from the NFSV reference.

1. Compile the original game logic to ARM64, preserving its menus, physics,
   AI, race modes and save formats. Use Objective-C/C for the native host,
   Python for build tools and the existing lifter where suitable. The final
   game app must run without Wine, Rosetta or runtime x86 emulation.
2. Read and validate the supplied disc and patch archives without changing
   them. Store extracted assets, generated game-derived C and executable
   output in local build directories. Validate image bounds, archive paths
   and executable fingerprints before translation.
3. Inspect and extract official patch payloads. Use official 4.50 as the
   baseline, with VEG's documented 4.50-derived executable as the practical
   portable translation input. Record exactly which official payloads were
   applied and which are supplied by the VEG baseline. Retain 4.42 as an
   archival predecessor; do not claim to have run its installer if it was
   superseded or only inspected.
4. Adapt the game-facing Thrash graphics ABI and implement an ARM64 Vulkan
   backend with a macOS Vulkan implementation bundled locally. Evaluate
   available macOS Vulkan runtimes during implementation. Reuse NFSV's
   Metal backend for initial diagnostics and as an optional fallback.
   Merely copying the Windows Vulkan DLL does not satisfy Vulkan support.
5. Preserve the supplied Vulkan driver's documentation and configuration.
   Reuse compatible shader assets or reimplement equivalent native behavior
   where needed. Driver-specific widescreen, frame pacing and game-memory
   hooks require separate verification. Do not label the native renderer
   as a full port of Jericho's driver unless its behavior has been established.
6. Reuse native CoreAudio output, adapting the game's audio entry points and
   translating required EA decoder code. Exercise effects, menu music, race
   music and movie audio separately. A working output device alone is not
   proof of decoded game audio.
7. Build a Cocoa launcher and an app bundle. Persist resolution, fullscreen,
   renderer and available patch settings. Offer sound/music controls and
   opening the save/log directory. Use modest defaults, initially 1280x960
   or a supported display-fitting mode; preserve menu artwork aspect ratio.
8. Treat required portability fixes separately from optional community
   behavior. VEG baseline compatibility fixes cannot all be disabled within
   one translated executable. Implement independently selectable fixes only
   when their effects and compatibility can be established. Label required
   baseline fixes and unavailable components plainly in the launcher.
9. Inspect Stock Pack and Expansion Pack payloads before deciding which
   asset additions can be installed as selectable profiles. Keep each
   profile's writable saves separate. Never silently replace the chosen
   baseline executable with a pack's binary or mix incompatible patch sets.
10. Inspect IPLounge, but do not equate its Windows online client with an
    ARM64 macOS port. Online play is part of the compatibility investigation;
    enable it only if the full native path can be implemented and verified.

## Launcher behavior

The launcher shows the installed game and patch versions, resolution choices,
window/fullscreen choice, native renderer choice and the state of each supplied
community component. Compatible optional choices take effect on the next
launch. Required fixes and unimplemented components have an explanation and
cannot be toggled as though they worked. Failed launches report a readable
error and retain a diagnostic log. Quitting and restarting must preserve the
selected profile and settings.

## Verification and completion

- Verify ARM64 architecture for the host, launcher and bundled runtime.
- Test extraction, patch fingerprints, PE section handling and function
  discovery. Unsupported code paths must stop with a diagnostic, rather than
  silently acting as successful calls.
- Boot the real game and check menus and mouse/keyboard controls.
- Load a race, drive, complete it, return to menus and start another race.
- Exercise career/save/load, Hot Pursuit and split-screen where supported.
- Check Vulkan rendering, textures, depth, fog, headlights and HUD at more
  than one resolution. Confirm fullscreen entry/exit and app switching.
- Capture or otherwise inspect non-silent effects and music output. Exercise
  movie playback and audio separately.
- Check optional patch settings and profile isolation against real behavior.
- Keep a coverage record distinguishing implemented code, automated checks
  and interactive play testing. Report unresolved modes or patches explicitly.
  Compiling or showing a window is not sufficient for 'fully playable'.

## Boundaries and remaining uncertainty

This is a local port of the supplied copy. Preserve source images, patch
archives and NFSV. Retain applicable third-party notices. No uploading,
publishing, remote repository creation or external messages are authorized.
Do not include personal identifiers in new code, configuration or metadata.

Full gameplay compatibility cannot be established from the current inspection.
Runtime debugging, driver ABI differences, sound-library loading and optional
patch interactions may require substantial additional work. The requested
features remain the target; incomplete features must not be presented as done.

## References

- VEG author: https://veg.by/en/projects/nfs4/
- SilentPatch source: https://github.com/CookiePLMonster/SilentPatchNFS90s
- Vulkan driver author: https://www.moddb.com/games/need-for-speed-high-stakes/downloads/nfs4-vulkan
- macOS Vulkan implementation: https://github.com/KhronosGroup/MoltenVK

## Local input SHA-256 fingerprints

Computed directly from the supplied files during inspection.

| Input | SHA-256 |
| --- | --- |
| NFS.img | 011ef35613a15b372415cc3c3483559e44698ac09cbb4034ddd84f357b686cc4 |
| NFS.cue | 84e0522ff43d44906a0638e7597d26df8b0481cc7dc7663da920ec12f6efec07 |
| NFS.ccd | 45d9165d3bb26e295ae9c51e5a77eff313c3f155893b2347e9569a55d4f96c55 |
| NFS.sub | b8354e85a36b1b7f1b0b8cb7ba2d6c294fa9db53920ddb735253ddca9d1fe650 |
| Official 4.42 | a19891a4fc75ed3f2138acdf07a8d81d4eb6afdf47001f2ca4a2ebd787ca672e |
| Official 4.50 | 20b90c5f42ff899159d5e46cafcf0b599b1ae379f515a6794ffd92554dfe4d9f |
| VEG Modern Patch | cb4d34ff0e8be17c4b236ac58857f89442dd9a937235e2c1bb4397fa1bd6e015 |
| SilentPatch | 6c3b181301f3b6e646f4f42ad8e89f74dd3fea95cc028d055c56ddab7e0fd1b8 |
| Vulkan driver | b8920aae152fed3ab6aef14c53bae62267763e4570d083d91bd5ed1ea446adcc |
| Stock Pack | d03ecb002d476929fd28e1aa96ec752ee398243b136ec06e4a47128542cd7bb4 |
| Expansion Pack | efe0c834fb7a2a26ba5870b5e723516184ed60e027b95bc9edb5232ff62f57fc |
| IPLounge | 4ecd3b0674366f78f0dbe3ca701d9f768af4b75744b0546da45d6d43ba70c803 |
