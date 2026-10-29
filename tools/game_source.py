"""Verify the supported retail assets before preparing a private VEG overlay."""
import configparser
import hashlib
from pathlib import Path
import shutil
import tempfile

try:
    from .disc import Disc
    from .downloads import digest, extract_7z
except ImportError:
    from disc import Disc
    from downloads import digest, extract_7z

SOURCE = {'files': 1328, 'bytes': 547813845,
          'sha256': '73cb89e6dd4ea9ca32d02af2c822b22421cf9815e0c5557a3f6046671ed300d2'}
GAME_SHA = '17a0f96c3bcfb94fc72d31a429ef56e14ec028e4a6ed1f692cdd8efc0b762980'
SOUND_SHA = 'b23b61b85b3ad6b1d3f449e13a882585c254f271367bce5f932402163c9a358b'
ICON_SIZE = 766
ICON_SHA = 'cd07cfab47d414f218838ed1b5b4f18478e0d0e2eda09bbd3fed47e86c5f2d2a'
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


def inventory(folder):
    folder = Path(folder)
    if folder.is_symlink():
        raise ValueError(f'game symlink is unsupported: {folder}')
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
                raise ValueError(f'game symlink is unsupported: {relative}')
            if path.is_dir():
                walk(path, relative)
            elif path.is_file():
                files.append((key, path))
                size += path.stat().st_size
            else:
                raise ValueError(f'unsupported game file: {relative}')

    for name in ('data', 'savedata'):
        directory = child(folder, name)
        if not directory.is_dir():
            raise ValueError(f'game directory required: {name}')
        walk(directory, name)
    aggregate = hashlib.sha256()
    for name, path in sorted(files):
        aggregate.update(name.encode('utf-8') + b'\0' + bytes.fromhex(digest(path)))
    return {'files': len(files), 'bytes': size, 'sha256': aggregate.hexdigest()}


def verify_source(folder):
    actual = inventory(folder)
    if actual != SOURCE:
        raise ValueError('unsupported retail source checksum; expected pristine European Road Challenge '
                         f'DATA and SAVEDATA ({SOURCE["files"]} files); got {actual}')
    icon = child(folder, 'NFSHS.ICO')
    if not icon.is_file() or icon.stat().st_size != ICON_SIZE or digest(icon) != ICON_SHA:
        raise ValueError('NFSHS.ICO checksum mismatch; include the original retail disc icon')
    return actual


def resolve_image(source):
    source = Path(source)
    if source.is_symlink():
        raise ValueError(f'source symlink is unsupported: {source}')
    if not source.is_file():
        raise ValueError(f'game source does not exist: {source}')
    if source.suffix.casefold() != '.ccd':
        if source.suffix.casefold() not in ('.iso', '.bin', '.img', '.cue'):
            raise ValueError('unsupported source; use an extracted folder, ISO, BIN, IMG, CUE or CCD')
        return source
    try:
        ccd = configparser.ConfigParser()
        ccd.read_string(source.read_text(encoding='utf-8-sig'))
        tracks = [s for s in ccd.sections() if s.upper().startswith('TRACK ')]
        if (ccd.getint('CloneCD', 'Version') != 3 or ccd.getint('Disc', 'Sessions') != 1
                or ccd.getint('Disc', 'DataTracksScrambled') != 0 or tracks != ['TRACK 1']
                or ccd.getint('TRACK 1', 'MODE') != 1 or ccd.getint('TRACK 1', 'INDEX 1') != 0):
            raise ValueError('unsupported CCD layout; requires one unscrambled MODE1 track at sector 0')
    except (configparser.Error, UnicodeError) as error:
        raise ValueError(f'invalid CCD: {error}') from error
    image = child(source.parent, source.stem + '.img')
    if not image.is_file():
        raise ValueError('CCD requires a sibling IMG file')
    return image


def extract_source(source, destination):
    with Disc(resolve_image(source)) as disc:
        return disc.extract(destination)


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
