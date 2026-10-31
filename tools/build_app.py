#!/usr/bin/env python3
"""Build the native Apple Silicon app from verified, privately supplied retail assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import traceback
from urllib.parse import urlparse

try:
    from .downloads import DownloadFailed, digest, extract_tar, fetch
    from .game_source import SourceRejected, describe_rejection, extract_source, prepare_game, verify_source
    from .package import package_app
except ImportError:
    from downloads import DownloadFailed, digest, extract_tar, fetch
    from game_source import SourceRejected, describe_rejection, extract_source, prepare_game, verify_source
    from package import package_app

ROOT = Path(__file__).resolve().parents[1]
EVENT_PREFIX = 'NFSIV-EVENT '
PROGRESS = False
STEP_FAILED = 'This step stopped with an error. Click Copy log and include it in a bug report.'
SETUP_FAILED = 'Could not set up the build tools. Check your internet connection and try again.'
XCODE_LICENCE = 'Open Xcode once to accept its licence, then try again.'
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


DOWNLOAD_TITLES = {
    SOURCES['veg'][0]: 'VEG Modern Patch', SOURCES['moltenvk'][0]: 'MoltenVK',
    SOURCES['glslang'][0]: 'glslang source', SOURCES['7zip'][0]: '7-Zip',
    'hsfull.rar': 'High Stakes Expansion Pack',
}


def emit(event):
    """One machine-readable line for NFSIV Builder; every other line is plain log text."""
    print(EVENT_PREFIX + json.dumps(event), flush=True)


def step(ident, title):
    print(f'\n{title}', flush=True)
    if PROGRESS:
        emit({'step': ident, 'title': title})


def download_message(error, progress=False):
    host = urlparse(error.url).hostname or error.url
    host = host.removeprefix('www.')
    message = (f'The {DOWNLOAD_TITLES.get(error.name, error.name)} download from {host} failed. '
               'Check your internet connection and try again')
    if progress and error.name == 'hsfull.rar':
        message += ', or untick Include community cars and tracks'
    return message + '.'


def check_platform():
    if sys.version_info < (3, 11):
        raise ValueError('Python 3.11 or newer is required')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('Build requires macOS on Apple Silicon with a native ARM64 Python')


def tool_output(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        # An Xcode whose licence was never accepted refuses to run its tools.
        if 'license' in (result.stdout + result.stderr).lower():
            raise ValueError(XCODE_LICENCE)
        raise subprocess.CalledProcessError(result.returncode, command, result.stdout, result.stderr)
    return result.stdout.strip()


def check_toolchain():
    if not shutil.which('xcrun'):
        raise ValueError('Install Xcode Command Line Tools before building (xcode-select --install)')
    try:
        clang = tool_output(['xcrun', '--find', 'clang'])
        sdk = tool_output(['xcrun', '--show-sdk-path'])
        version = tool_output([clang, '--version'])
        if 'Apple clang' not in version or not Path(sdk).is_dir():
            raise ValueError('Apple clang and a macOS SDK are required')
        for tool in ('codesign', 'lipo'):
            if not shutil.which(tool):
                raise ValueError(f'Apple build tool is missing: {tool}')
    except subprocess.CalledProcessError as error:
        raise ValueError('Xcode Command Line Tools are unavailable; check xcode-select') from error


def check_host():
    check_platform()
    check_toolchain()


def environment_path(cache):
    """The private venv, named after requirements.txt and the interpreter that creates it, so
    venvs from different Pythons of the same version never share a cache entry."""
    stamp = hashlib.sha256((ROOT / 'requirements.txt').read_bytes()).hexdigest()
    base = hashlib.sha256(os.path.realpath(sys.base_prefix).encode()).hexdigest()
    return Path(cache) / f'python-{sys.version_info.major}.{sys.version_info.minor}-{stamp[:12]}-{base[:8]}'


def bootstrap(cache):
    """Install pinned wheels in a private environment, never global Python."""
    requirements = ROOT / 'requirements.txt'
    stamp = hashlib.sha256(requirements.read_bytes()).hexdigest()
    environment = environment_path(cache)
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
    unquarantine(environment)
    return python


def unquarantine(path):
    """Clear com.apple.quarantine from a tool this build runs (recursively for folders).

    Files written by processes started from a quarantined NFSIV Builder (a fresh download
    run from its disk image) can inherit the flag, and Gatekeeper then refuses to run the
    downloaded 7zz, the pip cmake or the locally built glslang. Missing flags are fine."""
    if Path(path).exists():
        subprocess.run(['/usr/bin/xattr', '-d', '-r', 'com.apple.quarantine', str(path)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def dependencies(cache, python, work):
    archives = {name: fetch(cache, *source) for name, source in SOURCES.items()}
    extract_tar(archives['7zip'], work / '7zip')
    unquarantine(work / '7zip')
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
    unquarantine(compiler)
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
        raise SourceRejected('link')
    if not source.exists():
        raise SourceRejected('missing')
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
    community = getattr(args, 'community', False)
    created = []  # this run's intermediates, removed at the end with --discard-intermediates
    try:
        with tempfile.TemporaryDirectory(prefix='.build-', dir=cache) as temporary:
            work = Path(temporary)
            if not source.is_dir():
                step('extract', f'Extracting {source.name}')
                extract_source(source, work / 'disc')
                source = work / 'disc'
            step('verify', 'Checking the retail game files and icon')
            verified = verify_source(source)
            print(f'Verified retail source: {verified}', flush=True)
            step('setup', 'Setting up the private Python packages')
            python = bootstrap(cache)
            step('dependencies', 'Fetching and checking the build dependencies')
            extractor, veg, moltenvk, glslang = dependencies(cache, python, work)
            step('prepare', 'Preparing the game files with VEG Modern Patch')
            # Every invocation gets a new tree, preserving any previous prepared saves.
            prepared_root = Path(tempfile.mkdtemp(prefix='game-', dir=prepared_parent))
            created.append(prepared_root)
            prepared = prepared_root / 'Game'
            prepare_game(source, veg, extractor, prepared)
            addons = None
            if community:
                step('community', 'Preparing community cars, tracks and traffic')
                addons = prepare_addons(cache, extractor)
                if addons.parent == cache and addons.name.startswith('addons-'):
                    created.append(addons)
            metadata = {'source': verified, 'dependencies': {k: v[2] for k, v in SOURCES.items()},
                        'baseline': 'EA 4.50 through verified VEG 0.1.0 executable and five matching menu files',
                        'community': bool(community)}
            (prepared.parent / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
            print(f'Prepared game: {prepared}', flush=True)
            if args.prepare_only:
                print('Source and dependencies verified; translation and app outputs were not touched.', flush=True)
                return prepared
            env = dict(os.environ, NFSIV_MOLTENVK=str(moltenvk), NFSIV_GLSLANG=str(glslang))
            step('translate', 'Translating the game and sound code to C')
            subprocess.run([str(python), '-B', str(ROOT / 'tools/prepare.py'), str(prepared)],
                           check=True, cwd=ROOT, env=env)
            step('compile', 'Compiling native ARM64 code')
            subprocess.run([str(python), '-B', str(ROOT / 'tools/compile.py')],
                           check=True, cwd=ROOT, env=env)
            step('package', 'Packaging and signing NFSIV.app')
            return package_app(prepared, addons=addons, output=args.output, moltenvk=moltenvk)
    finally:
        if getattr(args, 'discard_intermediates', False):
            for path in created:
                shutil.rmtree(path, ignore_errors=True)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        if PROGRESS:
            emit({'error': f'Invalid build options: {message}'})
        super().error(message)


def failure_event(error, setup_only=False):
    """The one plain sentence NFSIV Builder shows; the details are in the log above it."""
    if isinstance(error, SourceRejected):
        event = {'error': str(error), 'reason': error.reason}
        if error.detected:
            event['detected'] = error.detected
        return event
    return {'error': failure_message(error, setup_only)}


def failure_message(error, setup_only=False):
    if isinstance(error, DownloadFailed):
        return download_message(error, progress=True)
    if isinstance(error, subprocess.CalledProcessError):
        return SETUP_FAILED if setup_only else STEP_FAILED
    if isinstance(error, (ValueError, RuntimeError, OSError, subprocess.SubprocessError)):
        return str(error)
    return f'Unexpected error ({type(error).__name__}). Click Copy log and include it in a bug report.'


def main(argv=None):
    global PROGRESS
    # Cancel in NFSIV Builder sends SIGTERM; exiting normally unwinds every temporary directory.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    argv = sys.argv[1:] if argv is None else list(argv)
    options = argv[:argv.index('--')] if '--' in argv else argv
    PROGRESS = '--progress' in options
    parser = Parser(prog='./build.sh', description=__doc__)
    parser.add_argument('game_source', type=Path, nargs='?', metavar='GAME_SOURCE')
    parser.add_argument('--cache', type=Path, default=Path.home() / 'Library/Caches/NFSIV')
    parser.add_argument('--output', type=Path, default=ROOT / 'out/NFSIV.app')
    parser.add_argument('--prepare-only', action='store_true', help='verify and prepare without touching gen/ or out/')
    parser.add_argument('--community', action='store_true', help='include optional community content packs')
    parser.add_argument('--progress', action='store_true', help='print NFSIV-EVENT JSON lines for NFSIV Builder')
    parser.add_argument('--setup-only', action='store_true',
                        help='only set up the private Python packages; GAME_SOURCE is not needed')
    parser.add_argument('--discard-intermediates', action='store_true',
                        help="remove this build's prepared game and community files when it ends")
    try:
        args = parser.parse_args(argv)
        if args.prepare_only and args.discard_intermediates:
            parser.error('--discard-intermediates cannot be combined with --prepare-only')
        if args.game_source is None and not args.setup_only:
            parser.error('the following arguments are required: GAME_SOURCE')
    except SystemExit as stop:
        return stop.code
    try:
        if args.setup_only:
            check_platform()
            python = bootstrap(args.cache.expanduser().absolute())
            if PROGRESS:
                # The same shape as `builder_cli.py tools status`, which the Builder parses.
                emit({'tools': 'ready', 'python': str(python)})
            return 0
        check_host()
        result = build(args)
    except Exception as error:
        known = isinstance(error, (ValueError, RuntimeError, OSError, subprocess.SubprocessError))
        if not known:
            traceback.print_exc()
        detail = describe_rejection(error) if isinstance(error, SourceRejected) else error
        print(f'Build failed: {detail}' if known else 'Build failed.', file=sys.stderr, flush=True)
        if PROGRESS:
            emit(failure_event(error, args.setup_only))
        return 1
    if PROGRESS and not args.prepare_only:
        emit({'done': str(result)})
    print(result)
    return 0


if __name__ == '__main__':
    sys.exit(main())
