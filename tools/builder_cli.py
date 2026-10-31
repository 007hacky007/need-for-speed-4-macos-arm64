#!/usr/bin/env python3
"""Machine-readable helpers for NFSIV Builder. Prints NFSIV-EVENT JSON lines.

Standard library only: NFSIV Builder runs this with its private Python before the build
packages exist. Nothing here writes next to the game copy; disc images are extracted into a
temporary folder under local/.
"""
import argparse
import hashlib
import signal
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools import addons, build_app, downloads, game_source  # noqa: E402

emit = build_app.emit
DEFAULT_CACHE = Path.home() / 'Library/Caches/NFSIV'
EXPANSION = 'hsfull.rar'


def pinned(community):
    """(name, url, sha256) of every archive the build downloads."""
    entries = list(build_app.SOURCES.values())
    if community:
        entries.append((EXPANSION, addons.EXPANSION_URL, addons.EXPANSION_SHA256))
    return entries


def download_state(cache, community):
    """'ready', 'missing' or ('damaged', name); a damaged file wins over a missing one."""
    missing = False
    for name, _, sha256 in pinned(community):
        path = cache / name
        if path.is_symlink() or (path.exists() and (not path.is_file() or downloads.digest(path) != sha256)):
            return 'damaged', name
        missing = missing or not path.exists()
    return 'missing' if missing else 'ready'


def check_game(path):
    source = path.expanduser().absolute()
    if source.is_symlink():
        raise game_source.SourceRejected('link')
    if not source.exists():
        raise game_source.SourceRejected('missing')
    if source.is_dir():
        verified = game_source.verify_source(source)
    else:
        (ROOT / 'local').mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.check-', dir=ROOT / 'local') as temporary:
            folder = Path(temporary) / 'disc'
            print(f'Extracting {source.name} to check it', flush=True)
            game_source.extract_source(source, folder)
            verified = game_source.verify_source(folder)
    emit({'game': 'ok', 'version': game_source.SUPPORTED['release'],
          'summary': f"European Road Challenge CD, {verified['files']:,} files verified"})


def tools_status(cache):
    environment = build_app.environment_path(cache)
    python = environment / 'bin/python'
    marker = environment / '.requirements-sha256'
    stamp = hashlib.sha256((build_app.ROOT / 'requirements.txt').read_bytes()).hexdigest()
    if (not environment.is_symlink() and python.is_file() and marker.is_file()
            and marker.read_text() == stamp):
        emit({'tools': 'ready', 'python': str(python)})
    else:
        emit({'tools': 'missing'})


def fetch_downloads(cache, community):
    cache.mkdir(parents=True, exist_ok=True)
    for name, url, sha256 in pinned(community):
        path = cache / name
        # Only the pipeline's own pinned cache entries are ever replaced.
        if path.is_symlink() or (path.is_file() and downloads.digest(path) != sha256):
            print(f'Replacing the damaged download {name}', flush=True)
            path.unlink()
        downloads.fetch(cache, name, url, sha256)
    emit({'downloads': 'ready'})


def run(args):
    cache = args.cache.expanduser().absolute()
    if args.command == 'check-game':
        check_game(args.path)
    elif args.command == 'tools':
        tools_status(cache)
    elif args.command == 'supported':
        emit({'supported': game_source.SUPPORTED})
    elif args.action == 'status':
        state = download_state(cache, args.community)
        emit({'downloads': state} if isinstance(state, str) else {'downloads': state[0], 'file': state[1]})
    else:
        fetch_downloads(cache, args.community)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        emit({'error': f'Invalid options: {message}'})
        super().error(message)


def main(argv=None):
    # Cancel in NFSIV Builder sends SIGTERM; exiting normally removes the temporary folders.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    parser = Parser(description=__doc__.splitlines()[0])
    cache = argparse.ArgumentParser(add_help=False)
    cache.add_argument('--cache', type=Path, default=DEFAULT_CACHE)
    commands = parser.add_subparsers(dest='command', required=True, parser_class=Parser)
    commands.add_parser('check-game', parents=[cache], help='verify a game folder or disc image').add_argument(
        'path', type=Path)
    commands.add_parser('tools', parents=[cache], help='report the private Python packages').add_argument(
        'action', choices=('status',))
    files = commands.add_parser('downloads', parents=[cache], help='inspect or fetch the pinned downloads')
    files.add_argument('action', choices=('status', 'fetch'))
    files.add_argument('--community', action='store_true', help='include the High Stakes Expansion Pack')
    commands.add_parser('supported', parents=[cache], help='describe the accepted game release')
    try:
        args = parser.parse_args(argv)
    except SystemExit as stop:
        return stop.code
    try:
        run(args)
    except Exception as error:
        if not isinstance(error, (ValueError, RuntimeError, OSError, subprocess.SubprocessError)):
            traceback.print_exc()
        detail = game_source.describe_rejection(error) if isinstance(error, game_source.SourceRejected) else error
        print(f'Failed: {detail}', file=sys.stderr, flush=True)
        emit(build_app.failure_event(error))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
