"""Internal app packaging step. The public entry point is ./build.sh."""
import argparse
import json
import re
import stat
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
try:
    from .game_source import clone, leave_out, path_in
except ImportError:
    from game_source import clone, leave_out, path_in


def child(folder, name):
    matches = [p for p in Path(folder).iterdir() if p.name.casefold() == name.casefold()]
    if len(matches) != 1 or matches[0].is_symlink():
        raise ValueError(f'Missing or ambiguous prepared game path: {name}')
    return matches[0]



def payload_files(folder):
    folder = Path(folder)
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError('Payload must be a regular directory')
    files = []
    names = set()
    for path in folder.rglob('*'):
        relative = path.relative_to(folder).as_posix()
        if path.is_symlink():
            raise ValueError('Payload symlinks are not supported')
        mode = path.stat().st_mode
        if not stat.S_ISDIR(mode) and not stat.S_ISREG(mode):
            raise ValueError('Payload must contain regular files and directories')
        key = relative.casefold()
        if key in names:
            raise ValueError('Payload contains ambiguous filename casing')
        names.add(key)
        if stat.S_ISREG(mode) and path.name != '.DS_Store' and not path.name.startswith('._'):
            files.append((key, path))
    return sorted(files)


def content_catalog(addons):
    """Validate the community profiles. Each one runs straight from the bundle:
    the engine reads Addons/<id>/Overlay before Game, so nothing is merged or copied."""
    addons = Path(addons)
    payload_files(addons)
    catalog = json.loads((addons / 'catalog.json').read_text())
    if not isinstance(catalog, dict) or not isinstance(catalog.get('profiles'), list):
        raise ValueError('Invalid community content catalog')
    profiles = []
    used = {'original'}
    for item in catalog['profiles']:
        if not isinstance(item, dict):
            raise ValueError('Invalid community content profile')
        profile, name = item.get('id'), item.get('name')
        if not isinstance(profile, str) or not re.fullmatch(r'[a-z0-9_-]{1,64}', profile) or profile in used:
            raise ValueError('Community content profile IDs must be unique and cannot be original')
        if not isinstance(name, str) or not name.strip():
            raise ValueError('Community content profile needs a name')
        overlay = addons / profile / 'Overlay'
        if overlay.is_symlink() or not overlay.is_dir():
            raise ValueError(f'Community content profile has no overlay folder: {profile}')
        used.add(profile)
        profiles.append({'id': profile, 'name': name})
    return {'profiles': profiles}


def copy_tree(source, destination):
    """APFS clones (cp -c) of a payload tree on the same volume, else a copy keeping the
    quarantine of each file (game_source.clone())."""
    clone(source, destination)
    for junk in [*destination.rglob('.DS_Store'), *destination.rglob('._*')]:
        junk.unlink()


def package_app(game_folder, addons=None, output=None, moltenvk=None, builder_version=None):
    game_folder = Path(game_folder).resolve()
    output = Path(output or ROOT / 'out/NFSIV.app').resolve()
    moltenvk = Path(moltenvk or os.environ.get('NFSIV_MOLTENVK', ROOT / 'local/MoltenVK/MoltenVK')).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.nfsiv-app-', dir=output.parent) as temporary:
        app = Path(temporary) / 'NFSIV.app'
        contents = app / 'Contents'
        binaries, resources, frameworks = [contents / name for name in ('MacOS', 'Resources', 'Frameworks')]
        for folder in (binaries, resources, frameworks):
            folder.mkdir(parents=True)
        subprocess.run(['/usr/bin/sips', '-s', 'format', 'icns', str(child(game_folder, 'NFSHS.ICO')),
                        '--out', str(resources / 'NFSIV.icns')], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['clang', '-arch', 'arm64', '-mmacosx-version-min=11.0', '-O2', '-fobjc-arc',
                        '-I' + str(ROOT / 'gen/all'), str(ROOT / 'launcher/main.m'),
                        '-framework', 'Cocoa', '-o', str(binaries / 'NFSIVLauncher')], check=True)
        shutil.copy2(ROOT / 'out/nfsiv', binaries / 'NFSIVEngine')
        shutil.copy2(ROOT / 'out/linked.exe', resources / 'linked.exe')
        # The whole prepared game goes in: the retail assets with VEG's files, the icon (kept so
        # that a later update can reuse this app's game) and the Windows-only extras of the
        # player's copy. Only Finder files, links and macOS code stay out (leave_out()).
        for name in ('data', 'savedata', 'nfs4.exe', 'eacsnd.dll'):
            child(game_folder, name)
        payload_files(game_folder)
        destination = resources / 'Game'
        copy_tree(game_folder, destination)
        leave_out(destination)  # already done when the game was prepared
        # codesign --strict refuses Finder info and resource forks inside a bundle. The other
        # attributes stay, so a download's quarantine stays on the files copied from it.
        for name in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
            subprocess.run(['/usr/bin/xattr', '-dr', name, str(destination)], capture_output=True)
        path_in(destination, 'drivers', 'dx7', 'thrash.ini').write_text(
            '[THRASH]\nFile=dx7a.dll\nType=d3d\nFogSupport=1\nDirectDrawLagFix=1\n')
        (destination / 'nfs4.ini').write_text('[NFS4]\nLanguage=english\nNoMovies=0\nThrashDriver=dx7\nSingleProcAffinity=0\nOwnHeapLimitMb=64\nNoErrorReporting=0\nVariant=0\n')
        if addons:
            catalog = content_catalog(addons)
            copy_tree(Path(addons), resources / 'Addons')
            (resources / 'Addons/catalog.json').write_text(json.dumps(catalog, indent=2) + '\n')
        runtime = moltenvk / 'dynamic/dylib/macOS/libMoltenVK.dylib'
        target = frameworks / 'libMoltenVK.dylib'
        architectures = subprocess.check_output(['lipo', '-archs', str(runtime)], text=True).split()
        if 'arm64' not in architectures:
            raise ValueError('MoltenVK must include ARM64 support')
        if len(architectures) > 1:
            subprocess.run(['lipo', str(runtime), '-thin', 'arm64', '-output', str(target)], check=True)
        else:
            shutil.copy2(runtime, target)
        notices = resources / 'Notices'
        shutil.copytree(ROOT / 'third_party', notices)
        shutil.copy2(moltenvk.parent / 'LICENSE', notices / 'MoltenVK-LICENSE')
        info = {'CFBundleExecutable': 'NFSIVLauncher', 'CFBundleIdentifier': 'org.classicgames.nfsiv',
                'CFBundleName': 'NFSIV', 'CFBundleDisplayName': 'NFSIV', 'CFBundlePackageType': 'APPL',
                'CFBundleIconFile': 'NFSIV.icns',
                'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
                'LSMinimumSystemVersion': '11.0', 'NSHighResolutionCapable': True,
                'LSMultipleInstancesProhibited': True}
        if builder_version:
            # Lets the launcher offer newer Builder releases and the Builder show "old -> new".
            info['NFSBuilderVersion'] = str(builder_version)
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        for binary in (target, binaries / 'NFSIVEngine', binaries / 'NFSIVLauncher'):
            subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(binary)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        # Only replace a previous generated bundle. Writable saves live outside it.
        if output.exists():
            marker = output / 'Contents/Info.plist'
            if not marker.is_file() or plistlib.loads(marker.read_bytes()).get('CFBundleIdentifier') != info['CFBundleIdentifier']:
                raise ValueError('Refusing to replace an unrelated app at the output path')
            previous = Path(temporary) / 'previous.app'
            output.rename(previous)
        try:
            app.rename(output)
        except BaseException:
            if (Path(temporary) / 'previous.app').exists():
                (Path(temporary) / 'previous.app').rename(output)
            raise
    print(f'Built {output.name} (ARM64)')
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prepared_game', type=Path)
    parser.add_argument('--addons', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--moltenvk', type=Path)
    args = parser.parse_args()
    package_app(args.prepared_game, args.addons, args.output, args.moltenvk)
