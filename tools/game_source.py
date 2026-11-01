"""Verify the supported retail assets before preparing a private VEG overlay."""
import configparser
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile

try:
    from .disc import Disc, DiscError
    from .downloads import digest, extract_7z
except ImportError:
    from disc import Disc, DiscError
    from downloads import digest, extract_7z

# The one accepted release, with exactly the README "Supported game copy" table values.
# NFSIV Builder shows this in "Which copy works?"; it holds no checksums of its own.
SUPPORTED = {
    'release': 'Need for Speed: Road Challenge, European retail CD',
    'languages': 'English, Spanish and Swedish disc files (0409/040A/041D); the port runs in English',
    'assets': {'what': 'All files under DATA and SAVEDATA, combined', 'files': 1328, 'bytes': 547813845,
               'sha256': '73cb89e6dd4ea9ca32d02af2c822b22421cf9815e0c5557a3f6046671ed300d2'},
    'icon': {'what': 'NFSHS.ICO at the disc root', 'bytes': 766,
             'sha256': 'cd07cfab47d414f218838ed1b5b4f18478e0d0e2eda09bbd3fed47e86c5f2d2a'},
    'inputs': 'A folder with DATA, SAVEDATA and NFSHS.ICO from the disc root; an ISO; a single-track MODE1 '
              'BIN/CUE or IMG image; or a CCD with its IMG beside it.',
    'note': 'The checksum is a fingerprint of the extracted files, not of the disc image. '
            'Different ISO, BIN or IMG files can hold the same accepted game.',
}
SOURCE = {key: SUPPORTED['assets'][key] for key in ('files', 'bytes', 'sha256')}
GAME_SHA = '17a0f96c3bcfb94fc72d31a429ef56e14ec028e4a6ed1f692cdd8efc0b762980'
SOUND_SHA = 'b23b61b85b3ad6b1d3f449e13a882585c254f271367bce5f932402163c9a358b'
ICON_SIZE = SUPPORTED['icon']['bytes']
ICON_SHA = SUPPORTED['icon']['sha256']
# What prepare_game makes of the accepted copy with the pinned VEG patch: the retail DATA and
# SAVEDATA with VEG's five 4.50 menu files on top, measured like SOURCE. A built NFSIV.app
# carries this tree in Contents/Resources/Game, so an update can reuse it in place of
# the original copy (whose replaced menu files the app no longer has) when it still matches.
PREPARED = {'files': 1328, 'bytes': 547816751,
            'sha256': '279fe27b1ed88301fabd27649ab9a22aaa0d33c3b7cfe01d0ec6b6e70203f814'}
# Beside them the app carries everything else of the player's copy (the Windows-only extras such
# as the installer, DirectX and the 3dfx drivers), which differs from copy to copy. prepare_game
# records the inventory of the whole prepared game in RECORD, so an update finds a missing or
# changed file anywhere. Only RECORD itself and the two settings files packaging writes anew
# are not in it.
RECORD = 'game-files.json'
WRITTEN = (RECORD, 'nfs4.ini', 'drivers/dx7/thrash.ini')
# Copied or replaced on their own: the retail assets and icon, and what VEG and the port supply.
OWN = ('data', 'savedata', 'nfshs.ico', 'nfs4.exe', 'eacsnd.dll', 'nfs4.ini')
BUNDLE_ID = 'org.classicgames.nfsiv'
MESSAGES = {
    'missing': 'The game copy was not found. Choose it again.',
    'link': 'Choose the original folder or file, not an alias or link.',
    'unsupported-type': 'Choose a game folder, .iso, .bin, .img, .cue or .ccd.',
    'ccd-image': 'The .ccd file needs its matching .img file in the same folder.',
    'cue-image': 'The .cue file needs the .bin or .img file it names in the same folder.',
    'image-layout': 'This disc image layout is not supported. Use an ISO, or a single-track BIN/CUE, '
                    'IMG or CCD/IMG image.',
    'unreadable': 'This disc image could not be read. It may be damaged or incomplete.',
    'not-game': 'This is not a Road Challenge game copy: the DATA and SAVEDATA folders were not found.',
    'assets': 'This copy does not match the supported release. NFSIV needs the unmodified European retail CD '
              'of Need for Speed: Road Challenge (English, Spanish and Swedish).',
    'icon-missing': 'NFSHS.ICO is missing. Choose the disc image instead, or copy NFSHS.ICO from the root of '
                    'the game disc into this folder.',
    'icon': 'NFSHS.ICO does not match the retail disc icon. Copy it again from the root of the game disc.',
    'not-app': 'This app is not an NFSIV.app built by NFSIV Builder. Choose NFSIV.app or your game copy.',
    'bundle': 'The game inside this NFSIV.app is missing or was changed. Choose your original game copy.',
    'old-app': 'This NFSIV.app was built by an older NFSIV Builder, which left part of your game copy out of it. '
               'Choose your original game copy once to build the complete app.',
}


class SourceRejected(ValueError):
    """The user's game copy cannot be used; the message is one plain sentence."""

    def __init__(self, reason, detected=None):
        super().__init__(MESSAGES[reason])
        self.reason, self.detected = reason, detected


def describe_rejection(error):
    """The plain sentence, plus the detected inventory when one was measured."""
    text = str(error)
    detected = getattr(error, 'detected', None)
    if detected:
        expected = PREPARED if getattr(error, 'reason', None) == 'bundle' else SOURCE
        text += (f"\nDetected: {detected['files']:,} files, {detected['bytes']:,} bytes, SHA-256 "
                 f"{detected['sha256']}; expected {expected['files']:,} files, {expected['bytes']:,} bytes.")
    return text


INI = '[NFS4]\nLanguage=english\nNoMovies=0\nThrashDriver=dx7\nSingleProcAffinity=0\nOwnHeapLimitMb=64\nNoErrorReporting=0\nVariant=0\n'


def metadata(name):
    return name == '.DS_Store' or name.startswith('._') or name == '__MACOSX'


def child(folder, name):
    matches = [p for p in Path(folder).iterdir() if p.name.casefold() == name.casefold()]
    if len(matches) != 1:
        raise ValueError(f'missing or case-colliding game path: {name}')
    if matches[0].is_symlink():
        raise ValueError(f'game symlink is unsupported: {matches[0]}')
    return matches[0]


def source_child(folder, name, reason):
    """Like child(), for the user's copy: a missing entry is rejected with `reason`."""
    matches = [p for p in Path(folder).iterdir() if p.name.casefold() == name.casefold()]
    if len(matches) != 1:
        raise SourceRejected(reason)
    if matches[0].is_symlink():
        raise SourceRejected('link')
    return matches[0]


def inventory(folder):
    folder = Path(folder)
    if folder.is_symlink():
        raise SourceRejected('link')
    if not folder.is_dir():
        raise SourceRejected('missing')
    files, seen, size = [], set(), 0

    def walk(directory, prefix):
        nonlocal size
        for path in directory.iterdir():
            if metadata(path.name):
                continue
            relative = prefix + '/' + path.name
            key = relative.casefold()
            if key in seen:
                raise ValueError(f'case-colliding game path: {relative}')
            seen.add(key)
            if path.is_symlink():
                raise SourceRejected('link')
            if path.is_dir():
                walk(path, relative)
            elif path.is_file():
                files.append((key, path))
                size += path.stat().st_size
            else:
                raise ValueError(f'unsupported game file: {relative}')

    for name in ('data', 'savedata'):
        directory = source_child(folder, name, 'not-game')
        if not directory.is_dir():
            raise SourceRejected('not-game')
        walk(directory, name)
    aggregate = hashlib.sha256()
    for name, path in sorted(files):
        aggregate.update(name.encode('utf-8') + b'\0' + bytes.fromhex(digest(path)))
    return {'files': len(files), 'bytes': size, 'sha256': aggregate.hexdigest()}


def tree_inventory(folder):
    """inventory() of every file in a prepared game, less WRITTEN."""
    folder = Path(folder)
    files, size = [], 0
    for directory, names, filenames in os.walk(folder):
        names[:] = [n for n in names if not metadata(n)]
        for name in names + filenames:
            path = Path(directory) / name
            if metadata(name):
                continue
            if path.is_symlink():
                raise SourceRejected('link')
            key = path.relative_to(folder).as_posix().casefold()
            if path.is_file() and key not in WRITTEN:
                files.append((key, path))
                size += path.stat().st_size
            elif not path.is_file() and not path.is_dir():
                raise ValueError(f'unsupported game file: {key}')
    aggregate = hashlib.sha256()
    for name, path in sorted(files):
        aggregate.update(name.encode('utf-8') + b'\0' + bytes.fromhex(digest(path)))
    return {'files': len(files), 'bytes': size, 'sha256': aggregate.hexdigest()}


# macOS code that never goes into NFSIV.app from the player's copy (names compared casefolded).
# Bundles: folders with these extensions or with a Contents/Info.plist, left out whole.
MACOS_BUNDLES = ('.app', '.appex', '.framework', '.bundle', '.plugin', '.kext', '.pkg', '.mpkg', '.workflow',
                 '.action', '.xpc', '.prefpane', '.saver', '.qlgenerator', '.mdimporter', '.scptd', '.wdgt',
                 '.component', '.systemextension')
# Files: scripts, libraries and launchers by extension, and any file that starts like a script
# ("#!") or a Mach-O binary, whatever its name.
MACOS_FILES = ('.command', '.tool', '.sh', '.bash', '.zsh', '.csh', '.ksh', '.fish', '.py', '.pl', '.rb', '.php',
               '.scpt', '.applescript', '.terminal', '.dylib', '.so', '.jar')
MACH_O = {bytes.fromhex(magic) for magic in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def macos_code(path):
    """True when `path` (a folder or a regular file, not a link) is macOS code by the rules above."""
    path = Path(path)
    name = path.name.casefold()
    if path.is_dir():
        return name.endswith(MACOS_BUNDLES) or os.path.lexists(path / 'Contents' / 'Info.plist')
    if name.endswith(MACOS_FILES):
        return True
    with path.open('rb') as f:
        head = f.read(4)
    return head[:2] == b'#!' or head in MACH_O


def left_out(folder, skip=('data', 'savedata')):
    """What never goes into NFSIV.app from `folder` (a game with files copied from the player's
    copy), as (path, why) pairs: Finder files, symbolic links (codesign refuses links that leave
    the app) and macOS code. The game is Windows files only, and a Mac program hidden in a
    downloaded copy must not end up inside a signed app. Windows files stay. The top-level names
    in `skip` (the retail assets, checked against PREPARED) are not looked at. Only reads."""
    folder = Path(folder)

    def scan(path):
        if path.is_symlink():
            yield path, 'symbolic link'
        elif metadata(path.name):
            yield path, 'Finder file'
        elif path.is_dir():
            if macos_code(path):
                yield path, 'macOS code'
            else:
                for item in sorted(path.iterdir()):
                    yield from scan(item)
        elif path.is_file() and macos_code(path):
            yield path, 'macOS code'

    for item in sorted(folder.iterdir()):
        if item.name.casefold() not in skip:
            yield from scan(item)


def leave_out(folder, skip=('data', 'savedata')):
    """Removes what left_out() finds from `folder`, logging each item, and takes the execute
    permission off every file left (the game only reads them; the port's own programs are in
    Contents/MacOS, not here). Returns the removed paths."""
    folder, removed = Path(folder), []
    for path, why in list(left_out(folder, skip)):
        relative = path.relative_to(folder).as_posix()
        print(f'left out of the app ({why}): {relative}', flush=True)
        removed.append(relative)
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    for directory, _, names in os.walk(folder):
        for name in names:
            path = os.path.join(directory, name)
            mode = os.lstat(path).st_mode
            if stat.S_ISREG(mode) and mode & 0o111:
                os.chmod(path, stat.S_IMODE(mode) & ~0o111)
    return removed


# com.apple.quarantine of the files copied from the player's copy stays on them in the app (only
# what the build made loses it). Python has no xattr calls on macOS, so libc's are used.
QUARANTINE = b'com.apple.quarantine'
_XATTR_NOFOLLOW = 0x0001
_ENOATTR = 93
_libc = ctypes.CDLL(None, use_errno=True) if sys.platform == 'darwin' else None
if _libc:
    _libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_uint32, ctypes.c_int]
    _libc.getxattr.restype = ctypes.c_ssize_t
    _libc.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_uint32, ctypes.c_int]
    _libc.setxattr.restype = ctypes.c_int


def quarantine(path):
    """The com.apple.quarantine value of `path` (a link itself, not followed), or None."""
    if not _libc:
        return None
    name = os.fsencode(path)
    size = _libc.getxattr(name, QUARANTINE, None, 0, 0, _XATTR_NOFOLLOW)
    if size >= 0:
        buffer = ctypes.create_string_buffer(size)
        size = _libc.getxattr(name, QUARANTINE, buffer, size, 0, _XATTR_NOFOLLOW)
        if size >= 0:
            return buffer.raw[:size]
    error = ctypes.get_errno()
    if error == _ENOATTR:
        return None
    raise OSError(error, f'cannot read the quarantine of {path}: {os.strerror(error)}')


def set_quarantine(path, value):
    """Sets com.apple.quarantine of `path` (not following a link) to `value`; raises if it can't."""
    if _libc and _libc.setxattr(os.fsencode(path), QUARANTINE, value, len(value), 0, _XATTR_NOFOLLOW) != 0:
        error = ctypes.get_errno()
        raise OSError(error, f'cannot keep the quarantine on {path}: {os.strerror(error)}')


def keep_quarantine(source, destination):
    """Gives each folder and file of the copy `destination` the exact quarantine its counterpart
    in `source` has (copies other than APFS clones drop or rewrite it). Fails rather than leave
    a quarantined file of the player's copy without its quarantine."""
    source, destination = Path(source), Path(destination)
    pairs = [(source, destination)]
    if source.is_dir() and not source.is_symlink():
        for directory, names, files in os.walk(source):
            relative = Path(directory).relative_to(source)
            pairs.extend((Path(directory) / name, destination / relative / name) for name in names + files)
    for original, copy in pairs:
        if original.is_symlink():
            continue
        value = quarantine(original)
        if value is not None and quarantine(copy) != value:
            set_quarantine(copy, value)


def quarantine_tree(folder, value):
    """Puts `value` on `folder` and everything in it (files extracted from a quarantined image)."""
    set_quarantine(folder, value)
    for directory, names, files in os.walk(folder):
        for name in names + files:
            path = os.path.join(directory, name)
            if not os.path.islink(path):
                set_quarantine(path, value)


def copy_file(source, destination):
    """shutil.copy2, with the source's exact quarantine kept."""
    shutil.copy2(source, destination)
    keep_quarantine(source, destination)


def path_in(folder, *parts):
    """folder/parts with each existing part matched case-insensitively, the folders made."""
    path = Path(folder)
    for index, part in enumerate(parts):
        matches = [p for p in path.iterdir() if p.name.casefold() == part.casefold()] if path.is_dir() else []
        path = matches[0] if len(matches) == 1 else path / part
        if index < len(parts) - 1:
            path.mkdir(exist_ok=True)
    return path


def verify_source(folder):
    actual = inventory(folder)
    if actual != SOURCE:
        raise SourceRejected('assets', detected=actual)
    icon = source_child(folder, 'NFSHS.ICO', 'icon-missing')
    if not icon.is_file() or icon.stat().st_size != ICON_SIZE or digest(icon) != ICON_SHA:
        raise SourceRejected('icon')
    return actual


def resolve_image(source):
    source = Path(source)
    if source.is_symlink():
        raise SourceRejected('link')
    if not source.exists():
        raise SourceRejected('missing')
    if not source.is_file() or source.suffix.casefold() not in ('.iso', '.bin', '.img', '.cue', '.ccd'):
        raise SourceRejected('unsupported-type')
    if source.suffix.casefold() != '.ccd':
        return source
    try:
        ccd = configparser.ConfigParser()
        ccd.read_string(source.read_text(encoding='utf-8-sig'))
        tracks = [s for s in ccd.sections() if s.upper().startswith('TRACK ')]
        if (ccd.getint('CloneCD', 'Version') != 3 or ccd.getint('Disc', 'Sessions') != 1
                or ccd.getint('Disc', 'DataTracksScrambled') != 0 or tracks != ['TRACK 1']
                or ccd.getint('TRACK 1', 'MODE') != 1 or ccd.getint('TRACK 1', 'INDEX 1') != 0):
            raise SourceRejected('image-layout')
    except (configparser.Error, UnicodeError, ValueError) as error:
        if isinstance(error, SourceRejected):
            raise
        raise SourceRejected('image-layout') from error
    image = source_child(source.parent, source.stem + '.img', 'ccd-image')
    if not image.is_file():
        raise SourceRejected('ccd-image')
    return image


def extract_source(source, destination):
    """Extracts the player's disc image. The files are written anew, so they get the image's
    quarantine (that of the image file read, else of the file chosen, such as the .cue)."""
    image = resolve_image(source)
    try:
        with Disc(image) as disc:
            entries = disc.extract(destination)
            value = quarantine(disc.path)
    except DiscError as error:
        print(f'Disc image error: {error}', file=sys.stderr, flush=True)
        raise SourceRejected(error.reason) from error
    if value is None:
        value = quarantine(source)
    if value is not None:
        try:
            quarantine_tree(destination, value)
        except BaseException:
            shutil.rmtree(destination)
            raise
    return entries


def is_app(path):
    return Path(path).suffix.lower() == '.app' and Path(path).is_dir()


def app_info(app):
    """The Info.plist of an NFSIV.app this project built, or SourceRejected('not-app')."""
    app = Path(app)
    plist = app / 'Contents/Info.plist'
    try:
        info = plistlib.loads(plist.read_bytes()) if not app.is_symlink() and not plist.is_symlink() else None
    except (OSError, plistlib.InvalidFileException, ValueError):
        info = None
    if not isinstance(info, dict) or info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise SourceRejected('not-app')
    return info


def check_prepared(game):
    """Raise SourceRejected('bundle') unless `game` is exactly the tree prepare_game makes."""
    try:
        actual = inventory(game)
        for name, sha in (('nfs4.exe', GAME_SHA), ('eacsnd.dll', SOUND_SHA)):
            if digest(child(game, name)) != sha:
                raise SourceRejected('bundle', detected=actual)
    except SourceRejected as error:
        if error.reason == 'bundle':
            raise
        raise SourceRejected('bundle') from error
    except (OSError, ValueError) as error:
        raise SourceRejected('bundle') from error
    if actual != PREPARED:
        raise SourceRejected('bundle', detected=actual)
    record = Path(game) / RECORD
    if not record.is_file() or record.is_symlink():
        raise SourceRejected('old-app')
    try:
        if json.loads(record.read_text()) != tree_inventory(game):
            raise SourceRejected('bundle')
    except (OSError, ValueError) as error:
        if isinstance(error, SourceRejected):
            raise
        raise SourceRejected('bundle') from error
    return actual


def verify_bundle(app):
    """Check the game an existing NFSIV.app carries, reading it only.
    -> (inventory, the Builder version that built it or None)."""
    info = app_info(app)
    game = Path(app) / 'Contents/Resources/Game'
    if game.is_symlink() or not game.is_dir():
        raise SourceRejected('bundle')
    return check_prepared(game), info.get('NFSBuilderVersion')


def clone(source, destination):
    """APFS clone (cp -c) when source and destination share a volume, else a copy with cp -p,
    which keeps the extended attributes but rewrites a quarantine; keep_quarantine() then makes
    sure each copied item has its exact one (or fails). Links are copied as links."""
    source, destination = Path(source), Path(destination)
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
        return
    flag = '-R' if source.is_dir() else '-p'
    if subprocess.run(['/bin/cp', '-c', flag, str(source), str(destination)],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        elif destination.exists() or destination.is_symlink():
            destination.unlink()
        result = subprocess.run(['/bin/cp', '-Rp' if flag == '-R' else '-p', str(source), str(destination)],
                                capture_output=True, text=True)
        if result.returncode:
            raise OSError(f'could not copy {source}: {result.stderr.strip()}')
    keep_quarantine(source, destination)


def reuse_bundle(app, destination):
    """Prepare `destination` from the game an existing NFSIV.app carries, for an update.

    The old app is only read: its whole game is cloned, and the clone, not the original, is
    what gets verified and used, so a change to the old app meanwhile cannot slip in."""
    app, destination = Path(app), Path(destination)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    app_info(app)
    game = app / 'Contents/Resources/Game'
    if game.is_symlink() or not game.is_dir():
        raise SourceRejected('bundle')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.mkdir()
    try:
        for path in sorted(game.iterdir()):
            if not metadata(path.name):
                clone(path, destination / path.name)
        verified = check_prepared(destination)
        try:
            if digest(child(destination, 'nfshs.ico')) != ICON_SHA:
                raise SourceRejected('bundle')
        except ValueError as error:
            if isinstance(error, SourceRejected):
                raise
            raise SourceRejected('bundle') from error
        # The driver and nfs4.ini files are written again when the app is packaged.
    except BaseException:
        shutil.rmtree(destination)
        raise
    return verified


def copy_assets(source, destination):
    """Use one casefolded namespace so VEG replaces retail files on every filesystem."""
    destination.mkdir(parents=True, exist_ok=True)
    for path in source.iterdir():
        if metadata(path.name):
            continue
        if path.is_symlink():
            raise ValueError(f'game symlink is unsupported: {path}')
        target = destination / path.name.casefold()
        if path.is_dir():
            copy_assets(path, target)
        elif path.is_file():
            copy_file(path, target)
        else:
            raise ValueError(f'unsupported game file: {path}')


def prepare_game(source, veg_archive, extractor, destination):
    """Never modify source trees or archives; destination must be newly created."""
    source, destination = Path(source), Path(destination)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.source-', dir=destination.parent) as temporary:
        work = Path(temporary)
        if source.is_symlink():
            raise ValueError('source symlink is unsupported')
        if not source.is_dir():
            extract_source(source, work / 'disc')
            source = work / 'disc'
        verified = verify_source(source)
        extract_7z(veg_archive, work / 'veg', extractor)
        overlay = work / 'veg'
        for name, sha in (('nfs4.exe', GAME_SHA), ('eacsnd.dll', SOUND_SHA)):
            if digest(child(overlay, name)) != sha:
                raise ValueError(f'unsupported VEG {name} checksum')
        destination.mkdir()
        try:
            for name in ('data', 'savedata'):
                copy_assets(child(source, name), destination / name)
            copy_file(child(source, 'NFSHS.ICO'), destination / 'nfshs.ico')
            # The rest of the copy goes in as it is (APFS clones, so a download's quarantine
            # stays), less what leave_out() removes; VEG's executable and sound module replace
            # the retail ones.
            for path in sorted(source.iterdir()):
                if not metadata(path.name) and path.name.casefold() not in OWN:
                    clone(path, destination / path.name)
            leave_out(destination)
            # Of VEG, only what the native runtime uses; its Windows driver DLLs are unnecessary.
            for name in ('nfs4.exe', 'eacsnd.dll'):
                shutil.copy2(child(overlay, name), destination / name)
            copy_assets(child(overlay, 'data'), destination / 'data')
            shutil.copy2(child(child(child(overlay, 'drivers'), 'dx7'), 'thrash.ini'),
                         path_in(destination, 'drivers', 'dx7', 'thrash.ini'))
            (destination / 'nfs4.ini').write_text(INI)
            (destination / RECORD).write_text(json.dumps(tree_inventory(destination), indent=2) + '\n')
        except BaseException:
            shutil.rmtree(destination)
            raise
    return verified
