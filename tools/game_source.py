"""Verify the supported retail assets before preparing a private VEG overlay."""
import configparser
import hashlib
from pathlib import Path
import shutil
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
        text += (f"\nDetected: {detected['files']:,} files, {detected['bytes']:,} bytes, SHA-256 "
                 f"{detected['sha256']}; expected {SOURCE['files']:,} files, {SOURCE['bytes']:,} bytes.")
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
    image = resolve_image(source)
    try:
        with Disc(image) as disc:
            return disc.extract(destination)
    except DiscError as error:
        print(f'Disc image error: {error}', file=sys.stderr, flush=True)
        raise SourceRejected(error.reason) from error


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
            shutil.copy2(path, target)
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
            shutil.copy2(child(source, 'NFSHS.ICO'), destination / 'nfshs.ico')
            # Copy only assets the native runtime uses; Windows driver DLLs are unnecessary.
            for name in ('nfs4.exe', 'eacsnd.dll'):
                shutil.copy2(child(overlay, name), destination / name)
            copy_assets(child(overlay, 'data'), destination / 'data')
            driver = destination / 'drivers/dx7'
            driver.mkdir(parents=True)
            shutil.copy2(child(child(child(overlay, 'drivers'), 'dx7'), 'thrash.ini'), driver / 'thrash.ini')
            (destination / 'nfs4.ini').write_text(INI)
        except BaseException:
            shutil.rmtree(destination)
            raise
    return verified
