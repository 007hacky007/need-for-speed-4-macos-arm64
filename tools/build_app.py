#!/usr/bin/env python3
"""Build the native Apple Silicon app from verified, privately supplied retail assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

try:
    from .downloads import digest, extract_tar, fetch
    from .game_source import extract_source, prepare_game, verify_source
    from .package import package_app
except ImportError:
    from downloads import digest, extract_tar, fetch
    from game_source import extract_source, prepare_game, verify_source
    from package import package_app

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    'veg': ('nfs4_modern_patch.7z', 'https://veg.by/files/nfs4/nfs4_modern_patch.7z',
            'cb4d34ff0e8be17c4b236ac58857f89442dd9a937235e2c1bb4397fa1bd6e015'),
    'moltenvk': ('MoltenVK-macos-1.2.11.tar', 'https://github.com/KhronosGroup/MoltenVK/releases/download/v1.2.11-artifacts/MoltenVK-macos.tar',
                 '6b984a8ea17028dcd1485f69465f7c3220ce8f56fbbd53b3dfb34c177af46ab8'),
    'glslang': ('glslang-14.3.0.tar.gz', 'https://github.com/KhronosGroup/glslang/archive/refs/tags/14.3.0.tar.gz',
                'be6339048e20280938d9cb399fcdd06e04f8654d43e170e8cce5a56c9a754284'),
    '7zip': ('7z2605-mac.tar.xz', 'https://github.com/ip7z/7zip/releases/download/26.05/7z2605-mac.tar.xz',
             '12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570'),
}


def check_host():
    if sys.version_info < (3, 11):
        raise ValueError('Python 3.11 or newer is required')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('Build requires macOS on Apple Silicon with a native ARM64 Python')
    if not shutil.which('xcrun'):
        raise ValueError('Install Xcode Command Line Tools before building (xcode-select --install)')
    try:
        clang = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
        sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
        version = subprocess.check_output([clang, '--version'], text=True)
        if 'Apple clang' not in version or not Path(sdk).is_dir():
            raise ValueError('Apple clang and a macOS SDK are required')
        for tool in ('codesign', 'lipo'):
            if not shutil.which(tool):
                raise ValueError(f'Apple build tool is missing: {tool}')
    except subprocess.CalledProcessError as error:
        raise ValueError('Xcode Command Line Tools are unavailable; check xcode-select') from error


def bootstrap(cache):
    """Install pinned wheels in a private environment, never global Python."""
    requirements = ROOT / 'requirements.txt'
    stamp = hashlib.sha256(requirements.read_bytes()).hexdigest()
    environment = cache / f'python-{sys.version_info.major}.{sys.version_info.minor}-{stamp[:12]}'
    python = environment / 'bin/python'
    marker = environment / '.requirements-sha256'
    if environment.is_symlink():
        raise ValueError('private Python environment must not be a symlink')
    if not python.is_file():
        subprocess.run([sys.executable, '-m', 'venv', str(environment)], check=True)
    if not marker.is_file() or marker.read_text() != stamp:
        subprocess.run([str(python), '-m', 'pip', 'install', '--disable-pip-version-check',
                        '--cache-dir', str(cache / 'pip'), '--retries', '2', '--timeout', '30',
                        '--only-binary=:all:', '-r', str(requirements)], check=True)
        marker.write_text(stamp)
    return python


def dependencies(cache, python, work):
    archives = {name: fetch(cache, *source) for name, source in SOURCES.items()}
    extract_tar(archives['7zip'], work / '7zip')
    extractor = work / '7zip/7zz'
    if not extractor.is_file() or not os.access(extractor, os.X_OK):
        raise ValueError('7-Zip archive is missing its executable')
    # The full release also contains framework symlinks; extract only native inputs.
    extract_tar(archives['moltenvk'], work / 'moltenvk', include=(
        'MoltenVK/LICENSE', 'MoltenVK/MoltenVK/include', 'MoltenVK/MoltenVK/dynamic/dylib/macOS'))
    moltenvk = work / 'moltenvk/MoltenVK/MoltenVK'
    for relative in ('include/vulkan/vulkan.h', 'dynamic/dylib/macOS/libMoltenVK.dylib'):
        if not (moltenvk / relative).is_file():
            raise ValueError(f'MoltenVK archive is missing {relative}')
    if not (moltenvk.parent / 'LICENSE').is_file():
        raise ValueError('MoltenVK archive is missing its license')
    compiler = cache / 'glslang-14.3.0-arm64'
    marker = compiler.with_suffix('.json')
    if compiler.is_symlink() or marker.is_symlink():
        raise ValueError('cached shader compiler must not be a symlink')
    valid = False
    if compiler.is_file() and marker.is_file():
        try:
            valid = json.loads(marker.read_text()) == {
                'source_sha256': SOURCES['glslang'][2], 'binary_sha256': digest(compiler)}
        except (ValueError, OSError):
            pass
    if not valid:
        extract_tar(archives['glslang'], work / 'glslang-source')
        source = work / 'glslang-source/glslang-14.3.0'
        build_dir = work / 'glslang-build'
        cmake = python.parent / 'cmake'
        subprocess.run([str(cmake), '-S', str(source), '-B', str(build_dir),
                        '-DCMAKE_BUILD_TYPE=Release', '-DENABLE_OPT=OFF',
                        '-DENABLE_GLSLANG_BINARIES=ON', '-DBUILD_TESTING=OFF',
                        '-DENABLE_CTEST=OFF', '-DCMAKE_OSX_ARCHITECTURES=arm64'], check=True)
        subprocess.run([str(cmake), '--build', str(build_dir), '-j' + str(min(8, os.cpu_count() or 1))], check=True)
        built = build_dir / 'StandAlone/glslang'
        temporary = work / 'glslang'
        shutil.copy2(built, temporary)
        os.replace(temporary, compiler)
        marker.write_text(json.dumps({'source_sha256': SOURCES['glslang'][2],
                                      'binary_sha256': digest(compiler)}) + '\n')
    return extractor, archives['veg'], moltenvk, compiler


def prepare_addons(cache, extractor):
    try:
        if __package__:
            from .addons import prepare_addons as prepare
        else:
            from addons import prepare_addons as prepare
    except ImportError as error:
        raise ValueError('--community requires tools/addons.py') from error
    return prepare(cache, extractor)


def build(args):
    source = args.game_source.expanduser().absolute()
    cache = args.cache.expanduser().absolute()
    if args.output.suffix != '.app':
        raise ValueError('output must be an .app bundle path')
    if source.is_symlink():
        raise ValueError('source symlink is unsupported')
    cache.mkdir(parents=True, exist_ok=True)
    if cache.resolve().is_relative_to(ROOT.resolve()):
        # Custom caches can live beside source; hide only generated cache entries.
        ignore = cache / '.gitignore'
        if ignore.is_symlink():
            raise ValueError('cache .gitignore must not be a symlink')
        existing = ignore.read_text() if ignore.exists() else ''
        rules = ['/.build-*/', '/addons-*/', '/python-*/', '/pip/',
                 '/glslang-14.3.0-arm64', '/glslang-14.3.json', '/hsfull.rar']
        rules.extend('/' + source[0] for source in SOURCES.values())
        missing = [rule for rule in rules if rule not in existing.splitlines()]
        if missing:
            with ignore.open('a') as target:
                target.write('\n' + '\n'.join(missing) + '\n')
    prepared_parent = ROOT / 'local/build-game'
    prepared_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.build-', dir=cache) as temporary:
        work = Path(temporary)
        if not source.is_dir():
            extract_source(source, work / 'disc')
            source = work / 'disc'
        verified = verify_source(source)
        print(f'Verified retail source: {verified}', flush=True)
        python = bootstrap(cache)
        extractor, veg, moltenvk, glslang = dependencies(cache, python, work)
        # Every invocation gets a new tree, preserving any previous prepared saves.
        prepared = Path(tempfile.mkdtemp(prefix='game-', dir=prepared_parent)) / 'Game'
        prepare_game(source, veg, extractor, prepared)
        addons = prepare_addons(cache, extractor) if args.community else None
        metadata = {'source': verified, 'dependencies': {k: v[2] for k, v in SOURCES.items()},
                    'baseline': 'EA 4.50 through verified VEG 0.1.0 executable and five matching menu files',
                    'community': bool(args.community)}
        (prepared.parent / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
        print(f'Prepared game: {prepared}', flush=True)
        if args.prepare_only:
            print('Source and dependencies verified; translation and app outputs were not touched.', flush=True)
            return prepared
        env = dict(os.environ, NFSIV_MOLTENVK=str(moltenvk), NFSIV_GLSLANG=str(glslang))
        subprocess.run([str(python), '-B', str(ROOT / 'tools/prepare.py'), str(prepared)],
                       check=True, cwd=ROOT, env=env)
        subprocess.run([str(python), '-B', str(ROOT / 'tools/compile.py')],
                       check=True, cwd=ROOT, env=env)
        return package_app(prepared, addons=addons, output=args.output, moltenvk=moltenvk)


def main():
    parser = argparse.ArgumentParser(prog='./build.sh', description=__doc__)
    parser.add_argument('game_source', type=Path, metavar='GAME_SOURCE')
    parser.add_argument('--cache', type=Path, default=Path.home() / 'Library/Caches/NFSIV')
    parser.add_argument('--output', type=Path, default=ROOT / 'out/NFSIV.app')
    parser.add_argument('--prepare-only', action='store_true', help='verify and prepare without touching gen/ or out/')
    parser.add_argument('--community', action='store_true', help='include optional community content packs')
    args = parser.parse_args()
    try:
        check_host()
        result = build(args)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Build failed: {error}\n')
    print(result)


if __name__ == '__main__':
    main()
