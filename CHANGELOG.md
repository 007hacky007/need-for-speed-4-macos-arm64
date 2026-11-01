# Changelog

What each version of NFSIV Builder brings. The newest version is first.

## 1.1.0 - 2026-11-01

### Added
- The launcher tells you when a newer NFSIV Builder is out, with What's new, Download and Not now. It checks once a day, and unticking Check for updates stops all network requests.
- NFSIV Builder can update an existing NFSIV.app using the game inside it, so you do not need your game copy again. You can also drop an NFSIV.app onto the Game copy row. The button reads Update NFSIV.app with the old and new version, and saves are kept.

### Changed
- NFSIV.app now holds your whole game copy, Windows-only extras included. It needs no game folder and keeps working wherever you move it. Apps made by earlier Builders need your original game copy one more time.
- Community content profiles now run straight from the app instead of from a separate copy of the game for each profile. The launcher deletes those old copies once, which frees their disk space.
- Mac programs hidden in a game copy are left out of the app, and files from your game copy or disc image keep their download quarantine.
- Remove build files is now Delete temporary files. It shows how much space it frees and says what it deletes and what it keeps.

## 1.0.1 - 2026-10-31

### Changed
- While the game is in front it takes the mouse, as it does on Windows, so the game cursor reaches every edge of the picture. Cmd+Tab gets the Mac pointer back.

### Fixed
- Typing works again after switching between fullscreen and a window.

## 1.0.0 - 2026-10-31

### Added
- NFSIV Builder makes NFSIV.app on your Mac from your own European retail CD of Need for Speed: Road Challenge, given as a folder or a disc image (ISO, BIN/CUE, IMG or CCD). It downloads and applies the patches the game needs.
- A checklist that fixes each missing item with one button. No Terminal needed.
- The game runs as native Apple Silicon code with Vulkan or Metal graphics, your choice, and CoreAudio sound. No Wine, Rosetta or emulator.
- The original game: menus, physics and AI, racing, career, Hot Pursuit, local split-screen and replays, with the original sound, music and movies.
- Race resolutions from 640x480 to 4096x3072, and borderless fullscreen that you can switch with F11 while you play.
- A launcher that remembers your renderer, resolution, fullscreen, audio, movie and fix choices, and opens your saves and logs.
- Optional SilentPatch input fixes and a projected-headlight fix, each with a launcher switch.
- Optional community content from the High Stakes Expansion Pack: 70 cars, 30 replacement tracks and pursuit traffic. You pick one content profile per launch, and each has its own saves.
- Your saves and logs are kept outside the app, so rebuilding never touches them.
