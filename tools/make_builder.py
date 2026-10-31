#!/usr/bin/env python3
"""Build and assemble NFSIV Builder.app (ad-hoc signed)."""
import argparse
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Keep in step with bundledSourceEntries in builder/Sources/BuilderCore/Workspace.swift.
ENTRIES = ('build.sh', 'requirements.txt', 'tools', 'runtime', 'launcher', 'third_party')
MIN_MACOS = '12.0'
BUNDLE_ID = 'org.classicgames.nfsiv.builder'
APP_NAME = 'NFSIV Builder'
EXECUTABLE = 'NFSIVBuilder'


def build_sources(root):
    """Tracked files the Builder bundles, relative to the repo root."""
    out = subprocess.run(['git', 'ls-files', '-z', '--', *ENTRIES], cwd=root, check=True,
                         capture_output=True).stdout.decode()
    return sorted(Path(n) for n in out.split('\0') if n and '__pycache__' not in Path(n).parts)


def parse_minos(otool_output):
    if 'LC_BUILD_VERSION' not in otool_output:
        raise ValueError('no LC_BUILD_VERSION load command')
    match = re.search(r'minos (\S+)', otool_output.split('LC_BUILD_VERSION', 1)[1])
    if not match:
        raise ValueError('LC_BUILD_VERSION has no minos')
    return match.group(1)


def build_binary(root):
    cmd = ['swift', 'build', '--package-path', str(root / 'builder'), '-c', 'release', '--arch', 'arm64']
    subprocess.run(cmd, check=True)
    shown = subprocess.run(cmd + ['--show-bin-path'], check=True, capture_output=True, text=True).stdout.strip()
    binary = Path(shown) / EXECUTABLE
    minos = parse_minos(subprocess.run(['otool', '-l', str(binary)], check=True, capture_output=True,
                                       text=True).stdout)
    if minos != MIN_MACOS:
        raise SystemExit(f'{binary} targets macOS {minos}, expected {MIN_MACOS}')
    print(f'minos {minos}')
    return binary


def make_icns(png, destination):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / 'AppIcon.iconset'
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                name = f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png'
                subprocess.run(['sips', '-z', str(size * scale), str(size * scale), str(png), '--out',
                                str(iconset / name)], check=True, capture_output=True)
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(destination)], check=True)


def info_plist(version):
    return {
        'CFBundleIdentifier': BUNDLE_ID, 'CFBundleName': APP_NAME, 'CFBundleDisplayName': APP_NAME,
        'CFBundleExecutable': EXECUTABLE, 'CFBundlePackageType': 'APPL', 'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleShortVersionString': version, 'CFBundleVersion': version,
        'LSMinimumSystemVersion': MIN_MACOS, 'NSHighResolutionCapable': True, 'CFBundleIconFile': 'AppIcon',
    }


def assemble(binary, version, output, root):
    app = Path(output) / f'{APP_NAME}.app'
    if app.exists():
        shutil.rmtree(app)
    macos, resources = app / 'Contents/MacOS', app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(binary, macos / EXECUTABLE)
    for rel in build_sources(root):
        target = resources / 'BuildSources' / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / rel, target)
    make_icns(root / 'builder/Resources/AppIcon-1024.png', resources / 'AppIcon.icns')
    with open(app / 'Contents/Info.plist', 'wb') as f:
        plistlib.dump(info_plist(version), f)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return app


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--version', required=True)
    ap.add_argument('--output', default='dist')
    args = ap.parse_args()
    print(assemble(build_binary(ROOT), args.version, Path(args.output), ROOT))


if __name__ == '__main__':
    main()
